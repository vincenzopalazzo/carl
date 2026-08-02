#!/usr/bin/env bash
#
# Loopback throughput benchmark: one carl seeds, another carl leeches, both on
# 127.0.0.1, peers introduced by a stub HTTP tracker. Loopback removes the
# internet from the measurement, so the number that comes out is carl's own
# ceiling -- the seeder's upload path and the leecher's download path together,
# with no swarm, ISP, or web-seed variance in the way.
#
# Use it to compare a change against a baseline: run it on the base commit,
# run it again on the branch, and diff the MB/s.
#
#   SIZE_MB     test payload size in MiB          (default 256)
#   PIECE_LEN   piece length in bytes             (default 262144)
#   TIMEOUT     seconds to allow the transfer     (default 600)
#   CARL        path to the carl binary           (default ./zig-out/bin/carl)
#   KEEP        set to 1 to keep the work dir
#   DEAD_PEERS  blackhole peers the tracker lists BEFORE the real seeder
#               (default 0). This is the swarm case that matters: a tracker
#               hands back mostly-unreachable addresses. With serial blocking
#               dials, 40 dead peers x a 5s connect timeout meant the transfer
#               could not finish at all; they must be dialed concurrently and
#               timed out off the event loop.
#
# Exit status: 0 when the leecher's bytes match the seeder's, non-zero otherwise.
set -euo pipefail

CARL=${CARL:-./zig-out/bin/carl}
SIZE_MB=${SIZE_MB:-256}
PIECE_LEN=${PIECE_LEN:-262144}
TIMEOUT=${TIMEOUT:-600}
KEEP=${KEEP:-0}
DEAD_PEERS=${DEAD_PEERS:-0}

TRACKER_PORT=${TRACKER_PORT:-16969}
SEED_PORT=${SEED_PORT:-16881}
LEECH_PORT=${LEECH_PORT:-16882}

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
[ -x "$CARL" ] || { echo "carl binary not found at $CARL (run: zig build -Doptimize=ReleaseSafe)" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() {
  [ -n "${TRACKER_PID:-}" ] && kill "$TRACKER_PID" 2>/dev/null || true
  [ -n "${SEED_PID:-}" ] && kill "$SEED_PID" 2>/dev/null || true
  [ -n "${LEECH_PID:-}" ] && kill "$LEECH_PID" 2>/dev/null || true
  if [ "$KEEP" = "1" ]; then echo "work dir kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

mkdir -p "$WORK/seed" "$WORK/dl"

# --- stub tracker -----------------------------------------------------------
# Answers every announce with a single compact peer: the seeder on loopback.
# Compact format (BEP 23) is 6 bytes per peer: 4-byte IPv4 + 2-byte big-endian
# port. Nothing else about the announce matters for a two-node benchmark.
cat > "$WORK/tracker.py" <<PYEOF
import http.server, socket, struct, sys
SEED_PORT = int(sys.argv[1])
PORT = int(sys.argv[2])
DEAD = int(sys.argv[3])
# TEST-NET-2 (RFC 5737) is reserved for documentation and is not routed, so
# these connects hang until they time out -- the point of the exercise.
peer = b"".join(
    socket.inet_aton("198.51.100.%d" % (i % 254 + 1)) + struct.pack(">H", 6881)
    for i in range(DEAD)
)
peer += socket.inet_aton("127.0.0.1") + struct.pack(">H", SEED_PORT)
body = b"d8:intervali60e5:peers" + str(len(peer)).encode() + b":" + peer + b"e"

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF

python3 "$WORK/tracker.py" "$SEED_PORT" "$TRACKER_PORT" "$DEAD_PEERS" &
TRACKER_PID=$!
# Detach from job control so the shell doesn't print a "Terminated" notice for
# it when the cleanup trap fires.
disown "$TRACKER_PID" 2>/dev/null || true
sleep 1

# --- payload + torrent ------------------------------------------------------
echo "creating ${SIZE_MB}MiB payload..."
dd if=/dev/urandom of="$WORK/seed/payload.bin" bs=1m count="$SIZE_MB" 2>/dev/null
"$CARL" create "$WORK/seed/payload.bin" -o "$WORK/payload.torrent" \
  -t "http://127.0.0.1:${TRACKER_PORT}/announce" --piece-length "$PIECE_LEN" >/dev/null

# --- seed -------------------------------------------------------------------
"$CARL" seed "$WORK/payload.torrent" "$WORK/seed" --port "$SEED_PORT" > "$WORK/seed.log" 2>&1 &
SEED_PID=$!
sleep 2
kill -0 "$SEED_PID" 2>/dev/null || { echo "seeder died:"; cat "$WORK/seed.log"; exit 1; }

# --- leech + measure --------------------------------------------------------
echo "downloading..."
START=$(python3 -c 'import time; print(time.time())')
"$CARL" download "$WORK/payload.torrent" --output-dir "$WORK/dl" --port "$LEECH_PORT" \
  > "$WORK/leech.log" 2>&1 &
LEECH_PID=$!

DEADLINE=$(( $(date +%s) + TIMEOUT ))
while kill -0 "$LEECH_PID" 2>/dev/null; do
  [ "$(date +%s)" -gt "$DEADLINE" ] && { echo "TIMEOUT after ${TIMEOUT}s"; tail -5 "$WORK/leech.log"; exit 1; }
  sleep 1
done
END=$(python3 -c 'import time; print(time.time())')

# --- verify -----------------------------------------------------------------
SRC_HASH=$(shasum -a 256 "$WORK/seed/payload.bin" | cut -d' ' -f1)
DST_HASH=$(shasum -a 256 "$WORK/dl/payload.bin" 2>/dev/null | cut -d' ' -f1 || echo "MISSING")
if [ "$SRC_HASH" != "$DST_HASH" ]; then
  echo "FAIL: hash mismatch (src=$SRC_HASH dst=$DST_HASH)"
  tail -10 "$WORK/leech.log"
  exit 1
fi

python3 - "$START" "$END" "$SIZE_MB" <<'PYEOF'
import sys
start, end, size_mb = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
secs = end - start
print(f"OK  {size_mb:.0f} MiB in {secs:.1f}s = {size_mb/secs:.1f} MiB/s")
PYEOF
