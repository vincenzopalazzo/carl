// data.jsx — mock domain data for carl
// All distros/media below are real FOSS / public-domain releases.

const TRANSFERS = [
  {
    id: "t1",
    name: "debian-12.5.0-amd64-netinst.iso",
    hash: "a1d9f3c2e7b48f10c9a6d2e5f8b3071c4e9a2d6f",
    magnet: "magnet:?xt=urn:btih:a1d9f3c2e7b48f10c9a6d2e5f8b3071c4e9a2d6f&dn=debian-12.5.0",
    status: "downloading",
    route: "direct",
    sources: ["tracker", "dht", "nostr"],
    pct: 64,
    size: 658 * 1024 * 1024,
    down: 4.2 * 1024 * 1024,
    up: 256 * 1024,
    eta: "1m 48s",
    peers: 38,
    seeds: 64,
    added: "today, 14:22",
  },
  {
    id: "t2",
    name: "archlinux-2026.06.01-x86_64.iso",
    hash: "7f2b9c4e1a8d603f5e2c7b09a4d6f813c0e5b27a",
    magnet: "magnet:?xt=urn:btih:7f2b9c4e1a8d603f5e2c7b09a4d6f813c0e5b27a&dn=archlinux-2026",
    status: "seeding",
    route: "tor",
    sources: ["nostr"],
    onion: "g7k3xqp4nfz2vw9d6r8slmc1ojtb5haeuyx0qprtkn9fwd2v3sba.onion",
    pct: 100,
    size: 1.12 * 1024 * 1024 * 1024,
    down: 0,
    up: 1.8 * 1024 * 1024,
    eta: "—",
    peers: 12,
    seeds: 0,
    ratio: 3.41,
    added: "3 days ago",
  },
  {
    id: "t3",
    name: "blender-4.2.0-source.tar.xz",
    hash: "c3e8a1f60d2b9745e1c8a3f7b04d62e9015c8b4d",
    magnet: "magnet:?xt=urn:btih:c3e8a1f60d2b9745e1c8a3f7b04d62e9015c8b4d&dn=blender-4.2.0",
    status: "downloading",
    route: "proxy",
    sources: ["dht", "nostr"],
    pct: 23,
    size: 412 * 1024 * 1024,
    down: 1.1 * 1024 * 1024,
    up: 48 * 1024,
    eta: "6m 12s",
    peers: 9,
    seeds: 14,
    added: "today, 15:03",
  },
  {
    id: "t4",
    name: "nixos-25.05-minimal-x86_64.iso",
    hash: "5b1c7e3a9f2d8460c7e1b5a8f3d29c604e7a1f8b",
    magnet: "magnet:?xt=urn:btih:5b1c7e3a9f2d8460c7e1b5a8f3d29c604e7a1f8b&dn=nixos-25.05",
    status: "complete",
    route: "direct",
    sources: ["tracker", "dht"],
    pct: 100,
    size: 892 * 1024 * 1024,
    down: 0,
    up: 0,
    eta: "—",
    peers: 0,
    seeds: 0,
    ratio: 0.92,
    added: "yesterday",
  },
  {
    id: "t5",
    name: "tails-amd64-6.4.img",
    hash: "9e4d2a7c1f8b3056e9a2d4c7f1b80d35a6e9c243",
    magnet: "magnet:?xt=urn:btih:9e4d2a7c1f8b3056e9a2d4c7f1b80d35a6e9c243&dn=tails-6.4",
    status: "metadata",
    route: "tor",
    sources: ["nostr"],
    pct: 0,
    size: null,
    down: 0,
    up: 0,
    eta: "—",
    peers: 3,
    seeds: 0,
    added: "today, 15:10",
  },
  {
    id: "t6",
    name: "ubuntu-26.04-desktop-amd64.iso",
    hash: "2c8f1b6e4a9d7350f2c1e8b4a7d96035e1c8a4f7",
    magnet: "magnet:?xt=urn:btih:2c8f1b6e4a9d7350f2c1e8b4a7d96035e1c8a4f7&dn=ubuntu-26.04",
    status: "stalled",
    route: "proxy",
    sources: ["dht", "nostr"],
    pct: 47,
    size: 4.7 * 1024 * 1024 * 1024,
    down: 0,
    up: 0,
    eta: "stalled",
    peers: 0,
    seeds: 0,
    added: "today, 12:40",
  },
  {
    id: "t7",
    name: "LibreOffice_24.8_macOS_aarch64.dmg",
    hash: "8a3f6c1e9b2d7045c8a1f3e6b9d40725e8a3c1f6",
    magnet: "magnet:?xt=urn:btih:8a3f6c1e9b2d7045c8a1f3e6b9d40725e8a3c1f6&dn=LibreOffice-24.8",
    status: "seeding",
    route: "direct",
    sources: ["tracker", "dht"],
    pct: 100,
    size: 348 * 1024 * 1024,
    down: 0,
    up: 412 * 1024,
    eta: "—",
    peers: 5,
    seeds: 0,
    ratio: 1.74,
    added: "5 days ago",
  },
];

