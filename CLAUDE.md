# Carl - BitTorrent Light Client

## References

- BEP Index: https://www.bittorrent.org/beps/bep_0000.html
- BEP 3 (The BitTorrent Protocol): https://www.bittorrent.org/beps/bep_0003.html
- BEP 7 (IPv6 Tracker Extension): https://www.bittorrent.org/beps/bep_0007.html
- BEP 5 (DHT Protocol): https://www.bittorrent.org/beps/bep_0005.html
- BEP 10 (Extension Protocol): https://www.bittorrent.org/beps/bep_0010.html
- NIP-01 (Nostr basic protocol): https://github.com/nostr-protocol/nips/blob/master/01.md
- NIP-19 (bech32 entities): https://github.com/nostr-protocol/nips/blob/master/19.md
- NIP-35 (Torrents): https://github.com/nostr-protocol/nips/blob/master/35.md
- BIP-340 (Schnorr): https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki
- RFC 6455 (WebSocket): https://datatracker.ietf.org/doc/html/rfc6455

## Build

- Language: Zig 0.15
- Build: `zig build`
- Test: `zig build test`
- Format: `zig fmt src/`

## Install (always use a fresh binary)

Whenever you test `carl` by hand or run it via `$PATH`, rebuild and reinstall
first so you are never running a stale binary (a stale `~/.local/bin/carl`
silently produces wrong results — e.g. a 0-byte `unknown` file). After any code
change, before manual/e2e testing:

```sh
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/carl ~/.local/bin/carl   # the binary `carl` on $PATH resolves to
```

Prefer invoking the freshly built `./zig-out/bin/carl` directly in scripts, and
keep the installed `~/.local/bin/carl` in sync after every change.
