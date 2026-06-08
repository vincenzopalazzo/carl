// Command-line-tool install, Docker-style: the packaged app symlinks a PATH
// location to its bundled `carl`, so the CLI always tracks the app version.
// These are Tauri commands (not daemon HTTP), so they only do anything inside
// the desktop shell; in a browser they degrade to "unavailable".

export interface CliStatus {
  /** The packaged app has a bundled `carl` to link to. */
  available: boolean;
  /** A `carl` is present at a known install location. */
  installed: boolean;
  /** Where it's installed, if any. */
  path: string | null;
  /** True when installed in the system location (/usr/local/bin) vs per-user. */
  system: boolean;
  /** True when the install is a symlink into this app bundle (tracks updates). */
  linkedToBundle: boolean;
}

function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

const UNAVAILABLE: CliStatus = {
  available: false,
  installed: false,
  path: null,
  system: false,
  linkedToBundle: false,
};

export async function cliStatus(): Promise<CliStatus> {
  if (!isTauri()) return UNAVAILABLE;
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<CliStatus>("cli_status");
}

/** Install the CLI. `system` → /usr/local/bin (one admin prompt); otherwise
 *  ~/.local/bin (no prompt). Returns the installed path. */
export async function installCli(system: boolean): Promise<string> {
  if (!isTauri()) throw new Error("the command-line tool is only available in the desktop app");
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<string>("install_cli", { system });
}

export async function uninstallCli(system: boolean): Promise<void> {
  if (!isTauri()) throw new Error("the command-line tool is only available in the desktop app");
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("uninstall_cli", { system });
}
