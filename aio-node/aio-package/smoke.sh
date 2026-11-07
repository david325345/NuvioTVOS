#!/usr/bin/env bash
# Installs and runs AIOStreams the way Nuvio does on Apple TV — bootstrap.mjs
# from the installer folder (aio-node/installer/assemble.sh), Node 24 with the
# JIT off (--jitless), the shims instead of native addons — and checks the
# configuration page, saving a configuration (the addon address lands in the
# state file), a stream request and Nuvio's version port.
#
#   aio-node/aio-package/smoke.sh <installer folder> <source: image or aio.tar.gz>
set -uo pipefail

INSTALLER=$(cd "${1:?installer folder}" && pwd)
SOURCE=${2:?source}
[ -f "$SOURCE" ] && SOURCE=$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")
RUN=$(mktemp -d)
export NUVIO_AIO_HOME="$RUN/home"
export NUVIO_AIO_SOURCE="$SOURCE"
export NUVIO_CONTROL_PORT=18771
export NUVIO_CONTROL_TOKEN=smoke
export NODE_ENV=production
export PORT=18770
export NUVIO_LAN_PORT=18767
export NUVIO_STATE_FILE="$RUN/state.json"
export SECRET_KEY=$(openssl rand -hex 32)
export DATABASE_URI="sqlite://$RUN/db.sqlite"
export DISK_CACHE_DIR="$RUN/cache"
export BASE_URL="http://127.0.0.1:$NUVIO_LAN_PORT"
export ANIME_DB_LEVEL_OF_DETAIL="${ANIME_DB_LEVEL_OF_DETAIL:-required}"
LAN="http://127.0.0.1:$NUVIO_LAN_PORT"
failed=0

check() {
  local name=$1 expected=$2 url=$3
  local status
  status=$(curl -s -o "$RUN/body" -w '%{http_code}' --max-time 60 "$url")
  if [ "$status" = "$expected" ]; then
    echo "ok   $name ($status, $(wc -c < "$RUN/body") B)"
  else
    echo "FAIL $name: HTTP $status"; head -c 600 "$RUN/body"; echo
    failed=1
  fi
}

# nodejs-mobile has no WebAssembly in V8 (jitless) and installs the pure-JS
# polywasm instead, so fetch (undici) works; do the same here.
mkdir -p "$RUN/wasm"
(cd "$RUN/wasm" && npm install --silent --no-package-lock polywasm >/dev/null)
cat > "$RUN/wasm/preload.mjs" <<'JS'
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { WebAssembly } = require('polywasm');
WebAssembly.LinkError ??= class LinkError extends Error {};
WebAssembly.RuntimeError ??= class RuntimeError extends Error {};
globalThis.WebAssembly = WebAssembly;
JS
export UNDICI_NO_WASM_SIMD=1

started=$(date +%s)
node --jitless --max-old-space-size=1024 --import "$RUN/wasm/preload.mjs" "$INSTALLER/bootstrap.mjs" > "$RUN/aio.log" 2>&1 &
PID=$!
for _ in $(seq 1 600); do
  grep -q '"status": "running"' "$NUVIO_STATE_FILE" 2>/dev/null && break
  grep -qE '"status": "(not answering|failed)"' "$NUVIO_STATE_FILE" 2>/dev/null && break
  kill -0 $PID 2>/dev/null || break
  sleep 1
done
echo "startup (installing included): $(( $(date +%s) - started )) s"
cat "$NUVIO_STATE_FILE" 2>/dev/null || { echo "no state file"; failed=1; }

check "health" 200 "$LAN/api/v1/health"
check "configuration page" 200 "$LAN/stremio/configure"
check "status" 200 "$LAN/api/v1/status"

# Save a configuration as the page would: AIOStreams' own starter template,
# with Torrentio only (no debrid key needed).
node -e '
const fs = require("fs");
const root = process.argv[1];
const dir = JSON.parse(fs.readFileSync(`${root}/versions.json`, "utf8")).current;
const template = JSON.parse(fs.readFileSync(`${root}/${dir}/resources/templates/debrid-starter.json`, "utf8"));
const config = template.config;
config.presets = config.presets.filter((preset) => preset.type === "torrentio");
// No TMDB key here; on the TV Nuvio passes its own as TMDB_API_KEY.
delete config.tmdbApiKey;
delete config.tmdbAccessToken;
for (const key of ["titleMatching", "yearMatching", "digitalReleaseFilter"]) {
  if (config[key]) config[key].enabled = false;
}
fs.writeFileSync(process.argv[2], JSON.stringify({ config, password: "nuvio-smoke-test" }));
' "$NUVIO_AIO_HOME" "$RUN/config.json"
status=$(curl -s -o "$RUN/created" -w '%{http_code}' --max-time 120 -H 'content-type: application/json' \
  --data-binary "@$RUN/config.json" "$LAN/api/v1/user")
echo "save configuration: HTTP $status"; head -c 400 "$RUN/created"; echo
sleep 1
MANIFEST=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')).manifest||'')}catch{console.log('')}" "$NUVIO_STATE_FILE")
if [ -n "$MANIFEST" ]; then
  echo "addon address written: ${MANIFEST%%/stremio/*}/stremio/…"
  check "manifest" 200 "$MANIFEST"
  t0=$(date +%s%N)
  check "stream request" 200 "${MANIFEST%/manifest.json}/stream/movie/tt0133093.json"
  echo "stream request took $(( ($(date +%s%N) - t0) / 1000000 )) ms, $(node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).streams||[];console.log(s.length+" streams; first: "+JSON.stringify((s[0]||{}).name||"").slice(0,120))}catch(e){console.log("unreadable")}' "$RUN/body")"
  t0=$(date +%s%N)
  check "same request again (cache)" 200 "${MANIFEST%/manifest.json}/stream/movie/tt0133093.json"
  echo "took $(( ($(date +%s%N) - t0) / 1000000 )) ms"
else
  echo "FAIL no addon address in the state file"; failed=1
fi

CONTROL="http://127.0.0.1:$NUVIO_CONTROL_PORT"
echo "versions: $(curl -s -H "x-nuvio-token: $NUVIO_CONTROL_TOKEN" "$CONTROL/versions")"
echo "check for updates: $(curl -s -X POST -H "x-nuvio-token: $NUVIO_CONTROL_TOKEN" "$CONTROL/check")"
[ "$(curl -s -o /dev/null -w '%{http_code}' "$CONTROL/versions")" = 403 ] && echo "ok   version port refuses requests without the token" \
  || { echo "FAIL version port without the token"; failed=1; }

echo "memory after requests: $(ps -o rss= -p $PID 2>/dev/null | awk '{printf "%d MB", $1/1024}')"
sleep 60
echo "memory a minute later (background downloads): $(ps -o rss= -p $PID 2>/dev/null | awk '{printf "%d MB", $1/1024}')"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo "--- log (last 60 lines) ---"; tail -60 "$RUN/aio.log"
echo "--- errors in log ---"; grep -iE "error|fail|cannot|not found" "$RUN/aio.log" | grep -v '"level":30' | head -30 || true
exit $failed
