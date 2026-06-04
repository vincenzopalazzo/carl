// HTTP + WebSocket client for the carl daemon.
//
// Connection config (base URL + token) comes from one of two places:
//   - Tauri:   the Rust shell spawns `carl daemon` as a sidecar, reads its
//              token off stdout, and returns it via the `daemon_config` command.
//   - Browser: dev env vars (VITE_CARL_BASE / VITE_CARL_TOKEN) with defaults
//              matching the demo daemon.
import type {
  AppState,
  DiscoverResult,
  Route,
  Settings,
} from "./types";

export interface DaemonConfig {
  base: string;
  token: string;
}

function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/** Resolve the daemon base URL + token for this runtime. */
export async function resolveConfig(): Promise<DaemonConfig> {
  if (isTauri()) {
    const { invoke } = await import("@tauri-apps/api/core");
    return await invoke<DaemonConfig>("daemon_config");
  }
  const env = import.meta.env;
  return {
    base: env.VITE_CARL_BASE ?? "http://127.0.0.1:8088",
    token: env.VITE_CARL_TOKEN ?? "carldemo",
  };
}

export class DaemonClient {
  constructor(private cfg: DaemonConfig) {}

  private headers(): HeadersInit {
    return {
      "X-Carl-Token": this.cfg.token,
      "Content-Type": "application/json",
    };
  }

  private async json<T>(res: Response): Promise<T> {
    if (!res.ok) {
      throw new Error(`${res.status} ${res.statusText}`);
    }
    return (await res.json()) as T;
  }

  async getState(): Promise<AppState> {
    const res = await fetch(`${this.cfg.base}/api/state`, {
      headers: this.headers(),
    });
    return this.json<AppState>(res);
  }

  async addTransfer(
    source: string,
    route: Route,
    nostr: boolean,
  ): Promise<{ id: string }> {
    const res = await fetch(`${this.cfg.base}/api/transfers`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ source, route, nostr }),
    });
    return this.json<{ id: string }>(res);
  }

  async removeTransfer(id: string): Promise<void> {
    const res = await fetch(`${this.cfg.base}/api/transfers/${id}`, {
      method: "DELETE",
      headers: this.headers(),
    });
    if (!res.ok && res.status !== 404) {
      throw new Error(`${res.status} ${res.statusText}`);
    }
  }

  async search(query: string): Promise<DiscoverResult[]> {
    const res = await fetch(`${this.cfg.base}/api/search`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ query }),
    });
    return this.json<DiscoverResult[]>(res);
  }

  async setRoute(route: Route): Promise<Settings> {
    const res = await fetch(`${this.cfg.base}/api/settings`, {
      method: "POST",
      headers: this.headers(),
      body: JSON.stringify({ route }),
    });
    return this.json<Settings>(res);
  }

  /**
   * Open the live state WebSocket. `onState` fires on each pushed snapshot.
   * Returns the socket so the caller can close it. The token rides in the query
   * string because browsers can't set headers on a WebSocket handshake.
   */
  openStateSocket(
    onState: (s: AppState) => void,
    onStatus: (connected: boolean) => void,
  ): WebSocket {
    const wsBase = this.cfg.base.replace(/^http/, "ws");
    const ws = new WebSocket(
      `${wsBase}/ws?token=${encodeURIComponent(this.cfg.token)}`,
    );
    ws.onopen = () => onStatus(true);
    ws.onclose = () => onStatus(false);
    ws.onerror = () => onStatus(false);
    ws.onmessage = (ev) => {
      try {
        onState(JSON.parse(ev.data) as AppState);
      } catch {
        /* ignore malformed frame */
      }
    };
    return ws;
  }
}
