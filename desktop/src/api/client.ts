// HTTP + WebSocket client for the carl daemon.
//
// Connection config (base URL + token) comes from one of two places:
//   - Tauri:   the Rust shell spawns `carl daemon` as a sidecar, reads its
//              token off stdout, and returns it via the `daemon_config` command.
//   - Browser: dev env vars (VITE_CARL_BASE / VITE_CARL_TOKEN) with defaults
//              matching the demo daemon.
import type {
  AppState,
  CreateTorrentResult,
  DiscoverResult,
  Route,
  Settings,
} from "./types";

export interface DaemonConfig {
  base: string;
  token: string;
}

/** Abort a stuck request so the UI falls back to its offline state instead of
 *  awaiting a hung daemon socket forever. Used for the fast read endpoints. */
const REQUEST_TIMEOUT_MS = 8000;

/** Adding a transfer or seed on an anonymized route blocks the daemon while it
 *  stands up the network session: a Tor hidden service, or an I2P SAM
 *  `SESSION CREATE` that builds tunnels (commonly 10-30s, bounded by the
 *  daemon's 60s SAM timeout). The 8s read timeout would abort that mid-build —
 *  the transfer/seed never registers and the UI looks like "i2p doesn't work" —
 *  so add/seed get a timeout that comfortably covers session setup. (A bridge
 *  that's actually down still fails fast: connection refused is instant.)
 *
 *  Note WKWebView itself kills any request idle for ~60s with
 *  `TypeError: Load failed` — before the daemon sent interim `102 Processing`
 *  keep-alives, a slow I2P session build (>60s across its SAM round-trips)
 *  died here with exactly that error even though the daemon was still
 *  working. The 90s cap below is still a sane upper bound on top. */
const SESSION_SETUP_TIMEOUT_MS = 90_000;

/** Matches the daemon's body cap (docs/daemon-api.md) — guard before reading the
 *  whole file into memory so a huge drop fails fast with a clear message. */
const MAX_SEED_BYTES = 256 * 1024 * 1024;

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
      // Surface the daemon's `{ "error": "..." }` body when present, so the UI
      // shows an actionable reason (e.g. Tor ControlPort not enabled) instead
      // of a bare status code.
      let detail = "";
      try {
        const body = (await res.json()) as { error?: unknown };
        if (body && typeof body.error === "string") detail = `: ${body.error}`;
      } catch {
        /* non-JSON or empty body — fall back to the status line */
      }
      throw new Error(`${res.status} ${res.statusText}${detail}`);
    }
    return (await res.json()) as T;
  }

  /** fetch() with the daemon token + a timeout so a hung socket can't wedge the
   *  UI. Caller-supplied headers/options win. */
  private fetch(path: string, init: RequestInit = {}): Promise<Response> {
    return fetch(`${this.cfg.base}${path}`, {
      ...init,
      headers: { ...this.headers(), ...(init.headers ?? {}) },
      signal: init.signal ?? AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  }

  async getState(): Promise<AppState> {
    return this.json<AppState>(await this.fetch("/api/state"));
  }

  async addTransfer(
    source: string,
    route: Route,
    nostr: boolean,
  ): Promise<{ id: string }> {
    const res = await this.fetch("/api/transfers", {
      method: "POST",
      body: JSON.stringify({ source, route, nostr }),
      // Anonymized routes build a session before the daemon responds (see
      // SESSION_SETUP_TIMEOUT_MS); don't abort mid-build.
      signal: AbortSignal.timeout(SESSION_SETUP_TIMEOUT_MS),
    });
    return this.json<{ id: string }>(res);
  }

  async removeTransfer(id: string): Promise<void> {
    const res = await this.fetch(`/api/transfers/${id}`, { method: "DELETE" });
    if (!res.ok && res.status !== 404) {
      throw new Error(`${res.status} ${res.statusText}`);
    }
  }

  /** Follow a publisher: mirror (download + reseed) everything they announce
   *  via NIP-35. `pubkey` is an npub or 64-char hex; route is direct|i2p. */
  async addFollow(pubkey: string, route: Route): Promise<{ id: string }> {
    const res = await this.fetch("/api/follows", {
      method: "POST",
      body: JSON.stringify({ pubkey, route }),
    });
    return this.json<{ id: string }>(res);
  }

  /** Unfollow. The daemon joins the mirror's worker threads before answering,
   *  which can take a few seconds if a relay query is mid-flight. */
  async removeFollow(id: string): Promise<void> {
    const res = await this.fetch(`/api/follows/${id}`, {
      method: "DELETE",
      signal: AbortSignal.timeout(SESSION_SETUP_TIMEOUT_MS),
    });
    if (!res.ok && res.status !== 404) {
      throw new Error(`${res.status} ${res.statusText}`);
    }
  }

  async search(query: string): Promise<DiscoverResult[]> {
    const res = await this.fetch("/api/search", {
      method: "POST",
      body: JSON.stringify({ query }),
    });
    return this.json<DiscoverResult[]>(res);
  }

  /** Update any subset of settings (route, downloadDir, relays). */
  async updateSettings(patch: {
    route?: Route;
    downloadDir?: string;
    relays?: string[];
  }): Promise<Settings> {
    const res = await this.fetch("/api/settings", {
      method: "POST",
      body: JSON.stringify(patch),
    });
    return this.json<Settings>(res);
  }

  setRoute(route: Route): Promise<Settings> {
    return this.updateSettings({ route });
  }

  /**
   * Upload a local file and start seeding it. The daemon hashes it into a
   * torrent in-process. The file bytes are the request body; metadata rides in
   * headers. Works from a browser drag-drop or the Tauri shell.
   */
  async createSeed(
    file: File,
    route: Route,
    nostr: boolean,
  ): Promise<{ id: string }> {
    if (file.size > MAX_SEED_BYTES) {
      const mib = (n: number) => Math.round(n / (1024 * 1024));
      throw new Error(
        `file is ${mib(file.size)} MiB; the daemon accepts up to ${mib(MAX_SEED_BYTES)} MiB`,
      );
    }
    const bytes = await file.arrayBuffer();
    const res = await fetch(`${this.cfg.base}/api/seeds`, {
      method: "POST",
      headers: {
        "X-Carl-Token": this.cfg.token,
        "X-Carl-Filename": file.name,
        "X-Carl-Route": route,
        "X-Carl-Nostr": String(nostr),
        "Content-Type": "application/octet-stream",
      },
      body: bytes,
      // A tor/i2p seed stands up its network session before responding; bound
      // the wait generously rather than hang forever or abort mid-setup.
      signal: AbortSignal.timeout(SESSION_SETUP_TIMEOUT_MS),
    });
    return this.json<{ id: string }>(res);
  }

  /**
   * Build a .torrent on disk from a server-side path (a file OR a directory).
   * Unlike createSeed this uploads no bytes — folders can't be a single body —
   * so the daemon reads `path` directly and writes `<path>.torrent` (or the
   * daemon's chosen location). Trackers are optional (Nostr/DHT discovery).
   * Returns the written path, info-hash, total size, and file count.
   */
  async createTorrent(
    path: string,
    trackers: string[],
    comment?: string,
  ): Promise<CreateTorrentResult> {
    const res = await this.fetch("/api/torrents", {
      method: "POST",
      body: JSON.stringify({ path, trackers, comment }),
    });
    return this.json<CreateTorrentResult>(res);
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
