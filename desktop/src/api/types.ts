// Mirrors the carl daemon JSON contract (docs/daemon-api.md).

export type Route = "direct" | "proxy" | "tor";
export type Status =
  | "downloading"
  | "seeding"
  | "complete"
  | "metadata"
  | "stalled"
  | "connecting"
  | "no_peers";
export type SourceKind = "tracker" | "dht" | "nostr";

export interface Transfer {
  id: string;
  name: string;
  hash: string;
  magnet: string;
  status: Status;
  route: Route;
  sources: SourceKind[];
  pct: number;
  size: number | null;
  down: number;
  up: number;
  eta: string;
  peers: number;
  seeds: number;
  /** BEP 9 metadata pieces received / total during magnet bootstrap; both 0
   *  once metadata is in or for a non-magnet source. */
  metaHave: number;
  metaTotal: number;
  ratio: number | null;
  onion: string | null;
}

export interface Relay {
  url: string;
  state: "connected" | "connecting" | "unreachable" | "configured";
  net: "clearnet" | "tor";
  events: number;
}

export interface Seed {
  id: string;
  name: string;
  visibility: Route;
  onion: string | null;
  size: number;
  upTotal: number;
  up: number;
  leechers: number;
  ratio: number;
  relays: number;
}

export interface Identity {
  npub: string;
}

/** Health of the configured SOCKS proxy on the proxy/tor route. */
export interface ProxyHealth {
  state:
    | "disabled"
    | "checking"
    | "ok"
    | "not_running"
    | "timeout"
    | "rejected";
  endpoint: string;
  detail: string;
}

export interface Settings {
  route: Route;
  socks: string;
  relays: string[];
  downloadDir: string;
  listenPort: number;
  maxActive: number;
  peerLimit: number;
  publishNip35: boolean;
}

export interface CreateTorrentResult {
  /** Absolute path of the .torrent written on disk. */
  path: string;
  /** info-hash, lowercase hex (40 chars). */
  infoHash: string;
  /** Total size of the source content, bytes. */
  size: number;
  /** Number of files included. */
  files: number;
}

export interface DiscoverResult {
  id: string;
  title: string;
  hash: string;
  size: number;
  files: number;
  trackers: number;
  desc: string;
  verified: boolean;
  relays: string[];
  author: string;
  age: string;
}

export interface AppState {
  transfers: Transfer[];
  seeds: Seed[];
  relays: Relay[];
  proxy: ProxyHealth;
  identity: Identity;
  settings: Settings;
}

export const emptyState: AppState = {
  transfers: [],
  seeds: [],
  relays: [],
  proxy: { state: "disabled", endpoint: "", detail: "" },
  identity: { npub: "" },
  settings: {
    route: "direct",
    socks: "",
    relays: [],
    downloadDir: "",
    listenPort: 0,
    maxActive: 0,
    peerLimit: 0,
    publishNip35: false,
  },
};
