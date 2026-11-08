#!/usr/bin/env bash
# Installs and runs AIOStreams the way Nuvio does on Apple TV — bootstrap.mjs
# from the installer folder (aio-node/installer/assemble.sh), Node 24 with the
# JIT off (--jitless), the shims instead of native addons — and checks the
# configuration page, saving a configuration (the addon address lands in the
# state file), a stream request and Nuvio's version port; a plugin on the
# "Nuvio plugins" card (a stand-in for Nuvio's plugin server) and the ports
# coming back after tvOS took them away (drop-ports.py).
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
export NUVIO_WAKE_FILE="$RUN/wake"
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

# A stand-in for Nuvio's plugin server (PluginAIOBridge): one plugin with one
# stream, for the "Nuvio plugins" card (nuvio-main.mjs).
cat > "$RUN/plugins.mjs" <<'JS'
import http from 'node:http';
const send = (res, body, status = 200) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
http.createServer((req, res) => {
  const path = req.url.split('?')[0];
  if (path === '/smoke/stremio/plugins.json') return send(res, { plugins: [{ key: 'smokeplugin', name: 'Smoke plugin', resources: ['stream'] }] });
  if (path === '/smoke/stremio/p/smokeplugin/manifest.json') {
    return send(res, { id: 'nuvio.plugin.aio.smokeplugin', version: '1.0.0', name: 'Smoke plugin', description: 'smoke', types: ['movie', 'series'], catalogs: [],
      resources: [{ name: 'stream', types: ['movie', 'series'], idPrefixes: ['tt', 'tmdb:'] }], behaviorHints: { configurable: false } });
  }
  if (path.startsWith('/smoke/stremio/p/smokeplugin/stream/')) {
    return send(res, { streams: [{ name: 'Smoke plugin 1080p', title: 'The Matrix 1999 1080p BluRay',
      url: 'http://127.0.0.1:18766/smoke/resolve/smokeplugin/The.Matrix.1999.1080p.BluRay.x264.mkv?p=e30',
      behaviorHints: { filename: 'The.Matrix.1999.1080p.BluRay.x264.mkv', videoSize: 2147483648, proxyHeaders: { request: { Referer: 'https://plugin.example/' } } } },
      // As Usenet Direct answers: Stremio NNTP's nzbUrl, no servers (Nuvio Usenet's own).
      { name: 'UD · Smoke\n2160p', description: 'smoke usenet', nzbUrl: 'https://indexer.example/api?t=get&id=smoke-nzb&apikey=KEY',
        behaviorHints: { notWebReady: true, bingeGroup: 'usenet-direct|2160p', videoSize: 4294967296, filename: 'The.Matrix.1999.2160p.UHD.BluRay.x265-SMOKE' } }] });
  }
  send(res, { error: 'Not found' }, 404);
}).listen(18766, '127.0.0.1');
JS
node "$RUN/plugins.mjs" &
PLUGINS_PID=$!
export NUVIO_PLUGINS_URL="http://127.0.0.1:18766/smoke/stremio/"

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
node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).data||{};const p=d.settings?.presets||d.presets||[];process.exit(p.some(x=>x.ID==="nuvio-plugins")?0:1)' "$RUN/body" \
  && echo "ok   the \"Nuvio plugins\" card is on the configuration page" \
  || { echo "FAIL no \"Nuvio plugins\" card in the presets"; failed=1; }

# Save a configuration as the page would: AIOStreams' own starter template,
# with Torrentio only (no debrid key needed).
node -e '
const fs = require("fs");
const root = process.argv[1];
const dir = JSON.parse(fs.readFileSync(`${root}/versions.json`, "utf8")).current;
const template = JSON.parse(fs.readFileSync(`${root}/${dir}/resources/templates/debrid-starter.json`, "utf8"));
const config = template.config;
config.presets = config.presets.filter((preset) => preset.type === "torrentio");
// The "Nuvio plugins" card: the plugin of the stand-in, never filtered out.
config.presets.push({ type: "nuvio-plugins", instanceId: "nuvioplg", enabled: true, options: { resultPassthrough: true } });
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
  grep -q '127.0.0.1:18766/smoke/resolve/smokeplugin/' "$RUN/body" \
    && echo "ok   the plugin's stream came through AIOStreams" \
    || { echo "FAIL no stream of the plugin in AIOStreams' answer"; head -c 800 "$RUN/body"; echo; failed=1; }
  grep -q 'id=smoke-nzb' "$RUN/body" \
    && echo "ok   the plugin's Usenet stream (nzbUrl) came through AIOStreams" \
    || { echo "FAIL the plugin's Usenet stream (nzbUrl) is not in AIOStreams' answer"; failed=1; }
  grep -F '[nuvio] AIOStreams took' "$RUN/aio.log" | head -3 || true
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
echo "--- times of the first start ---"; grep -F '[nuvio] start (' "$RUN/aio.log" || true

