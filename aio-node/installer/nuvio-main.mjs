// Starts the original AIOStreams inside Nuvio on Apple TV.
//
// Nuvio runs this file in its embedded Node.js with these variables:
//   AIO_ROOT          the unpacked AIOStreams package (packages/server/dist/server.js …)
//   PORT              AIOStreams' own port; bound to 127.0.0.1 only
//   NUVIO_LAN_PORT    the port the configuration page is reachable on from the network
//   NUVIO_STATE_FILE  where the addon address of a saved configuration is written
//   NUVIO_BACKUP_FILE where a copy of the configuration (with its password) is
//                     written; Nuvio moves it to the Keychain at once
//   NUVIO_CONTROL_PORT / NUVIO_CONTROL_TOKEN
//                     Nuvio's own port (127.0.0.1 only) for versions: check
//                     for an update, install it for the next start
//   NUVIO_AIO_HOME, NUVIO_AIO_SOURCE, NUVIO_AIO_CURRENT, NUVIO_AIO_VERSION
//                     the versions (set by bootstrap.mjs)
// plus AIOStreams' usual environment (DATABASE_URI, SECRET_KEY, BASE_URL …).
//
// The network port is a small proxy in front of AIOStreams. It forwards every
// request unchanged and watches the configuration page's user API: creating a
// configuration (POST /api/v1/user), loading one with its uuid and password
// (session + GET) and saving changes (PUT). From those Nuvio gets the addon
// address (NUVIO_STATE_FILE) — nothing to copy by hand — and a backup of the
// configuration: tvOS keeps AIOStreams' database in Caches, which it may clear.
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath, pathToFileURL } from 'node:url';

const aioRoot = process.env.AIO_ROOT;
const aioPort = Number(process.env.PORT || 8770);
const lanPort = Number(process.env.NUVIO_LAN_PORT || 0);
const stateFile = process.env.NUVIO_STATE_FILE;
const backupFile = process.env.NUVIO_BACKUP_FILE;
const controlPort = Number(process.env.NUVIO_CONTROL_PORT || 0);
const controlToken = process.env.NUVIO_CONTROL_TOKEN || '';
const aioHome = process.env.NUVIO_AIO_HOME;
const aioSource = process.env.NUVIO_AIO_SOURCE || '';
const currentVersion = process.env.NUVIO_AIO_VERSION || '';
const here = path.dirname(fileURLToPath(import.meta.url));
const started = Date.now();

function log(message) {
  console.log(`[nuvio] ${message}`);
}

// AIOStreams calls app.listen(PORT), which listens on every interface. Here
// only the proxy below is reachable from the network.
const originalListen = net.Server.prototype.listen;
net.Server.prototype.listen = function (...args) {
  if (args[0] === aioPort || args[0] === String(aioPort)) {
    const callback = args.find((value) => typeof value === 'function');
    return originalListen.call(this, aioPort, '127.0.0.1', callback);
  }
  return originalListen.apply(this, args);
};

function writeState(update) {
  if (!stateFile) return;
  let state = {};
  try {
    state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  } catch {
    // first write
  }
  Object.assign(state, update, { updatedAt: new Date().toISOString() });
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(`${stateFile}.tmp`, JSON.stringify(state, null, 2));
  fs.renameSync(`${stateFile}.tmp`, stateFile);
}

// The configuration page's user API: 'user' (/api/v1/user) or 'session'
// (/api/v1/user/session, logging in with uuid and password).
function userApi(request) {
  const match = /^\/api\/v\d+\/user(\/session)?\/?(\?|$)/.exec(request.url || '');
  if (!match || !['GET', 'POST', 'PUT'].includes(request.method)) return null;
  return match[1] ? 'session' : 'user';
}

function basicCredentials(request) {
  const match = /^Basic\s+(.+)$/i.exec(request.headers.authorization || '');
  if (!match) return null;
  const text = Buffer.from(match[1], 'base64').toString('utf8');
  const colon = text.indexOf(':');
  return colon > 0 ? { uuid: text.slice(0, colon), password: text.slice(colon + 1) } : null;
}

function decoded(buffer, encoding) {
  switch ((encoding || '').toLowerCase()) {
    case 'gzip': return zlib.gunzipSync(buffer);
    case 'deflate': return zlib.inflateSync(buffer);
    case 'br': return zlib.brotliDecompressSync(buffer);
    default: return buffer;
  }
}

function parsed(text) {
  try {
    return text ? JSON.parse(text) : {};
  } catch {
    return {};
  }
}

function saveAddon(uuid, encryptedPassword) {
  const manifest = `http://127.0.0.1:${aioPort}/stremio/${encodeURIComponent(uuid)}/${encodeURIComponent(encryptedPassword)}/manifest.json`;
  writeState({ manifest });
  log(`configuration ${uuid.slice(0, 8)}… in use, addon: /stremio/${uuid.slice(0, 8)}…/manifest.json`);
}

