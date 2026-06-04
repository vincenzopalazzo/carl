#!/usr/bin/env bash
#
# End-to-end download test: pull a file from a live carl seeder over nostr and
# verify the bytes match BOTH the canonical source and the server's copy.
#
# It does NOT trust carl's own "download complete!". It independently obtains
# three hashes and requires all of them to agree:
#
#   1. the canonical file freshly downloaded from OFFICIAL_URL (bitcoin.org)
#   2. the file the server is seeding (hashed over SSH)
#   3. the file carl downloaded for us
#
# All three matching proves we downloaded the GENUINE whitepaper end-to-end --
# not merely whatever happened to be on the server.
#
# Everything is overridable via environment variables so this works for any
# carl seed:
#
#   CARL         path to the carl binary            (default ./zig-out/bin/carl)
#   MAGNET       magnet link to download            (default the whitepaper)
#   SERVER       ssh target running `carl seed`     (default vincent@65.108.246.14)
#   SERVER_FILE  path to the seeded file on SERVER  (default ~/seed/bitcoin/bitcoin.pdf)
#   FILE_NAME    expected downloaded filename       (default bitcoin.pdf)
#   OFFICIAL_URL canonical source to verify against (default https://bitcoin.org/bitcoin.pdf;
#                                                     set empty to skip this check)
#   PROXY        optional carl --proxy URL          (e.g. socks5h://127.0.0.1:9050 for a Tor seed)
#   SSH_KEY      optional ssh identity file
#   TIMEOUT      seconds to allow the download       (default 180)
#
# Exit status: 0 on a verified match, non-zero otherwise.
#
# Examples:
#   scripts/e2e_download.sh                                   # clearnet IP seeder
#   PROXY=socks5h://127.0.0.1:9050 scripts/e2e_download.sh    # Tor onion seeder
set -euo pipefail

CARL=${CARL:-./zig-out/bin/carl}
MAGNET=${MAGNET:-'magnet:?xt=urn:btih:08d72b48f0799bbf62a2dc54cb66cb1ed14f9431'}
SERVER=${SERVER:-vincent@65.108.246.14}
SERVER_FILE=${SERVER_FILE:-'~/seed/bitcoin/bitcoin.pdf'}
FILE_NAME=${FILE_NAME:-bitcoin.pdf}
OFFICIAL_URL=${OFFICIAL_URL-https://bitcoin.org/bitcoin.pdf}
PROXY=${PROXY:-}
SSH_KEY=${SSH_KEY:-}
TIMEOUT=${TIMEOUT:-180}

ssh_opts=(-o ConnectTimeout=10)
[ -n "$SSH_KEY" ] && ssh_opts+=(-i "$SSH_KEY")

# sha256 <file> -> lowercase hex digest (portable: Linux sha256sum / macOS shasum)
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "error: no sha256sum/shasum available" >&2
    return 1
  fi
}

fail() { echo "E2E FAIL: $*" >&2; exit 1; }

[ -x "$CARL" ] || fail "carl binary not found/executable at '$CARL' (build with 'zig build' or set CARL=...)"

out_dir=$(mktemp -d)
log=$(mktemp)
trap 'rm -rf "$out_dir" "$log"' EXIT

# 1. Canonical source -- a fresh download from the authoritative URL.
official_hash=""
if [ -n "$OFFICIAL_URL" ]; then
  echo "==> canonical source ($OFFICIAL_URL)"
  official_file="$out_dir/.official"
  curl -fsSL --retry 2 -o "$official_file" "$OFFICIAL_URL" \
    || fail "could not fetch canonical file from $OFFICIAL_URL"
  official_hash=$(sha256 "$official_file")
  echo "    $official_hash  ($(wc -c < "$official_file" | tr -d ' ') bytes)"
fi

# 2. The file the server is actually seeding (source of truth #2).
echo "==> server file hash ($SERVER:$SERVER_FILE)"
remote_hash=$(ssh "${ssh_opts[@]}" "$SERVER" "sha256sum $SERVER_FILE 2>/dev/null | awk '{print \$1}'") \
  || fail "could not reach server or read seeded file"
[ -n "$remote_hash" ] || fail "server returned an empty hash (is $SERVER_FILE present?)"
echo "    $remote_hash"

# If we have a canonical hash, the server must actually be seeding THAT file.
if [ -n "$official_hash" ] && [ "$official_hash" != "$remote_hash" ]; then
  fail "server is not seeding the canonical file (server $remote_hash != official $official_hash)"
fi

# 3. Download through carl and hash what we received.
proxy_args=()
[ -n "$PROXY" ] && proxy_args=(--proxy "$PROXY")

echo "==> downloading via carl (timeout ${TIMEOUT}s)${PROXY:+ over $PROXY}"
if ! timeout "$TIMEOUT" "$CARL" download "$MAGNET" --nostr "${proxy_args[@]}" \
       --output-dir "$out_dir" >"$log" 2>&1; then
  rc=$?
  sed 's/^/    | /' "$log" >&2
  [ "$rc" = 124 ] && fail "download did not finish within ${TIMEOUT}s (carl should exit on completion)"
  fail "carl exited non-zero ($rc)"
fi

# carl must terminate on its own and leave a clean run (no leaks / panics).
if grep -qiE 'leaked|error\(gpa\)|panic|segmentation' "$log"; then
  sed 's/^/    | /' "$log" >&2
  fail "carl reported a leak/panic on exit"
fi

local_file="$out_dir/$FILE_NAME"
[ -f "$local_file" ] || fail "expected downloaded file '$FILE_NAME' not found in output dir"

echo "==> downloaded file hash ($local_file)"
local_hash=$(sha256 "$local_file")
echo "    $local_hash"

# Final gate: the downloaded bytes must equal the server's (and, if checked, the
# canonical source's -- already asserted equal to the server's above).
if [ "$local_hash" != "$remote_hash" ]; then
  fail "hash mismatch -- downloaded file differs from the server's copy"
fi

bytes=$(wc -c < "$local_file" | tr -d ' ')
if [ -n "$official_hash" ]; then
  echo "E2E PASS: canonical == server == downloaded ($FILE_NAME, $bytes bytes, sha256 $local_hash)"
else
  echo "E2E PASS: downloaded $FILE_NAME ($bytes bytes) matches the server (sha256 $local_hash)"
fi
