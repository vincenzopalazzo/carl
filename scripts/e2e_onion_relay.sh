#!/usr/bin/env bash
#
# End-to-end test for ws:// onion relay tunneling (issue #30).
#
# Proves that carl reaches a Nostr relay entirely over the proxy with no IP
# leak: it stands up a mock relay on a remote host, publishes it as a Tor v3
# onion, and then runs `carl search` against ws://<onion> through the local Tor
# SOCKS proxy. A hit means the WebSocket rode the Tor circuit end to end -- the
# relay only ever saw Tor, never our IP.
#
# Requires: local Tor SOCKS (default 127.0.0.1:9050), SSH access to a host that
# runs Tor with a ControlPort + a readable control cookie, and python3 +
# `websockets` on that host.
#
# Env overrides:
#   CARL         carl binary                 (default ./zig-out/bin/carl)
#   SERVER       ssh target running Tor      (default vincent@65.108.246.14)
#   SSH_KEY      ssh identity file
#   PROXY        local Tor SOCKS for carl     (default socks5h://127.0.0.1:9050)
#   QUERY        search term                  (default bitcoin)
#   EXPECT       string the result must contain (default the whitepaper infohash)
#   ONION_WAIT   seconds to wait for the descriptor to publish (default 35)
set -euo pipefail

CARL=${CARL:-./zig-out/bin/carl}
SERVER=${SERVER:-vincent@65.108.246.14}
SSH_KEY=${SSH_KEY:-}
PROXY=${PROXY:-socks5h://127.0.0.1:9050}
QUERY=${QUERY:-bitcoin}
EXPECT=${EXPECT:-08d72b48f0799bbf62a2dc54cb66cb1ed14f9431}
ONION_WAIT=${ONION_WAIT:-35}
# ws (plain, Tor-encrypted) or wss (TLS over the proxied stream).
SCHEME=${SCHEME:-ws}
[ "$SCHEME" = "wss" ] && RELAY_TLS=1 || RELAY_TLS=0

here=$(cd "$(dirname "$0")" && pwd)
mock_local="$here/onion_mock_relay.py"
mock_remote=/tmp/carl_onion_mock_relay.py

ssh_opts=(-o ConnectTimeout=10)
scp_opts=(-o ConnectTimeout=10)
[ -n "$SSH_KEY" ] && { ssh_opts+=(-i "$SSH_KEY"); scp_opts+=(-i "$SSH_KEY"); }

fail() { echo "E2E FAIL: $*" >&2; exit 1; }

[ -x "$CARL" ] || fail "carl binary not found/executable at '$CARL'"
[ -f "$mock_local" ] || fail "mock relay not found at $mock_local"

# Stop any prior mock (match a unique token, not 'mock_relay', to avoid killing
# this very ssh command's shell), then launch a fresh one detached.
cleanup() {
  ssh "${ssh_opts[@]}" "$SERVER" "pkill -f carl_onion_mock_relay.py" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> deploying mock onion relay to $SERVER"
scp "${scp_opts[@]}" "$mock_local" "$SERVER:$mock_remote" >/dev/null || fail "scp failed"
cleanup
ssh "${ssh_opts[@]}" "$SERVER" "RELAY_TLS=$RELAY_TLS setsid python3 $mock_remote >/tmp/carl_onion_mock.log 2>&1 </dev/null & echo launched" >/dev/null \
  || fail "could not launch mock relay"

echo "==> waiting for the onion address"
onion=""
for _ in $(seq 1 20); do
  onion=$(ssh "${ssh_opts[@]}" "$SERVER" "grep -m1 '^ONION ' /tmp/carl_onion_mock.log 2>/dev/null | awk '{print \$2}'" || true)
  [ -n "$onion" ] && break
  sleep 2
done
[ -n "$onion" ] || fail "mock relay never reported an onion (check websockets / Tor cookie on $SERVER)"
echo "    $onion"

echo "==> waiting ${ONION_WAIT}s for the onion descriptor to publish"
sleep "$ONION_WAIT"

echo "==> carl search '$QUERY' via $SCHEME://$onion over $PROXY"
log=$(mktemp); trap 'rm -f "$log"; cleanup' EXIT
if ! timeout 100 "$CARL" search "$QUERY" --relay "$SCHEME://$onion" --proxy "$PROXY" >"$log" 2>&1; then
  sed 's/^/    | /' "$log" >&2
  fail "carl search exited non-zero (could not reach the onion relay)"
fi

if grep -qi "failed" "$log"; then
  sed 's/^/    | /' "$log" >&2
  fail "relay connection reported a failure"
fi
if ! grep -q "$EXPECT" "$log"; then
  sed 's/^/    | /' "$log" >&2
  fail "expected '$EXPECT' not found in results -- the onion relay roundtrip did not return the event"
fi

echo "E2E PASS: reached $SCHEME://$onion over Tor and got the signed event (matched '$EXPECT')"