function saveBackup(uuid, password, config) {
  if (!backupFile || !config || typeof password !== 'string') return;
  fs.mkdirSync(path.dirname(backupFile), { recursive: true });
  fs.writeFileSync(`${backupFile}.tmp`, JSON.stringify({ uuid, password, config, savedAt: new Date().toISOString() }));
  fs.renameSync(`${backupFile}.tmp`, backupFile);
  log(`configuration ${uuid.slice(0, 8)}… backed up`);
}

let sessionCredentials = null; // the last login on the page

function observe(kind, request, requestBody, answer) {
  const body = parsed(requestBody.toString('utf8'));
  const data = (parsed(decoded(answer.body, answer.headers['content-encoding']).toString('utf8')).data) || {};
  const credentials = basicCredentials(request) || sessionCredentials;
  if (kind === 'session') {
    if (request.method === 'POST' && typeof body.uuid === 'string' && typeof body.password === 'string') {
      sessionCredentials = { uuid: typeof data.uuid === 'string' ? data.uuid : body.uuid, password: body.password };
    }
    return;
  }
  if (request.method === 'POST') {
    // A new configuration.
    if (typeof data.uuid === 'string' && typeof data.encryptedPassword === 'string') {
      saveAddon(data.uuid, data.encryptedPassword);
      saveBackup(data.uuid, body.password, body.config);
    }
  } else if (request.method === 'GET') {
    // An existing configuration, loaded with its uuid and password.
    const uuid = (data.userData && data.userData.uuid) || (credentials && credentials.uuid);
    if (uuid && typeof data.encryptedPassword === 'string') {
      saveAddon(uuid, data.encryptedPassword);
      if (credentials) saveBackup(uuid, credentials.password, data.userData);
    }
  } else if (request.method === 'PUT') {
    // Changes saved.
    const uuid = data.uuid || (credentials && credentials.uuid);
    if (uuid && credentials) saveBackup(uuid, credentials.password, body.config);
  }
}

