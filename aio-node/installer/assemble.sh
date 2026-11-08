#!/usr/bin/env bash
# Puts together what Nuvio carries to install and run AIOStreams on Apple TV:
# bootstrap.mjs, nuvio-main.mjs, image-install.mjs, ffprobe-bridge.mjs and
# the shims for native addons, with bcryptjs inside the bcrypt shim (fetched
# from npm, MIT).
#
#   aio-node/installer/assemble.sh <destination folder>
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEST=${1:?destination folder}
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$HERE/bootstrap.mjs" "$HERE/nuvio-main.mjs" "$HERE/image-install.mjs" "$HERE/ffprobe-bridge.mjs" "$DEST/"
cp -R "$HERE/shims" "$DEST/shims"
work=$(mktemp -d)
(cd "$work" && npm pack --silent bcryptjs@3 >/dev/null && tar xzf bcryptjs-*.tgz)
mkdir -p "$DEST/shims/bcrypt/node_modules"
mv "$work/package" "$DEST/shims/bcrypt/node_modules/bcryptjs"
rm -rf "$work"
echo "installer: $(find "$DEST" -type f | wc -l) files, $(du -sh "$DEST" | cut -f1)"
