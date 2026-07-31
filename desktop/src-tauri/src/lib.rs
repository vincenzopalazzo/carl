//! Tauri shell for the carl desktop GUI.
//!
//! On startup it spawns `carl daemon` as a child process, parses the token from
//! the daemon's startup banner (`token: <hex>`), and exposes the base URL +
//! token to the webview via the `daemon_config` command. The child is killed
//! when the app exits.
//!
//! Binary resolution: `CARL_BIN` env var if set (the dev workflow points this
//! at the freshly built `zig-out/bin/carl`), otherwise `carl` on `PATH`.
//! Bundling the daemon as a Tauri sidecar resource is a follow-up.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::Manager;

/// The port the embedded daemon listens on (loopback only).
const DAEMON_PORT: u16 = 8077;

#[derive(Clone, serde::Serialize)]
struct DaemonConfig {
    base: String,
    token: String,
}

#[derive(Default)]
struct DaemonState {
    config: Mutex<Option<DaemonConfig>>,
    child: Mutex<Option<Child>>,
}

/// Returns the daemon base URL + token for the frontend client.
#[tauri::command]
fn daemon_config(state: tauri::State<DaemonState>) -> Result<DaemonConfig, String> {
    state
        .config
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "daemon not ready".to_string())
}

/// Resolve the `carl` daemon binary, in priority order:
///   1. `CARL_BIN` env var — the dev workflow points this at `zig-out/bin/carl`.
///   2. The bundled sidecar next to the app executable (Contents/MacOS/carl) —
///      so a Finder-launched app ships its own daemon and never depends on
///      `$PATH` (GUI apps get a minimal PATH without ~/.local/bin or
///      /usr/local/bin, which otherwise yields "daemon offline").
///   3. `carl` on `$PATH` — the bare fallback for a dev shell.
fn resolve_carl_bin() -> String {
    if let Ok(p) = std::env::var("CARL_BIN") {
        return p;
    }
    if let Some(sidecar) = bundled_sidecar() {
        return sidecar.to_string_lossy().into_owned();
    }
    "carl".to_string()
}

/// The bundled sidecar `carl` next to the app executable, if present (only in a
/// packaged app — not a `CARL_BIN` dev run).
fn bundled_sidecar() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let sidecar = exe.parent()?.join("carl");
    sidecar.exists().then_some(sidecar)
}

/// The system CLI symlink location — on the default terminal PATH, root-owned
/// (so installing here needs a one-time admin authorization, like Docker).
const SYSTEM_CLI_PATH: &str = "/usr/local/bin/carl";

/// The per-user CLI location — no password needed, but only useful if the user
/// has `~/.local/bin` on their PATH.
fn user_cli_path() -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(
        std::path::Path::new(&home)
            .join(".local")
            .join("bin")
            .join("carl"),
    )
}

/// Reported to the UI so it can mirror Docker's "CLI installed / not installed"
/// state and offer install/remove.
#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct CliStatus {
    /// The packaged app has a bundled `carl` to link to (false in a dev run).
    available: bool,
    /// A `carl` is present at one of the known install locations.
    installed: bool,
    /// Where it's installed, if any.
    path: Option<String>,
    /// True when the install is the system location (/usr/local/bin); false for
    /// the per-user one. Lets the UI drive reinstall/remove without re-deriving
    /// the location from the path string.
    system: bool,
    /// True when the installed entry is a symlink into THIS app bundle (so it
    /// tracks app updates — the Docker model). A plain file or a link elsewhere
    /// reports false.
    linked_to_bundle: bool,
}

