#!/usr/bin/env bash
#
# End-to-end test for `carl drive` (Nostr shared drives, kind 30035).
#
# Runs the full convergence scenario on one machine:
#
#   STAGE 1  publish + initial sync: A drops file1.txt, B's mirror converges
#   STAGE 2  edit propagation: A appends to file1.txt, B converges to the NEW
#            bytes (proves a re-fetch, not a stale copy)
#   STAGE 3  delete quarantine: A removes file1.txt, B's copy moves into
#            .carl-drive/.trash/ (never unlinked)
#
# It does NOT trust carl's logs. Every stage independently sha256-hashes both
# sides with shasum/sha256sum and requires them to agree (stage 3 checks the
# filesystem layout directly).
#
# Topology: two carl processes with SEPARATE config dirs (separate Nostr
# identities, per XDG_CONFIG_HOME) talking through one relay. By default the
# script starts its own embedded mock relay (a tiny in-memory Nostr relay
# written to a temp file -- scripts/onion_mock_relay.py can't be used: it is
# onion-specific and only replays one canned kind-2003 event, while a drive
# needs a real store for kind-30035/30078 events). Set RELAY to use an
# existing relay instead.
#
# Route: default i2p. The direct route can't converge in this test: although
# `carl drive create --route direct --external-ip <ip>` does publish a
# dialable kind-30078 announce, carl rejects loopback/private IPv4 announces
# by design, and two instances on one host have no routable address to
# publish. See docs/drive.md ("Direct route needs --external-ip").
#
# Env overrides:
#   CARL       carl binary                    (default ./zig-out/bin/carl)
#   BUILD      rebuild + install carl first   (default 1; set 0 to skip)
#   ROUTE      drive route                    (default i2p; only i2p converges)
#   I2P_SAM    SAM bridge host:port           (default 127.0.0.1:7656)
#   RELAY      existing relay URL to use      (default: start embedded mock)
#   MOCK_PORT  port for the embedded relay    (default 18778)
#   DRIVE_NAME drive name                     (default e2e)
#   POLL       scan/poll interval in seconds  (default 2)
#   TIMEOUT    per-stage deadline in seconds  (default 300)
#   PYTHON     python3 with `websockets`      (default python3)
#
# Exit status: 0 when all three stages pass, non-zero otherwise.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

CARL=${CARL:-$repo/zig-out/bin/carl}
BUILD=${BUILD:-1}
ROUTE=${ROUTE:-i2p}
I2P_SAM=${I2P_SAM:-127.0.0.1:7656}
RELAY=${RELAY:-}
MOCK_PORT=${MOCK_PORT:-18778}
DRIVE_NAME=${DRIVE_NAME:-e2e}
POLL=${POLL:-2}
TIMEOUT=${TIMEOUT:-300}
PYTHON=${PYTHON:-python3}

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

results=()
record() { results+=("$1"); echo "$1"; }

summary() {
  echo "==> stage summary"
  for r in ${results[@]+"${results[@]}"}; do echo "    $r"; done
}

dump_logs() {
  for f in "$@"; do
    [ -f "$f" ] || continue
    echo "    --- tail $f ---" >&2
    tail -n 30 "$f" | sed 's/^/    | /' >&2
  done
}

fail_stage() { # <stage-name> <why>
  record "FAIL: $1 -- $2"
  dump_logs "$work/pub.log" "$work/sub.log" "$work/relay.log"
  summary
  echo "E2E FAIL: stage '$1': $2" >&2
  exit 1
}

# wait_until <deadline-secs> <description> <check-command...>
wait_until() {
  local deadline=$(( $(date +%s) + $1 )) desc=$2
  shift 2
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "    (timed out waiting for: $desc)" >&2
  return 1
}

# --- preflight ---------------------------------------------------------------

if [ "$BUILD" = "1" ]; then
  echo "==> rebuilding carl (ReleaseSafe) and installing to ~/.local/bin"
  export PATH="/opt/homebrew/bin:$PATH"
  (cd "$repo" && zig build -Doptimize=ReleaseSafe) || { echo "E2E FAIL: zig build failed" >&2; exit 1; }
  mkdir -p "$HOME/.local/bin"
  cp "$repo/zig-out/bin/carl" "$HOME/.local/bin/carl"
fi

[ -x "$CARL" ] || { echo "E2E FAIL: carl binary not found/executable at '$CARL'" >&2; exit 1; }

if [ -z "$RELAY" ]; then
  # Find a python that has `websockets`: the requested one first, then plain
  # python3, then the system python (a Homebrew python shadows the user's
  # Xcode python, and pip --user installs land per-interpreter).
  found_py=""
  for py in "$PYTHON" python3 /usr/bin/python3; do
    command -v "$py" >/dev/null 2>&1 || continue
    if "$py" -c "import websockets" 2>/dev/null; then found_py=$py; break; fi
  done
  [ -n "$found_py" ] || {
    echo "E2E FAIL: no python with the 'websockets' package found (tried $PYTHON, python3, /usr/bin/python3);" >&2
    echo "          install it (pip install --user websockets) or set RELAY=ws://... to use an existing relay" >&2
    exit 1
  }
  PYTHON=$found_py
