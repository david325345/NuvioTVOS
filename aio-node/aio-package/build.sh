#!/usr/bin/env bash
# Builds the original AIOStreams for Nuvio on Apple TV.
#
#   AIO_TAG=v2.37.0 aio-node/aio-package/build.sh <work dir> <output dir>
#
# Same steps and layout as AIOStreams' own Dockerfile (packages/server/dist,
# packages/frontend/dist, resources, node_modules), then:
#   - no symlinks: Apple TV does not let apps create them, so node_modules is
#     pnpm's hoisted layout (real folders) and no-symlinks.py turns the links
#     to AIOStreams' own packages into forwarding packages,
#   - native addons, which Apple TV can't load, are swapped for the shims in
#     shims/ (better-sqlite3 → node:sqlite, bcrypt → bcryptjs, yencode → off),
#   - nuvio-main.mjs is added,
# and everything goes into one aio.tar.gz that bootstrap.mjs unpacks on the TV.
# The AIOStreams code itself is not changed.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mkdir -p "${1:?work dir}" && cd "$1" && pwd)
OUT=$(mkdir -p "${2:?output dir}" && cd "$2" && pwd)
REPO=https://github.com/Viren070/AIOStreams

if [ -z "${AIO_TAG:-}" ]; then
  # The newest release tag (no betas). sed reads everything: no SIGPIPE under pipefail.
  AIO_TAG=$(git ls-remote --tags --refs --sort=-v:refname "$REPO" 'v*' | sed 's#.*refs/tags/##' | grep -vE -- '-' | sed -n 1p)
fi
echo "AIOStreams $AIO_TAG"

SRC="$WORK/src"
rm -rf "$SRC"
git clone --depth 1 --branch "$AIO_TAG" "$REPO" "$SRC"
cd "$SRC"
COMMIT=$(git rev-parse --short HEAD)

corepack enable
pnpm install --frozen-lockfile
# resources/metadata.json: version and channel, as AIOStreams' release builds have it.
pnpm run metadata || echo "note: metadata.json was not generated"
pnpm run build

# Production dependencies of the server and what it uses, as in the image —
# hoisted (real folders, like npm), because Apple TV refuses symlinks.
rm -rf node_modules packages/*/node_modules
pnpm install --prod --frozen-lockfile --filter '@aiostreams/server...' --config.node-linker=hoisted

STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/packages"
cp package.json LICENSE "$STAGE/"
cp -R resources "$STAGE/resources"
for package in core crypto server; do
  mkdir -p "$STAGE/packages/$package"
  cp "packages/$package/package.json" "$STAGE/packages/$package/"
  [ -d "packages/$package/dist" ] && cp -R "packages/$package/dist" "$STAGE/packages/$package/dist"
  [ -d "packages/$package/node_modules" ] && cp -a "packages/$package/node_modules" "$STAGE/packages/$package/node_modules"
done
# crypto ships its sources as the package (see the Dockerfile).
cp -R packages/crypto/. "$STAGE/packages/crypto/"
rm -rf "$STAGE/packages/crypto/node_modules/.cache"
cp -R packages/server/src/static "$STAGE/packages/server/dist/static"
for web in frontend web; do
  if [ -d "packages/$web/dist" ]; then
    mkdir -p "$STAGE/packages/$web"
    cp -R "packages/$web/dist" "$STAGE/packages/$web/dist"
  fi
done
cp -a node_modules "$STAGE/node_modules"

# No symlinks at all (forwarding packages for AIOStreams' own, .bin dropped).
python3 "$HERE/no-symlinks.py" "$STAGE"

# Native addons → shims, wherever the package is in node_modules.
bcryptjs_dir="$WORK/bcryptjs"
rm -rf "$bcryptjs_dir" && mkdir -p "$bcryptjs_dir"
(cd "$bcryptjs_dir" && npm pack --silent bcryptjs@3 >/dev/null && tar xzf bcryptjs-*.tgz && mv package bcryptjs)
# shim folder:package
for entry in better-sqlite3:better-sqlite3 bcrypt:bcrypt yencode:yencode fsmux-fuse:@viren070/fsmux-fuse; do
  shim=${entry%%:*}
  package=${entry#*:}
  found=0
  while IFS= read -r -d '' dir; do
    found=1
    rm -rf "$dir"
    cp -R "$HERE/shims/$shim" "$dir"
    if [ "$shim" = bcrypt ]; then
      mkdir -p "$dir/node_modules"
      cp -R "$bcryptjs_dir/bcryptjs" "$dir/node_modules/bcryptjs"
    fi
    echo "shim: $package → ${dir#$STAGE/}"
  done < <(find "$STAGE" -type d -path "*/node_modules/$package" -prune -print0)
  [ "$found" = 1 ] || echo "note: $package is not among the production dependencies"
done

# Anything native left is reported: it can't run on Apple TV.
native=$(find "$STAGE" -name '*.node' -type f | sed "s#$STAGE/##" || true)
if [ -n "$native" ]; then
  echo "Native addons still in the package (they will not load on Apple TV):"
  echo "$native"
  find "$STAGE" -name '*.node' -type f -delete
fi
# Not needed at run time.
find "$STAGE/node_modules" -name '*.d.ts' -type f -delete
find "$STAGE/node_modules" \( -name '*.map' -o -name '*.md' -o -name 'CHANGELOG*' \) -type f -delete

cp "$HERE/nuvio-main.mjs" "$STAGE/nuvio-main.mjs"
cat > "$STAGE/nuvio-package.json" <<JSON
{ "aiostreams": "$AIO_TAG", "commit": "$COMMIT", "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)" }
JSON

# GNU tar: PAX for long paths, hard links stored as files.
tar --format=pax --hard-dereference -C "$STAGE" -czf "$OUT/aio.tar.gz" .
cp "$HERE/bootstrap.mjs" "$OUT/bootstrap.mjs"
cp "$STAGE/nuvio-package.json" "$OUT/nuvio-package.json"
echo "files: $(find "$STAGE" -type f | wc -l), unpacked: $(du -sh "$STAGE" | cut -f1), aio.tar.gz: $(du -sh "$OUT/aio.tar.gz" | cut -f1)"