# A second start, like every start after the first one: the version is
# installed and AIOStreams' data is on disk. Its data refreshes wait until it
# answers and is quiet (nuvio-main.mjs); a search goes out at once.
echo "--- second start ---"
rm -f "$NUVIO_STATE_FILE"
export NUVIO_T0_MS=$(( $(date +%s%N) / 1000000 ))
node --jitless --max-old-space-size=1024 --import "$RUN/wasm/preload.mjs" "$INSTALLER/bootstrap.mjs" > "$RUN/aio2.log" 2>&1 &
PID=$!
for _ in $(seq 1 3000); do
  grep -q '"status": "running"' "$NUVIO_STATE_FILE" 2>/dev/null && break
  grep -qE '"status": "(not answering|failed)"' "$NUVIO_STATE_FILE" 2>/dev/null && break
  kill -0 $PID 2>/dev/null || break
  sleep 0.1
done
echo "second start: answering after $(( $(date +%s%N) / 1000000 - NUVIO_T0_MS )) ms"
grep -q '"status": "running"' "$NUVIO_STATE_FILE" 2>/dev/null || { echo "FAIL second start"; failed=1; }
if [ -n "$MANIFEST" ]; then
  t0=$(date +%s%N)
  check "stream request right after the second start" 200 "${MANIFEST%/manifest.json}/stream/movie/tt0133093.json"
  echo "took $(( ($(date +%s%N) - t0) / 1000000 )) ms"
fi
echo "activity: $(curl -s -H "x-nuvio-token: $NUVIO_CONTROL_TOKEN" "$CONTROL/activity")"
for _ in $(seq 1 150); do
  grep -qF '[nuvio] start (data refreshed)' "$RUN/aio2.log" && break
  kill -0 $PID 2>/dev/null || break
  sleep 1
done
echo "--- times of the second start ---"
grep -F '[nuvio] start (' "$RUN/aio2.log" || { echo "FAIL no times of the start in the log"; failed=1; }
grep -qF '[nuvio] start (data refreshed)' "$RUN/aio2.log" && echo "ok   held data refreshes ran after the start" \
  || echo "note: no held data refreshes ran (none held, or still waiting)"
check "health after the refreshes" 200 "$LAN/api/v1/health"

# tvOS takes a suspended app's ports away: the listening sockets are shut down
# from outside (the process is not told). Coming back, Nuvio writes to the wake
# file; nuvio-main.mjs checks its port at once and listens again.
if sudo -n true 2>/dev/null && command -v python3 >/dev/null; then
  sudo -n python3 "$(dirname "$0")/drop-ports.py" "$PID" "$PORT" "$NUVIO_LAN_PORT" "$NUVIO_CONTROL_PORT"
  sleep 0.5
  t0=$(date +%s%N); back=""
  printf '%s' "$(date +%s)" > "$NUVIO_WAKE_FILE"
  for _ in $(seq 1 50); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$PORT/api/v1/health")" = 200 ] && { back=1; break; }
    sleep 0.1
  done
  if [ -n "$back" ]; then
    echo "ok   AIOStreams answers again $(( ($(date +%s%N) - t0) / 1000000 )) ms after Nuvio woke it up (ports taken away)"
    check "configuration page after the ports came back" 200 "$LAN/stremio/configure"
  else
    echo "FAIL AIOStreams does not answer after its ports were taken away"; failed=1
  fi
  grep -F 'the ports were gone' "$RUN/aio2.log" || true
else
  echo "note: no sudo or python3 here, the ports are not taken away"
fi
kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo "--- second start: log (last 40 lines) ---"; tail -40 "$RUN/aio2.log"
echo "--- second start: errors in log ---"; grep -iE "error|fail|cannot|not found" "$RUN/aio2.log" | grep -v '"level":30' | head -30 || true
kill $PLUGINS_PID 2>/dev/null
exit $failed
