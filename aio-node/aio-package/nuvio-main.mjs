// Starts the original AIOStreams inside Nuvio on Apple TV.
//
// Nuvio runs this file in its embedded Node.js with these variables:
//   AIO_ROOT          the unpacked AIOStreams package (packages/server/dist/server.js …)
//   PORT              AIOStreams' own port; bound to 127.0.0.1 only
//   NUVIO_LAN_PORT    the port the configuration page is reachable on from the network
//   NUVIO_STATE_FILE  where the addon address of a saved configuration is written
// plus AIOStreams' usual environment (DATABASE_URI, SECRET_KEY, BASE_URL …).
//
// The network port is a small proxy in front of AIOStreams. It forwards every
// request unchanged and watches one thing: when the configuration page saves
// a new configuration (POST /api/v1/user), the answer carries its uuid and
// encrypted password, and Nuvio gets the addon address from NUVIO_STATE_FILE —
// nothing to copy by hand.
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const aioRoot = process.env.AIO_ROOT;
const aioPort = Number(process.env.PORT || 8770);
const lanPort = Number(process.env.NUVIO_LAN_PORT || 0);
const stateFile = process.env.NUVIO_STATE_FILE;
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

function findCredentials(value) {
  if (!value || typeof value !== 'object') return null;
  if (typeof value.uuid === 'string' && typeof value.encryptedPassword === 'string') {
    return { uuid: value.uuid, encryptedPassword: value.encryptedPassword };
  }
  for (const child of Object.values(value)) {
    const found = findCredentials(child);
    if (found) return found;
  }
  return null;
}

function rememberConfiguration(body) {
  try {
    const credentials = findCredentials(JSON.parse(body));
    if (!credentials) return;
    const manifest = `http://127.0.0.1:${aioPort}/stremio/${encodeURIComponent(credentials.uuid)}/${encodeURIComponent(credentials.encryptedPassword)}/manifest.json`;
    writeState({ manifest });
    log(`configuration saved, addon: /stremio/${credentials.uuid}/…/manifest.json`);
  } catch (error) {
    log(`could not read the saved configuration: ${error.message}`);
  }
}

function startProxy() {
  if (!lanPort) return;
  const proxy = http.createServer((request, response) => {
    const watch = request.method === 'POST' && /^\/api\/v\d+\/user\/?(\?|$)/.test(request.url || '');
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
          rememberConfiguration(Buffer.concat(chunks).toString('utf8'));
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
writeState({ status: 'starting', pid: process.pid, node: process.version, port: aioPort, lanPort });
process.chdir(aioRoot);
startProxy();
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
log(ready ? `AIOStreams is ready in ${seconds} s, ${memory} MB` : `AIOStreams did not answer within 5 minutes`);
setInterval(() => {
  writeState({ rssMB: Math.round(process.memoryUsage().rss / 1048576), heapMB: Math.round(process.memoryUsage().heapUsed / 1048576) });
}, 15000).unref();