// peers for the expanded (debian) row
const PEERS = [
  { addr: "188.40.62.17", port: 51413, client: "carl/0.9.2", down: 1.4 * 1024 * 1024, up: 84 * 1024, pct: 100, flags: "DUE" },
  { addr: "94.130.12.88", port: 6881, client: "Transmission 4.0.6", down: 880 * 1024, up: 22 * 1024, pct: 100, flags: "DU" },
  { addr: "g7k3xqp4nfz2vw9d6r8slmc1ojtb5haeuyx0qprtkn9fwd2v3sba.onion", port: 0, client: "carl/0.9.2", down: 720 * 1024, up: 0, pct: 88, flags: "DE", onion: true },
  { addr: "tkn9fwd2v3sbag7k3xqp4nfz2vw9d6r8slmc1ojtb5haeuyx0qprt.onion", port: 0, client: "libtorrent 2.0.10", down: 512 * 1024, up: 0, pct: 73, flags: "D", onion: true },
  { addr: "37.221.193.4", port: 51820, client: "qBittorrent 4.6.5", down: 420 * 1024, up: 0, pct: 64, flags: "Du" },
  { addr: "159.69.201.55", port: 6889, client: "Deluge 2.1.1", down: 0, up: 0, pct: 100, flags: "UE" },
];

// piece heatmap state: 0 missing, 1 have, 2 downloading
function makePieces(n, pct) {
  const have = Math.floor((pct / 100) * n);
  return Array.from({ length: n }, (_, i) => {
    if (i < have) return 1;
    if (i < have + 6 && pct < 100) return i % 2 === 0 ? 2 : 0;
    return 0;
  });
}
const PIECES = makePieces(360, 64);

const FILES = [
  { name: "debian-12.5.0-amd64-netinst.iso", size: 658 * 1024 * 1024, pct: 64, prio: "normal" },
  { name: "SHA256SUMS", size: 142, pct: 100, prio: "high" },
  { name: "SHA256SUMS.sign", size: 833, pct: 100, prio: "high" },
];

const SOURCES = [
  { kind: "tracker", label: "udp://tracker.debian.org:6969", state: "working", detail: "64 seeds · 38 leechers", interval: "next in 14m" },
  { kind: "tracker", label: "udp://explodie.org:6969/announce", state: "working", detail: "12 seeds · 4 leechers", interval: "next in 9m" },
  { kind: "dht", label: "Distributed Hash Table", state: "working", detail: "1,284 nodes · 22 peers", interval: "—" },
  { kind: "nostr", label: "Nostr peer-announce (NIP-35)", state: "working", detail: "announced to 4 relays · 7 peers", interval: "next in 2m" },
];

