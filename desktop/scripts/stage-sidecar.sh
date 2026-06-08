#!/usr/bin/env sh
# Stage the `carl` daemon binary as a Tauri sidecar so the bundle ships its own
# daemon (PATH-independent) and the desktop app can install/symlink the CLI.
#
# Run automatically by tauri.conf.json `beforeBuildCommand`. The binary is a
# build artifact (gitignored under src-tauri/binaries/), so this regenerates it
# every build — never shipping a stale daemon.
#
# Honors CARL_BIN if it points at a usable binary (skips the zig rebuild);
# otherwise builds a fresh ReleaseSafe `carl` from the repo.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TRIPLE="$(rustc -Vv | awk '/host:/{print $2}')"

if [ -n "$CARL_BIN" ] && [ -x "$CARL_BIN" ]; then
  SRC="$CARL_BIN"
  echo "stage-sidecar: using CARL_BIN=$SRC"
else
  echo "stage-sidecar: building ReleaseSafe carl"
  ( cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe )
  SRC="$REPO_ROOT/zig-out/bin/carl"
fi

DEST_DIR="$REPO_ROOT/desktop/src-tauri/binaries"
mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST_DIR/carl-$TRIPLE"
chmod +x "$DEST_DIR/carl-$TRIPLE"
echo "stage-sidecar: staged $DEST_DIR/carl-$TRIPLE"