fi

if [ "$ROUTE" = "i2p" ]; then
  sam_host=${I2P_SAM%:*}; sam_port=${I2P_SAM#*:}
  "$PYTHON" -c "import socket,sys; s=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=5); s.close()" "$sam_host" "$sam_port" 2>/dev/null || {
    echo "E2E FAIL: no I2P SAM bridge at $I2P_SAM (route i2p needs a local I2P router with SAM enabled)" >&2
    exit 1
  }
fi

# --- workspace ---------------------------------------------------------------

work=$(mktemp -d)
A_DIR="$work/a-drive"
B_DIR="$work/b-drive"
A_CFG="$work/cfg-a"
B_CFG="$work/cfg-b"
mkdir -p "$A_DIR" "$B_DIR" "$A_CFG/carl" "$B_CFG/carl"

PUB_PID="" SUB_PID="" RELAY_PID=""
cleanup() {
  [ -n "$PUB_PID" ] && kill "$PUB_PID" 2>/dev/null || true
  [ -n "$SUB_PID" ] && kill "$SUB_PID" 2>/dev/null || true
  [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true
  wait 2>/dev/null || true
  if [ "${KEEP:-0}" = "1" ]; then
    echo "    (KEEP=1: workspace left at $work)" >&2
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

# --- relay -------------------------------------------------------------------

RELAY_URL=$RELAY
if [ -z "$RELAY_URL" ]; then
  RELAY_URL="ws://127.0.0.1:$MOCK_PORT"
  echo "==> starting embedded mock relay on $RELAY_URL"
  cat > "$work/mock_relay.py" <<'PY'
"""Tiny in-memory Nostr relay for the carl-drive e2e: stores EVENTs (with
NIP-33 parameterized-replaceable semantics for kinds 30000-39999), answers
every REQ with the matching stored events + EOSE, and OKs every EVENT."""
import asyncio
import json
import os

import websockets

EVENTS = []  # list of event dicts


def tag_values(ev, name):
    return [t[1] for t in ev.get("tags", []) if len(t) > 1 and t[0] == name]


def d_tag(ev):
    vals = tag_values(ev, "d")
    return vals[0] if vals else None


def matches(ev, filt):
    kinds = filt.get("kinds")
    if kinds and ev.get("kind") not in kinds:
        return False
    authors = filt.get("authors")
    if authors and ev.get("pubkey") not in authors:
        return False
    for key, wanted in filt.items():
        if isinstance(key, str) and key.startswith("#"):
            have = tag_values(ev, key[1:])
            if not any(w in have for w in wanted):
                return False
    return True


async def handler(ws):
    async for raw in ws:
        try:
            msg = json.loads(raw)
        except Exception:
            continue
        if not isinstance(msg, list) or not msg:
            continue
        if msg[0] == "EVENT" and len(msg) > 1:
            ev = msg[1]
            kind = ev.get("kind", 0)
            if 30000 <= kind < 40000:  # NIP-33: replace per (pubkey, kind, d)
                for i, old in enumerate(EVENTS):
                    if (old.get("kind") == kind and old.get("pubkey") == ev.get("pubkey")
                            and d_tag(old) == d_tag(ev)):
                        if ev.get("created_at", 0) > old.get("created_at", 0):
                            EVENTS[i] = ev
                        break
                else:
                    EVENTS.append(ev)
            else:
                EVENTS.append(ev)
            await ws.send(json.dumps(["OK", ev.get("id", ""), True, ""]))
        elif msg[0] == "REQ" and len(msg) > 1:
            sub = msg[1]
            filt = msg[2] if len(msg) > 2 and isinstance(msg[2], dict) else {}
            for ev in list(EVENTS):
                if matches(ev, filt):
                    await ws.send(json.dumps(["EVENT", sub, ev]))
            await ws.send(json.dumps(["EOSE", sub]))


async def main():
    port = int(os.environ.get("MOCK_PORT", "18778"))
    async with websockets.serve(handler, "127.0.0.1", port):
        print(f"READY {port}", flush=True)
        await asyncio.Future()


asyncio.run(main())
PY
  MOCK_PORT=$MOCK_PORT "$PYTHON" "$work/mock_relay.py" > "$work/relay.log" 2>&1 &
  RELAY_PID=$!
  wait_until 15 "mock relay to listen on $MOCK_PORT" grep -q "READY" "$work/relay.log" || {
    dump_logs "$work/relay.log"
    echo "E2E FAIL: embedded mock relay did not start" >&2
    exit 1
  }
else
  echo "==> using existing relay $RELAY_URL"
  : > "$work/relay.log"
fi

# --- two identities, one relay ----------------------------------------------

echo "==> configuring two carl identities (A=publisher, B=subscriber)"
echo "$RELAY_URL" > "$A_CFG/carl/relays"
echo "$RELAY_URL" > "$B_CFG/carl/relays"
XDG_CONFIG_HOME=$A_CFG "$CARL" nostr-keygen > /dev/null
XDG_CONFIG_HOME=$B_CFG "$CARL" nostr-keygen > /dev/null
A_NPUB=$(XDG_CONFIG_HOME=$A_CFG "$CARL" whoami | awk '/^npub:/{print $2}')
[ -n "$A_NPUB" ] || { echo "E2E FAIL: could not read A's npub from \`carl whoami\`" >&2; exit 1; }
echo "    A npub: $A_NPUB"

# --- start the drives --------------------------------------------------------

printf 'carl drive e2e\nline 1: the quick brown fox\n' > "$A_DIR/file1.txt"

echo "==> starting publisher (A) and subscriber (B), route $ROUTE, poll ${POLL}s"
XDG_CONFIG_HOME=$A_CFG "$CARL" drive create "$A_DIR" --name "$DRIVE_NAME" \
  --route "$ROUTE" --interval "$POLL" > "$work/pub.log" 2>&1 &
PUB_PID=$!
XDG_CONFIG_HOME=$B_CFG "$CARL" drive subscribe "$A_NPUB" "$DRIVE_NAME" \
  --dir "$B_DIR" --route "$ROUTE" --interval "$POLL" > "$work/sub.log" 2>&1 &
SUB_PID=$!

# b_has_a_copy: exit 0 iff B's file1.txt exists and hashes equal to A's.
b_has_a_copy() {
  [ -f "$B_DIR/file1.txt" ] && [ -f "$A_DIR/file1.txt" ] &&
    [ "$(sha256 "$B_DIR/file1.txt")" = "$(sha256 "$A_DIR/file1.txt")" ]
}

# --- STAGE 1: publish + initial sync -----------------------------------------

echo "==> STAGE 1: initial sync (deadline ${TIMEOUT}s)"
if wait_until "$TIMEOUT" "B to mirror file1.txt" b_has_a_copy; then
  record "PASS: stage 1 initial sync -- $B_DIR/file1.txt matches A (sha256 $(sha256 "$B_DIR/file1.txt"))"
else
  fail_stage "stage 1 initial sync" "B never converged to A's file1.txt"
fi

# Let B's re-seed of the current version fully establish before the next
# mutation. This works around a known follow.Mirror eviction race (in src/,
# NOT worked around in the drive logic): Mirror.evictTransfer stops a
# transfer only via `live_session.running = false`; a transfer evicted while
# it is ENTERING seedForever -- in the seconds-wide window between the
# transferStopping check and publishSession (SAM session create + storage
# verify) -- has no live session yet, so it seeds forever and the eviction
# join hangs the whole drive loop. An edit/delete landing in that window
# kills convergence. Steady-state edits/deletes (what real users do) are
# unaffected, which is what this e2e verifies.
settle_reseed() { # <expected reseed count>
  local want=$1
  # "mirror seeding <title> at <b32>" is logged AFTER publishSession(), i.e.
  # once live_session is set and an eviction can actually stop the session.
  reseed_established() { [ "$(grep -c 'mirror seeding file1.txt at' "$work/sub.log" 2>/dev/null || echo 0)" -ge "$want" ]; }
  wait_until 90 "B re-seed #$want to establish" reseed_established || return 1
  sleep "$SETTLE"
}
SETTLE=${SETTLE:-5}
settle_reseed 1 || fail_stage "settle" "B's re-seed of the initial version never established"

# --- STAGE 2: edit propagation ------------------------------------------------

echo "==> STAGE 2: edit propagation (deadline ${TIMEOUT}s)"
printf 'line 2: appended by the publisher\n' >> "$A_DIR/file1.txt"
new_hash=$(sha256 "$A_DIR/file1.txt")
b_has_new_copy() {
  [ -f "$B_DIR/file1.txt" ] && [ "$(sha256 "$B_DIR/file1.txt")" = "$new_hash" ]
}
if wait_until "$TIMEOUT" "B to re-fetch the edited file1.txt" b_has_new_copy; then
  record "PASS: stage 2 edit -- B re-fetched and matches A's NEW content (sha256 $new_hash)"
else
  fail_stage "stage 2 edit" "B never converged to the edited file1.txt (stale or missing)"
fi

settle_reseed 2 || fail_stage "settle" "B's re-seed of the edited version never established"

# --- STAGE 3: delete -> quarantine --------------------------------------------

echo "==> STAGE 3: delete quarantine (deadline ${TIMEOUT}s)"
rm "$A_DIR/file1.txt"
b_quarantined() {
  [ ! -e "$B_DIR/file1.txt" ] &&
    ls "$B_DIR/.carl-drive/.trash/file1.txt"* >/dev/null 2>&1
}
if wait_until "$TIMEOUT" "B to quarantine file1.txt into .carl-drive/.trash" b_quarantined; then
  record "PASS: stage 3 delete -- B moved file1.txt to .carl-drive/.trash/ (never unlinked)"
else
  fail_stage "stage 3 delete" "B's file1.txt was not quarantined (still present, or vanished without trash)"
fi

summary
echo "E2E PASS: drive publish/edit/delete all converged over $ROUTE via $RELAY_URL"
