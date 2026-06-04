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

fn resolve_carl_bin() -> String {
    std::env::var("CARL_BIN").unwrap_or_else(|_| "carl".to_string())
}

/// Spawn `carl daemon` and block (with a timeout) until it reports its token.
fn spawn_daemon(port: u16) -> Result<(Child, DaemonConfig), String> {
    let bin = resolve_carl_bin();
    let mut child = Command::new(&bin)
        .args(["daemon", "--port", &port.to_string()])
        .stdout(Stdio::piped())
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
        return Err("daemon did not report a token within 10s".to_string());
    }

    // Keep draining stdout so the daemon's pipe never fills and blocks it.
    std::thread::spawn(move || {
        let mut buf = String::new();
        while reader.read_line(&mut buf).unwrap_or(0) > 0 {
            buf.clear();
        }
    });

    let cfg = DaemonConfig {
        base: format!("http://127.0.0.1:{port}"),
        token,
    };
    Ok((child, cfg))
}

pub fn run() {
    tauri::Builder::default()
        .manage(DaemonState::default())
        .invoke_handler(tauri::generate_handler![daemon_config])
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
            if let tauri::RunEvent::Exit = event {
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
