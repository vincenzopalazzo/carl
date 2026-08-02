#!/usr/bin/env bash
#
# Upload fan-out benchmark: one carl seeds, N carls leech it concurrently, all
# on 127.0.0.1 with a stub tracker. Where bench_loopback.sh measures a single
# peer-to-peer stream, this measures the seeder's *aggregate* upload path --
# the send buffers, the choke/unchoke slots, and the poll loop's fairness when
# several peers all want data at once.
#
#   SIZE_MB     payload size in MiB                (default 512)
#   LEECHERS    concurrent downloaders             (default 4)
#   TIMEOUT     seconds to allow the transfers     (default 600)
#   CARL        path to the carl binary            (default ./zig-out/bin/carl)
#   KEEP        set to 1 to keep the work dir
#
# Exit status: 0 only when every leecher's bytes match the seeder's.
set -euo pipefail

CARL=${CARL:-./zig-out/bin/carl}
SIZE_MB=${SIZE_MB:-512}
LEECHERS=${LEECHERS:-4}
TIMEOUT=${TIMEOUT:-600}
KEEP=${KEEP:-0}

TRACKER_PORT=${TRACKER_PORT:-18200}
SEED_PORT=${SEED_PORT:-18201}
LEECH_PORT_BASE=${LEECH_PORT_BASE:-18210}

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
[ -x "$CARL" ] || { echo "carl binary not found at $CARL (run: zig build -Doptimize=ReleaseSafe)" >&2; exit 1; }

WORK=$(mktemp -d)
TAG=$(basename "$WORK")
cleanup() {
  [ -n "${TRACKER_PID:-}" ] && kill "$TRACKER_PID" 2>/dev/null || true
  [ -n "${SEED_PID:-}" ] && kill "$SEED_PID" 2>/dev/null || true
  pkill -f "download .*${TAG}" 2>/dev/null || true
  if [ "$KEEP" = "1" ]; then echo "work dir kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

mkdir -p "$WORK/seed"

cat > "$WORK/tracker.py" <<PYEOF
import http.server, socket, struct, sys
peer = socket.inet_aton("127.0.0.1") + struct.pack(">H", ${SEED_PORT})
body = b"d8:intervali60e5:peers" + str(len(peer)).encode() + b":" + peer + b"e"

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", ${TRACKER_PORT}), H).serve_forever()
PYEOF

python3 "$WORK/tracker.py" &
TRACKER_PID=$!
# Detach from job control so the shell doesn't print a "Terminated" notice for
# it when the cleanup trap fires.
disown "$TRACKER_PID" 2>/dev/null || true
sleep 1

echo "creating ${SIZE_MB}MiB payload..."
dd if=/dev/urandom of="$WORK/seed/payload.bin" bs=1m count="$SIZE_MB" 2>/dev/null
"$CARL" create "$WORK/seed/payload.bin" -o "$WORK/payload.torrent" \
  -t "http://127.0.0.1:${TRACKER_PORT}/announce" >/dev/null

"$CARL" seed "$WORK/payload.torrent" "$WORK/seed" --port "$SEED_PORT" > "$WORK/seed.log" 2>&1 &
SEED_PID=$!
# The seeder hashes the payload before it will answer requests; starting the
# leechers mid-verify would bill that time to the transfer.
sleep 3
kill -0 "$SEED_PID" 2>/dev/null || { echo "seeder died:"; cat "$WORK/seed.log"; exit 1; }

echo "starting ${LEECHERS} leechers..."
START=$(python3 -c 'import time; print(time.time())')
i=1
while [ "$i" -le "$LEECHERS" ]; do
  mkdir -p "$WORK/dl$i"
  "$CARL" download "$WORK/payload.torrent" --output-dir "$WORK/dl$i" \
    --port $((LEECH_PORT_BASE + i)) > "$WORK/leech$i.log" 2>&1 &
  i=$((i + 1))
done

# Poll rather than `wait`: bare `wait` would also block on the tracker and
# seeder, which never exit, and zsh does not word-split an unquoted PID list.
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while pgrep -f "download .*${TAG}" >/dev/null; do
  [ "$(date +%s)" -gt "$DEADLINE" ] && { echo "TIMEOUT after ${TIMEOUT}s"; exit 1; }
  sleep 1
done
END=$(python3 -c 'import time; print(time.time())')

SRC_HASH=$(shasum -a 256 "$WORK/seed/payload.bin" | cut -d' ' -f1)
ok=0
i=1
while [ "$i" -le "$LEECHERS" ]; do
  h=$(shasum -a 256 "$WORK/dl$i/payload.bin" 2>/dev/null | cut -d' ' -f1 || echo MISSING)
  if [ "$h" = "$SRC_HASH" ]; then ok=$((ok + 1)); else echo "leecher $i MISMATCH ($h)"; fi
  i=$((i + 1))
done

python3 - "$START" "$END" "$SIZE_MB" "$LEECHERS" "$ok" <<'PYEOF'
import sys
start, end, size_mb, n, ok = (float(sys.argv[1]), float(sys.argv[2]),
                              float(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
secs = end - start
total = size_mb * n
status = "OK " if ok == n else "FAIL"
print(f"{status} {n} leechers x {size_mb:.0f} MiB = {total:.0f} MiB in {secs:.1f}s "
      f"= {total/secs:.1f} MiB/s aggregate upload  (verified {ok}/{n})")
sys.exit(0 if ok == n else 1)
PYEOF