// Discover (Nostr NIP-35 search results)
const DISCOVER = [
  {
    id: "d1",
    title: "Debian 12.5 — Full DVD set (amd64)",
    hash: "a1d9f3c2e7b48f10c9a6d2e5f8b3071c4e9a2d6f",
    size: 3.7 * 1024 * 1024 * 1024,
    files: 3,
    trackers: 4,
    desc: "Official Debian 12.5 \u201cbookworm\u201d full DVD images, GPG-verified. Includes installer + offline package set.",
    verified: true,
    relays: ["relay.damus.io", "nos.lol", "relay.snort.social"],
    author: "npub1deb\u202622qx",
    age: "2h ago",
  },
  {
    id: "d2",
    title: "Sintel (2010) — Blender Open Movie · 4K",
    hash: "4e9a2d6fa1d9f3c2e7b48f10c9a6d2e5f8b3071c",
    size: 6.1 * 1024 * 1024 * 1024,
    files: 12,
    trackers: 2,
    desc: "Durian project short film, CC-BY 3.0. 4K ProRes master + 1080p H.264 + source .blend files.",
    verified: true,
    relays: ["relay.damus.io", "nostr.wine"],
    author: "npub1blnd\u20269f7k",
    age: "6h ago",
  },
  {
    id: "d3",
    title: "Big Buck Bunny — 60fps remaster",
    hash: "c0e5b27a7f2b9c4e1a8d603f5e2c7b09a4d6f813",
    size: 1.4 * 1024 * 1024 * 1024,
    files: 4,
    trackers: 3,
    desc: "Peach open movie, CC-BY 3.0. 60fps 1080p remaster with stems and poster art.",
    verified: true,
    relays: ["nos.lol", "relay.snort.social", "ws://relay onion"],
    author: "npub1peach\u202641dz",
    age: "1d ago",
  },
  {
    id: "d4",
    title: "Project Gutenberg — 2026 ebook archive",
    hash: "015c8b4dc3e8a1f60d2b9745e1c8a3f7b04d62e9",
    size: 78 * 1024 * 1024 * 1024,
    files: 73421,
    trackers: 1,
    desc: "Complete public-domain ebook corpus, EPUB + plaintext. Updated 2026-05-30.",
    verified: false,
    relays: ["relay.damus.io"],
    author: "npub1gtnbg\u20267xqa",
    age: "3d ago",
  },
  {
    id: "d5",
    title: "Wikipedia ZIM dump — en_all_nopic 2026-05",
    hash: "e7a1f8b5b1c7e3a9f2d8460c7e1b5a8f3d29c604",
    size: 102 * 1024 * 1024 * 1024,
    files: 1,
    trackers: 2,
    desc: "Kiwix ZIM, English Wikipedia, no images. For offline / air-gapped reading.",
    verified: true,
    relays: ["nos.lol", "relay.nostr.band"],
    author: "npub1kiwix\u2026m0r3",
    age: "4d ago",
  },
];

// Nostr relays (shared: settings + discover strip)
const RELAYS = [
  { url: "wss://relay.damus.io", state: "connected", net: "clearnet", events: 1284 },
  { url: "wss://nos.lol", state: "connected", net: "clearnet", events: 962 },
  { url: "wss://relay.snort.social", state: "connected", net: "clearnet", events: 511 },
  { url: "ws://nostrr5h7k3xqp4nfz2vw9d6r8slmc1ojt.onion", state: "connected", net: "tor", events: 88 },
  { url: "wss://relay.nostr.band", state: "unreachable", net: "clearnet", events: 0 },
  { url: "wss://nostr.wine", state: "connecting", net: "clearnet", events: 0 },
];

// Seeding
const SEEDS = [
  {
    id: "s1",
    name: "archlinux-2026.06.01-x86_64.iso",
    visibility: "tor",
    onion: "g7k3xqp4nfz2vw9d6r8slmc1ojtb5haeuyx0qprtkn9fwd2v3sba.onion",
    size: 1.12 * 1024 * 1024 * 1024,
    upTotal: 3.82 * 1024 * 1024 * 1024,
    up: 1.8 * 1024 * 1024,
    leechers: 12,
    ratio: 3.41,
    relays: 4,
  },
  {
    id: "s2",
    name: "LibreOffice_24.8_macOS_aarch64.dmg",
    visibility: "direct",
    size: 348 * 1024 * 1024,
    upTotal: 604 * 1024 * 1024,
    up: 412 * 1024,
    leechers: 5,
    ratio: 1.74,
    relays: 3,
  },
  {
    id: "s3",
    name: "field-recordings-2025.flac.tar",
    visibility: "proxy",
    size: 2.3 * 1024 * 1024 * 1024,
    upTotal: 1.1 * 1024 * 1024 * 1024,
    up: 96 * 1024,
    leechers: 2,
    ratio: 0.48,
    relays: 4,
  },
];

Object.assign(window, {
  TRANSFERS, PEERS, PIECES, FILES, SOURCES, DISCOVER, RELAYS, SEEDS, makePieces,
});