/// Quote a string for a single-quoted `/bin/sh` argument: wrap in `'…'` and
/// escape any embedded single quote as `'\''`. Prevents a path containing a
/// quote (e.g. an app under "/Users/me/Vince's apps/…") from breaking — or
/// injecting into — the admin shell command.
fn sh_single_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Run a shell command with one-time admin authorization via the native macOS
/// dialog (the Homebrew-cask approach). `script` must be a self-contained
/// `/bin/sh` snippet; embed any paths via `sh_single_quote`.
#[cfg(target_os = "macos")]
fn run_admin(script: &str) -> Result<(), String> {
    // Embed into an AppleScript string: escape backslashes and double quotes.
    let escaped = script.replace('\\', "\\\\").replace('"', "\\\"");
    let osa = format!("do shell script \"{escaped}\" with administrator privileges");
    let out = Command::new("osascript")
        .arg("-e")
        .arg(osa)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        // Cancelling the password dialog yields "User canceled. (-128)".
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

/// Report whether the bundled CLI is available and where (if anywhere) it's
/// installed — so Settings can show the right install/remove affordance.
#[tauri::command]
fn cli_status() -> CliStatus {
    let bundle = bundled_sidecar();
    let mut candidates: Vec<std::path::PathBuf> = vec![std::path::PathBuf::from(SYSTEM_CLI_PATH)];
    if let Some(u) = user_cli_path() {
        candidates.push(u);
    }
    for p in candidates {
        // symlink_metadata so a symlink doesn't get followed/hidden.
        if std::fs::symlink_metadata(&p).is_ok() {
            let linked_to_bundle = match (std::fs::read_link(&p).ok(), bundle.as_ref()) {
                (Some(t), Some(b)) => &t == b,
                _ => false,
            };
            return CliStatus {
                available: bundle.is_some(),
                installed: true,
                path: Some(p.to_string_lossy().into_owned()),
                system: p == std::path::Path::new(SYSTEM_CLI_PATH),
                linked_to_bundle,
            };
        }
    }
    CliStatus {
        available: bundle.is_some(),
        installed: false,
        path: None,
        system: false,
        linked_to_bundle: false,
    }
}

/// Install the CLI by symlinking a PATH location to the bundled `carl` — so the
/// CLI always tracks this app's version (no stale copies, no signature kill).
/// `system` targets `/usr/local/bin` (one admin prompt); otherwise `~/.local/bin`
/// (no prompt). Returns the installed path.
#[tauri::command]
fn install_cli(system: bool) -> Result<String, String> {
    let sidecar = bundled_sidecar().ok_or("the command-line tool isn't available in this build")?;
    let src = sidecar.to_string_lossy();
    if system {
        // mkdir + symlink, replacing any existing entry, with one auth prompt.
        // Paths are shell-quoted so a quote/space in the bundle path is safe.
        let script = format!(
            "mkdir -p /usr/local/bin && ln -sf {} {}",
            sh_single_quote(&src),
            sh_single_quote(SYSTEM_CLI_PATH),
        );
        #[cfg(target_os = "macos")]
        {
            run_admin(&script)?;
            Ok(SYSTEM_CLI_PATH.to_string())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = script;
            Err("system install is only implemented on macOS".to_string())
        }
    } else {
        let dest = user_cli_path().ok_or("no HOME directory")?;
        if let Some(dir) = dest.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let _ = std::fs::remove_file(&dest); // replace any existing entry
        #[cfg(unix)]
        std::os::unix::fs::symlink(&sidecar, &dest).map_err(|e| e.to_string())?;
        Ok(dest.to_string_lossy().into_owned())
    }
}

/// Remove a CLI symlink we installed. `system` targets `/usr/local/bin` (admin
/// prompt); otherwise `~/.local/bin`.
#[tauri::command]
fn uninstall_cli(system: bool) -> Result<(), String> {
    if system {
        #[cfg(target_os = "macos")]
        {
            run_admin(&format!("rm -f {}", sh_single_quote(SYSTEM_CLI_PATH)))?;
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        Err("system uninstall is only implemented on macOS".to_string())
    } else {
        let dest = user_cli_path().ok_or("no HOME directory")?;
        let _ = std::fs::remove_file(&dest);
        Ok(())
    }
}

/// The daemon log file the shell tees the sidecar's output into:
/// `<config>/carl/daemon.log`, with the same config-dir resolution the daemon
/// itself uses (`$XDG_CONFIG_HOME/carl`, else `~/.config/carl`). Rotated to
/// `daemon.log.old` past 2 MiB so a chatty daemon can't fill the disk.
/// Returns a shareable handle; None if the file can't be opened (draining
/// still happens, just discarded, so the pipe never blocks the daemon).
type SharedLog = std::sync::Arc<std::sync::Mutex<Option<std::fs::File>>>;

fn open_daemon_log() -> SharedLog {
    let file = (|| -> Option<std::fs::File> {
        let config = std::env::var("XDG_CONFIG_HOME")
            .map(std::path::PathBuf::from)
            .or_else(|_| std::env::var("HOME").map(|h| std::path::PathBuf::from(h).join(".config")))
            .ok()?;
        let dir = config.join("carl");
        std::fs::create_dir_all(&dir).ok()?;
        let path = dir.join("daemon.log");
        const MAX_LOG_BYTES: u64 = 2 * 1024 * 1024;
        if std::fs::metadata(&path).map(|m| m.len() > MAX_LOG_BYTES).unwrap_or(false) {
            let _ = std::fs::rename(&path, dir.join("daemon.log.old"));
        }
        std::fs::OpenOptions::new().create(true).append(true).open(path).ok()
    })();
    std::sync::Arc::new(std::sync::Mutex::new(file))
}

/// Drain one daemon output stream to EOF, teeing lines into the log file.
///
/// Byte-oriented on purpose: `read_line` into a String fails the whole drain
/// loop on the first non-UTF-8 byte (a torrent/peer name logged raw), the
/// pipe then fills, and the daemon blocks forever on its next stderr write —
/// the exact "offline daemon" hang this log exists to diagnose.
fn drain_to_log<R: std::io::Read>(mut reader: BufReader<R>, log: SharedLog) {
    let mut buf: Vec<u8> = Vec::new();
    while reader.read_until(b'\n', &mut buf).unwrap_or(0) > 0 {
        if let Ok(mut guard) = log.lock() {
            if let Some(f) = guard.as_mut() {
                use std::io::Write;
                let _ = f.write_all(&buf);
            }
        }
        buf.clear();
    }
}

/// Spawn `carl daemon` and block (with a timeout) until it reports its token.
fn spawn_daemon(port: u16) -> Result<(Child, DaemonConfig), String> {
    let bin = resolve_carl_bin();
    let port_s = port.to_string();
    let pid_s = std::process::id().to_string();

    // No --download-dir: the daemon resolves the unified carl work dir itself
    // ($CARL_DIR > the persisted Settings value > ~/Downloads/carl), the same
    // resolution the CLI uses — so GUI and CLI share one download + seed
    // directory and never fall back to the Finder-launch CWD (`/`).
    //
    // Pass our PID so the daemon's watchdog shuts it down if this shell dies
    // without a clean exit (crash / force-quit), instead of orphaning it.
    let mut cmd = Command::new(&bin);
    cmd.args(["daemon", "--port", &port_s, "--parent-pid", &pid_s]);
    let mut child = cmd
        .stdout(Stdio::piped())
        // Pipe stderr too so the daemon's log (Zig std.log goes to stderr)
        // lands in the log file below instead of vanishing when the app is
        // launched from Finder (no console attached).
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to spawn '{bin}': {e}"))?;

    let stdout = child.stdout.take().ok_or("daemon has no stdout")?;
    let mut reader = BufReader::new(stdout);

    // The banner prints "token: <hex>" once it is listening.
    let mut token = String::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut line = String::new();
    while Instant::now() < deadline {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break, // EOF — daemon exited
            Ok(_) => {
                if let Some(rest) = line.trim().strip_prefix("token:") {
                    token = rest.trim().to_string();
                    break;
                }
            }
            Err(e) => return Err(e.to_string()),
        }
    }
    if token.is_empty() {
        // Surface the daemon's own log tail — a daemon that won't start is
        // the top cause of a permanently "offline" GUI, and its reason
        // otherwise vanishes with the discarded pipes. Kill first so a wedged
        // (not crashed) daemon still reaches stderr EOF and can't leak.
        let _ = child.kill();
        let mut tail = String::new();
        if let Some(err) = child.stderr.take() {
            use std::io::Read;
            // Read on a helper thread with a deadline: a blocking read here
            // only ends at stderr EOF, which a future grandchild inheriting
            // the pipe could withhold forever. Bytes + lossy because the
            // daemon's log is not guaranteed UTF-8, and read_to_string would
            // then discard the tail we came for. A timed-out read just means
            // no tail — the kill above already guarantees the daemon is gone.
            let (tx, rx) = std::sync::mpsc::channel();
            std::thread::spawn(move || {
                let mut all = Vec::new();
                let _ = err.take(8192).read_to_end(&mut all);
                let _ = tx.send(all);
            });
            let all = rx.recv_timeout(Duration::from_secs(2)).unwrap_or_default();
            let lossy = String::from_utf8_lossy(&all);
            tail = lossy
                .chars()
                .rev()
                .take(2048)
                .collect::<String>()
                .chars()
                .rev()
                .collect();
        }
        return Err(format!(
            "daemon did not report a token within 10s. daemon log tail:\n{tail}"
        ));
    }

    // Keep draining stdout so the daemon's pipe never fills and blocks it —
    // and tee it (plus stderr, which carries the daemon's actual log) into
    // `<config>/carl/daemon.log`. Without this the daemon's output is
    // discarded entirely, so a crash/wedged daemon in the packaged app leaves
    // no trace and the GUI's bare "offline" badge is undiagnosable.
    let log_file = open_daemon_log();
    let stderr = child.stderr.take();
    let stdout_log = log_file.clone();
    std::thread::spawn(move || drain_to_log(reader, stdout_log));
    if let Some(stderr) = stderr {
        std::thread::spawn(move || drain_to_log(BufReader::new(stderr), log_file));
    }

    let cfg = DaemonConfig {
        base: format!("http://127.0.0.1:{port}"),
        token,
    };
    Ok((child, cfg))
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(DaemonState::default())
        .invoke_handler(tauri::generate_handler![
            daemon_config,
            cli_status,
            install_cli,
            uninstall_cli
        ])
        .setup(|app| {
            match spawn_daemon(DAEMON_PORT) {
                Ok((child, cfg)) => {
                    let state = app.state::<DaemonState>();
                    *state.config.lock().unwrap() = Some(cfg);
                    *state.child.lock().unwrap() = Some(child);
                }
                Err(e) => {
                    // Surface to the console; the UI shows a "daemon offline"
                    // state via its reconnect logic.
                    eprintln!("carl: {e}");
                }
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building the carl application")
        .run(|app_handle, event| {
            // Kill the daemon on either teardown event. The daemon's --parent-pid
            // watchdog is the backstop for crash/force-quit paths that never emit
            // these (or where `panic = abort` skips unwinding).
            if matches!(
                event,
                tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit
            ) {
                let state = app_handle.state::<DaemonState>();
                // Bind the taken child first so the MutexGuard temporary drops
                // before `state` does (avoids an E0597 borrow-lifetime error).
                let child = state.child.lock().unwrap().take();
                if let Some(mut child) = child {
                    let _ = child.kill();
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::sh_single_quote;

    #[test]
    fn sh_single_quote_wraps_and_escapes() {
        assert_eq!(sh_single_quote("/usr/local/bin/carl"), "'/usr/local/bin/carl'");
        // An embedded single quote must close, escape, and reopen the quoting
        // so the shell can't be broken out of (e.g. an app under "Vince's apps").
        assert_eq!(
            sh_single_quote("/a/Vince's apps/carl"),
            "'/a/Vince'\\''s apps/carl'"
        );
    }
}
