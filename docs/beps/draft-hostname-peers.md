# Draft: hostname peers in BEP 3 dictionary responses

**Status:** in-repo draft (not submitted to bittorrent.org)  
**Applies to:** BEP 3 tracker announce — dictionary `peers` list only  
**Non-goals:** compact peer lists, BEP 5 DHT values, public UDP trackers

## Problem

BEP 3 compact `peers` is a concatenation of 6-byte records (`IPv4` + port).
BEP 5 DHT values are the same compact form (BEP 32 adds IPv6). Neither encoding
has a field for a Tor v3 `.onion` or an I2P `.b32.i2p` destination.

A hidden-service seed therefore **cannot** be announced to, or discovered from,
a compact-only tracker or the clearnet DHT without either:

- leaking a clearnet IP (the TCP source of the announce), or
- stuffing a non-IP into a 4-byte field (not interoperable).

BEP 3 already allows a **non-compact** `peers` value: a list of dictionaries
with keys `peer id`, `ip`, `port`. The spec says `ip` is “an IPv4 (dotted
quad), IPv6 (hex) or **dns name**.” This draft pins down what “dns name”
means for hidden services and what a client must **not** do.

## Dictionary `ip` as a hidden-service hostname

When `peers` is a list of dicts, `ip` MAY be:

| Form | Example | Dial |
|------|---------|------|
| IPv4 dotted quad | `192.0.2.1` | TCP (or SOCKS if the session is proxied) |
| Tor v3 onion | `xxxxxxxx…xxxx.onion` (56 base32 chars + `.onion`) | SOCKS5h |
| I2P base32 dest | `xxxxxxxx…xxxx.b32.i2p` (52 base32 chars + `.b32.i2p`) | I2P SAM STREAM |

`port` is the virtual port the leecher should request (Tor onion map, I2P
`TO_PORT`; `0` is allowed for I2P and means the destination default).

Compact `peers` (6-byte IPv4, 18-byte IPv6) is **unchanged**. Clients MUST NOT
encode a hostname in compact form.

## Fail-closed announce

A client whose reachable endpoint is a hidden service MUST NOT send a tracker
announce that would reveal a clearnet IP:

- `--tor-seed`: no announce to a clearnet HTTP/UDP tracker (the tracker would
  record the exit or the real IP). Discovery stays Nostr kind 30078 and any
  **Tor-reachable** HTTP tracker that returns dictionary hostname peers.
- `--i2p-seed` / `--route i2p`: announce only to HTTP trackers whose host is
  `.i2p`, over SAM STREAM. Skip every clearnet `http://` / `udp://` URL.
- `--proxy` without a hidden service: announce may be tunneled (SOCKS), but
  compact still describes IPv4 as seen by the tracker (usually an exit). That
  is the existing proxy path; this draft does not change it.

## Host wins

If a dictionary peer (or a signed Nostr announce) carries both a hostname and
an IPv4, the hostname **wins**. A client MUST NOT dial the IPv4 in that case.
This matches Carl kind 30078 (`host` preferred over `ip`) so a signed event
cannot smuggle a clearnet endpoint next to an onion.

## Mapping to Nostr kind 30078

| Tracker dict | Kind 30078 tag |
|--------------|----------------|
| `ip` = hostname | `host` |
| `port` | `port` |
| (infohash of the torrent) | `d` (hex) |

Same string, same port. A peer found either way is dialed with the same
`connectOnionPeer` / `connectI2pPeer` path.

## Interop

This draft is the **Tor hostname** half. I2P clients that already speak
I2P-BT (i2psnark, qBittorrent I2P) use HTTP-over-SAM to `.i2p` trackers and
may return destinations in tracker-specific bodies; see
[i2p-bt-tracker.md](i2p-bt-tracker.md). Carl accepts `.b32.i2p` in the BEP 3
dict `ip` field so a tracker that uses the dns-name clause interops without a
second parser.

## Tests a client should have

- Compact IPv4 still parses; no hostname ever appears in compact.
- Dict `ip=192.0.2.1` still yields an IPv4 peer.
- Dict `ip=<v3>.onion` / `ip=<b32>.b32.i2p` yields a hostname peer, not IPv4.
- Invalid onion / truncated `.b32.i2p` is skipped, not fatal.
- I2P session never dials a dict IPv4 peer (IP leak).