function startProxy() {
  if (!lanPort) return;
  const proxy = http.createServer((request, response) => {
    const watch = userApi(request);
    const requestChunks = [];
    if (watch) request.on('data', (chunk) => requestChunks.push(chunk));
    const upstream = http.request(
      { host: '127.0.0.1', port: aioPort, method: request.method, path: request.url, headers: request.headers },
      (answer) => {
        response.writeHead(answer.statusCode || 502, answer.headers);
        if (!watch || (answer.statusCode || 0) >= 300) {
          answer.pipe(response);
          return;
        }
        const chunks = [];
        answer.on('data', (chunk) => {
          chunks.push(chunk);
          response.write(chunk);
        });
        answer.on('end', () => {
          response.end();
          try {
            observe(watch, request, Buffer.concat(requestChunks), { headers: answer.headers, body: Buffer.concat(chunks) });
          } catch (error) {
            log(`could not read the configuration page's request: ${error.message}`);
          }
        });
      }
    );
    upstream.on('error', (error) => {
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
      response.end(`AIOStreams is not answering yet: ${error.message}`);
    });
    request.pipe(upstream);
  });
  proxy.on('upgrade', (request, socket, head) => {
    const upstream = net.connect(aioPort, '127.0.0.1', () => {
      const lines = [`${request.method} ${request.url} HTTP/${request.httpVersion}`];
      for (let i = 0; i < request.rawHeaders.length; i += 2) lines.push(`${request.rawHeaders[i]}: ${request.rawHeaders[i + 1]}`);
      upstream.write(`${lines.join('\r\n')}\r\n\r\n`);
      if (head && head.length) upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
  });
  proxy.on('error', (error) => log(`configuration page port ${lanPort}: ${error.message}`));
  originalListen.call(proxy, lanPort, '0.0.0.0', () => log(`configuration page on port ${lanPort}`));
}

// MARK: versions (Check for updates / Update in Nuvio)

let update = { state: 'idle' };

async function installer() {
  return import(pathToFileURL(path.join(here, 'image-install.mjs')).href);
}

function versionsSummary(versions) {
  const label = (name) => (name && versions.labels && versions.labels[name] && versions.labels[name].tag) || null;
  return {
    current: label(versions.current) || currentVersion || null,
    previous: label(versions.previous),
    pending: label(versions.pending),
    source: aioSource || null,
  };
}

async function runUpdate() {
  update = { state: 'running', progress: 'Looking for the newest AIOStreams…' };
  try {
    const tools = await installer();
    const { tag } = await tools.latestVersion(aioSource);
    if (tag && tag === currentVersion) {
      update = { state: 'done', upToDate: true, version: tag };
      log(`AIOStreams ${tag} is the newest`);
      return;
    }
    const result = await tools.install({
      source: aioSource,
      tag,
      home: aioHome,
      shimsDir: path.join(here, 'shims'),
      log,
      onProgress: ({ phase, done, total }) => {
        update.progress = phase === 'download'
          ? `Downloading ${tag || ''} — ${(done / 1048576).toFixed(1)}${total ? ` / ${(total / 1048576).toFixed(1)}` : ''} MB`
          : `Preparing ${tag || ''}…`;
      },
    });
    const versions = tools.readVersions(aioHome);
    if (result.name === versions.current) {
      update = { state: 'done', upToDate: true, version: result.tag };
      return;
    }
    versions.pending = result.name;
    versions.labels[result.name] = { tag: result.tag, source: aioSource || tools.DEFAULT_SOURCE, installedAt: new Date().toISOString() };
    tools.saveVersions(aioHome, versions);
    update = { state: 'done', version: result.tag, pending: true };
    log(`AIOStreams ${result.tag} is installed; it starts with the next start of Nuvio`);
  } catch (error) {
    update = { state: 'failed', error: String(error && error.message ? error.message : error) };
    log(`update failed: ${update.error}`);
  }
}

function startControl() {
  if (!controlPort || !controlToken || !aioHome) return;
  const server = http.createServer(async (request, response) => {
    const send = (status, body) => {
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end(JSON.stringify(body));
    };
    if (request.headers['x-nuvio-token'] !== controlToken) return send(403, { error: 'forbidden' });
    try {
      if (request.method === 'GET' && request.url === '/versions') {
        return send(200, versionsSummary((await installer()).readVersions(aioHome)));
      }
      if (request.method === 'POST' && request.url === '/check') {
        const { tag } = await (await installer()).latestVersion(aioSource);
        return send(200, { latest: tag, current: currentVersion || null });
      }
      if (request.url === '/update') {
        if (request.method === 'POST' && update.state !== 'running') void runUpdate();
        return send(request.method === 'POST' ? 202 : 200, update);
      }
      send(404, { error: 'not found' });
    } catch (error) {
      send(500, { error: String(error && error.message ? error.message : error) });
    }
  });
  server.on('error', (error) => log(`control port ${controlPort}: ${error.message}`));
  originalListen.call(server, controlPort, '127.0.0.1');
}

function markReady() {
  if (!aioHome || !process.env.NUVIO_AIO_CURRENT) return;
  installer().then((tools) => {
    const versions = tools.readVersions(aioHome);
    if (versions.lastReady === process.env.NUVIO_AIO_CURRENT) return;
    versions.lastReady = process.env.NUVIO_AIO_CURRENT;
    tools.saveVersions(aioHome, versions);
  }).catch((error) => log(`versions: ${error.message}`));
}

async function waitUntilReady() {
  for (let attempt = 0; attempt < 600; attempt++) {
    const ok = await new Promise((resolve) => {
      const request = http.get({ host: '127.0.0.1', port: aioPort, path: '/api/v1/health', timeout: 2000 }, (answer) => {
        answer.resume();
        resolve((answer.statusCode || 0) < 500);
      });
      request.on('error', () => resolve(false));
      request.on('timeout', () => { request.destroy(); resolve(false); });
    });
    if (ok) return true;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  return false;
}

// Inside Nuvio, Node runs in the app's own process: process.exit() would
// close Nuvio. AIOStreams stops instead, and Nuvio shows it.
const embedded = process.env.NUVIO_EMBEDDED === '1';
if (embedded) {
  process.exit = (code) => {
    log(`AIOStreams asked to exit (${code ?? 0}); Nuvio keeps running`);
    writeState({ status: 'stopped', exitCode: code ?? 0 });
    return undefined;
  };
}

process.on('uncaughtException', (error) => log(`uncaught: ${error && error.stack ? error.stack : error}`));
process.on('unhandledRejection', (error) => log(`unhandled rejection: ${error && error.stack ? error.stack : error}`));

if (!aioRoot) {
  log('AIO_ROOT is not set');
  throw new Error('AIO_ROOT is not set');
}
writeState({ status: 'starting', pid: process.pid, node: process.version, port: aioPort, lanPort, version: currentVersion || null });
process.chdir(aioRoot);
startProxy();
startControl();
log(`starting AIOStreams from ${aioRoot} (node ${process.version}, ${process.arch}, jitless: ${process.execArgv.includes('--jitless') || process.versions.mobile ? 'yes' : 'no'})`);
try {
  await import(pathToFileURL(path.join(aioRoot, 'packages/server/dist/server.js')).href);
} catch (error) {
  log(`AIOStreams failed to load: ${error && error.stack ? error.stack : error}`);
  writeState({ status: 'failed', error: String(error && error.message ? error.message : error) });
  throw error;
}
const ready = await waitUntilReady();
const seconds = ((Date.now() - started) / 1000).toFixed(1);
const memory = Math.round(process.memoryUsage().rss / 1048576);
writeState({ status: ready ? 'running' : 'not answering', startupSeconds: Number(seconds), rssMB: memory });
if (ready) markReady();
log(ready ? `AIOStreams is ready in ${seconds} s, ${memory} MB` : `AIOStreams did not answer within 5 minutes`);
setInterval(() => {
  writeState({ rssMB: Math.round(process.memoryUsage().rss / 1048576), heapMB: Math.round(process.memoryUsage().heapUsed / 1048576) });
}, 60000).unref();
