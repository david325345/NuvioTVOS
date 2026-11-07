// Prepares the original AIOStreams for Nuvio on Apple TV straight from its
// official Docker image — what Nuvio itself is to do on the TV, so it needs no
// build of ours: only Node's own modules, nothing to install first.
//
//   node image-install.mjs --image ghcr.io/viren070/aiostreams:v2.37.0 \
//     --work <scratch dir> --out <package dir> --shims <shims dir> \
//     --nuvio-main <nuvio-main.mjs> [--bcryptjs <bcryptjs package dir>]
//
// 1. Asks the registry for the image (anonymous token, arm64 variant) and
//    finds the layer with the application: AIOStreams' Dockerfile copies the
//    whole /app in one step (COPY --from=runtime /runtime /app).
// 2. Downloads that layer and unpacks app/ from it. Apple TV does not let apps
//    create symlinks, so they are only noted, never created.
// 3. Lays out node_modules without symlinks, the way npm does (as flatten.py
//    does for the CI build): each package once, other versions nested where
//    Node.js finds them, forwarding packages for AIOStreams' own packages;
//    only what the server needs, nothing of the web frontend's.
// 4. Swaps native addons for the shims, adds nuvio-main.mjs.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { Readable, Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const started = Date.now();
const log = (text) => console.log(`[image] ${text}`);
const seconds = (since) => `${((Date.now() - since) / 1000).toFixed(1)} s`;
const mb = (bytes) => `${(bytes / 1048576).toFixed(1)} MB`;

const options = {};
for (let i = 2; i < process.argv.length; i += 2) options[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
if (!options.image && options.layer) options.image = 'local:layer';
for (const name of ['image', 'work', 'out', 'shims', 'nuvio-main']) {
  if (!options[name]) throw new Error(`--${name} is required`);
}

// MARK: registry

function parseImage(reference) {
  const at = reference.lastIndexOf(':');
  const slash = reference.indexOf('/');
  const tag = at > slash ? reference.slice(at + 1) : 'latest';
  const name = at > slash ? reference.slice(0, at) : reference;
  const first = name.slice(0, name.indexOf('/'));
  const hasRegistry = first.includes('.') || first.includes(':');
  const registry = hasRegistry ? first : 'registry-1.docker.io';
  let repository = hasRegistry ? name.slice(first.length + 1) : name;
  if (!hasRegistry && !repository.includes('/')) repository = `library/${repository}`;
  return { registry, repository, tag };
}

const image = parseImage(options.image);
let token = null;

async function registry(pathname, accept) {
  const url = `https://${image.registry}/v2/${image.repository}/${pathname}`;
  for (let attempt = 0; attempt < 2; attempt++) {
    const headers = { 'user-agent': 'Nuvio-AIOStreams' };
    if (accept) headers.accept = accept;
    if (token) headers.authorization = `Bearer ${token}`;
    const response = await fetch(url, { headers, redirect: 'follow' });
    if (response.status === 401 && !token) {
      // Bearer realm="…",service="…",scope="…" — an anonymous pull token.
      const challenge = response.headers.get('www-authenticate') || '';
      const fields = Object.fromEntries([...challenge.matchAll(/(\w+)="([^"]*)"/g)].map((m) => [m[1], m[2]]));
      if (!fields.realm) throw new Error(`registry wants authentication: ${challenge}`);
      const tokenURL = new URL(fields.realm);
      if (fields.service) tokenURL.searchParams.set('service', fields.service);
      tokenURL.searchParams.set('scope', fields.scope || `repository:${image.repository}:pull`);
      const answer = await fetch(tokenURL);
      if (!answer.ok) throw new Error(`token: HTTP ${answer.status}`);
      const body = await answer.json();
      token = body.token || body.access_token;
      continue;
    }
    if (!response.ok) throw new Error(`${pathname}: HTTP ${response.status}`);
    return response;
  }
  throw new Error(`${pathname}: no access`);
}

const MANIFESTS = [
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
  'application/vnd.oci.image.manifest.v1+json',
  'application/vnd.docker.distribution.manifest.v2+json',
].join(', ');

async function findAppLayer() {
  let manifest = await (await registry(`manifests/${image.tag}`, MANIFESTS)).json();
  if (manifest.manifests) {
    const platforms = manifest.manifests.filter((entry) => entry.platform && entry.platform.os === 'linux');
    const chosen = platforms.find((entry) => entry.platform.architecture === 'arm64')
      || platforms.find((entry) => entry.platform.architecture === 'amd64');
    if (!chosen) throw new Error('no linux variant in the image');
    log(`variants: ${platforms.map((entry) => entry.platform.architecture + (entry.platform.variant ? `/${entry.platform.variant}` : '')).join(', ')} → ${chosen.platform.architecture}`);
    manifest = await (await registry(`manifests/${chosen.digest}`, MANIFESTS)).json();
  }
  const config = await (await registry(`blobs/${manifest.config.digest}`)).json();
  const history = (config.history || []).filter((entry) => !entry.empty_layer);
  const layers = manifest.layers.map((layer, index) => ({ ...layer, index, createdBy: history[index] ? history[index].created_by || '' : '' }));
  for (const layer of layers) log(`layer ${layer.index}: ${mb(layer.size)} · ${layer.createdBy.replace(/\s+/g, ' ').slice(0, 110)}`);
  // The application: the last layer that copies into /app.
  const app = [...layers].reverse().find((layer) => /COPY .*\/app\b|COPY .* \/app\s*$|COPY .* \/app\/?\s*#/.test(layer.createdBy) && /runtime|\/app/.test(layer.createdBy));
  if (!app) throw new Error('no /app layer found in the image history');
  log(`application layer: ${app.index} (${mb(app.size)}, ${app.mediaType})`);
  return { app, digest: manifest.config.digest };
}

// MARK: tar (app/ only; symlinks noted, never created)

class LayerExtractor extends Writable {
  constructor(root, prefix) {
    super();
    this.root = root;
    this.prefix = prefix;
    this.buffer = Buffer.alloc(0);
    this.entry = null;
    this.pax = {};
    this.longName = null;
    this.longLink = null;
    this.links = new Map(); // relative path → link text
    this.files = 0;
    this.bytes = 0;
  }

  static text(block, start, length) {
    const end = block.indexOf(0, start);
    return block.toString('utf8', start, end === -1 || end > start + length ? start + length : end);
  }

  static octal(block, start, length) {
    const text = LayerExtractor.text(block, start, length).trim();
    return text ? parseInt(text, 8) : 0;
  }

  relative(name) {
    let clean = name.replace(/^\.?\//, '');
    if (!clean.startsWith(this.prefix)) return null;
    clean = clean.slice(this.prefix.length).replace(/\/$/, '');
    if (!clean || clean.split('/').includes('..')) return clean ? null : '';
    return clean;
  }

  header(block) {
    if (block.every((byte) => byte === 0)) return;
    let name = LayerExtractor.text(block, 0, 100);
    const size = LayerExtractor.octal(block, 124, 12);
    const mode = LayerExtractor.octal(block, 100, 8) || 0o644;
    const type = String.fromCharCode(block[156] || 48);
    let link = LayerExtractor.text(block, 157, 100);
    const prefix = block.toString('utf8', 257, 263).startsWith('ustar') ? LayerExtractor.text(block, 345, 155) : '';
    if (prefix) name = `${prefix}/${name}`;
    if (this.pax.path) name = this.pax.path;
    if (this.pax.linkpath) link = this.pax.linkpath;
    if (this.longName) name = this.longName;
    if (this.longLink) link = this.longLink;
    const padding = (512 - (size % 512)) % 512;
    if (type === 'x' || type === 'g' || type === 'L' || type === 'K') {
      this.entry = { remaining: size, padding, collect: [], kind: type };
      return;
    }
    this.pax = {};
    this.longName = null;
    this.longLink = null;
    const relative = this.relative(name);
    const base = path.posix.basename(name);
    if (relative === null || base.startsWith('.wh.')) {
      if (size > 0) this.entry = { remaining: size, padding, skip: true };
      return;
    }
    const target = path.join(this.root, relative);
    if (type === '5') {
      fs.mkdirSync(target, { recursive: true });
    } else if (type === '2') {
      this.links.set(relative, link);
    } else if (type === '1') {
      const from = this.relative(link);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      if (from !== null && fs.existsSync(path.join(this.root, from))) fs.copyFileSync(path.join(this.root, from), target);
      this.files++;
    } else if (type === '0' || type === '\0' || type === '7') {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      const fd = fs.openSync(target, 'w', mode & 0o777);
      this.files++;
      this.bytes += size;
      if (size === 0) fs.closeSync(fd);
      else {
        this.entry = { remaining: size, padding, fd };
        return;
      }
    }
    if (size > 0) this.entry = { remaining: size, padding, skip: true };
  }

  finishEntry() {
    const entry = this.entry;
    this.entry = null;
    if (entry.fd !== undefined) fs.closeSync(entry.fd);
    if (!entry.collect) return;
    const data = Buffer.concat(entry.collect);
    if (entry.kind === 'L') this.longName = LayerExtractor.text(data, 0, data.length);
    else if (entry.kind === 'K') this.longLink = LayerExtractor.text(data, 0, data.length);
    else if (entry.kind === 'x') {
      let offset = 0;
      while (offset < data.length) {
        const space = data.indexOf(32, offset);
        if (space === -1) break;
        const length = parseInt(data.toString('utf8', offset, space), 10);
        if (!length) break;
        const record = data.toString('utf8', space + 1, offset + length - 1);
        const equals = record.indexOf('=');
        if (equals > 0) this.pax[record.slice(0, equals)] = record.slice(equals + 1);
        offset += length;
      }
    }
  }

  _write(chunk, encoding, callback) {
    try {
      this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
      let offset = 0;
      for (;;) {
        if (this.entry) {
          if (this.entry.remaining > 0) {
            const take = Math.min(this.entry.remaining, this.buffer.length - offset);
            if (take === 0) break;
            const piece = this.buffer.subarray(offset, offset + take);
            if (this.entry.fd !== undefined) fs.writeSync(this.entry.fd, piece);
            else if (this.entry.collect) this.entry.collect.push(Buffer.from(piece));
            this.entry.remaining -= take;
            offset += take;
            if (this.entry.remaining > 0) break;
          }
          if (this.buffer.length - offset < this.entry.padding) break;
          offset += this.entry.padding;
          this.finishEntry();
          continue;
        }
        if (this.buffer.length - offset < 512) break;
        this.header(this.buffer.subarray(offset, offset + 512));
        offset += 512;
      }
      this.buffer = Buffer.from(this.buffer.subarray(offset));
      callback();
    } catch (error) {
      callback(error);
    }
  }
}

// MARK: the unpacked tree, with its symlinks as a table

class Tree {
  constructor(root, links) {
    this.root = root;
    this.links = links; // relative path → link text
    this.byFolder = new Map(); // folder → names of links in it
    for (const link of links.keys()) {
      const folder = path.posix.dirname(link);
      if (!this.byFolder.has(folder)) this.byFolder.set(folder, new Set());
      this.byFolder.get(folder).add(path.posix.basename(link));
    }
  }

  // Where a path really is, through the noted symlinks ('' = the root).
  real(relative) {
    let current = relative.split('/').filter(Boolean);
    for (let guard = 0; guard < 64; guard++) {
      let changed = false;
      for (let i = 1; i <= current.length; i++) {
        const prefix = current.slice(0, i).join('/');
        const link = this.links.get(prefix);
        if (link === undefined) continue;
        const base = link.startsWith('/')
          ? link.replace(/^\/app\/?/, '')
          : path.posix.join(path.posix.dirname(prefix), link);
        const resolved = path.posix.normalize(base).split('/').filter((part) => part && part !== '.');
        if (resolved.includes('..')) return null; // outside the application
        current = [...resolved, ...current.slice(i)];
        changed = true;
        break;
      }
      if (!changed) return current.join('/');
    }
    return null;
  }

  exists(relative) {
    const real = this.real(relative);
    return real !== null && fs.existsSync(path.join(this.root, real));
  }

  isDirectory(relative) {
    const real = this.real(relative);
    return real !== null && fs.existsSync(path.join(this.root, real)) && fs.statSync(path.join(this.root, real)).isDirectory();
  }

  names(folder) {
    const names = new Set(this.byFolder.get(folder) || []);
    const real = this.real(folder);
    if (real !== null && fs.existsSync(path.join(this.root, real))) {
      for (const entry of fs.readdirSync(path.join(this.root, real))) names.add(entry);
    }
    return [...names].sort();
  }

  // (name, real path) for each package entry of a node_modules folder.
  entries(folder) {
    const found = [];
    for (const name of this.names(folder)) {
      if (name.startsWith('.')) continue;
      const child = `${folder}/${name}`;
      if (name.startsWith('@') && !this.links.has(child)) {
        for (const inner of this.names(child)) found.push([`${name}/${inner}`, this.real(`${child}/${inner}`)]);
      } else {
        found.push([name, this.real(child)]);
      }
    }
    return found.filter(([, real]) => real !== null && fs.existsSync(path.join(this.root, real)));
  }
}

// MARK: flatten (as flatten.py)

// workspace: real path of each AIOStreams package in the tree → its place in the package.
function flatten(tree, stage, workspace) {
  const store = 'node_modules/.pnpm';

  const dependencies = (real) => {
    if (workspace.has(real) || real === '') return tree.entries(real ? `${real}/node_modules` : 'node_modules');
    let container = path.posix.dirname(real);
    if (path.posix.basename(container).startsWith('@')) container = path.posix.dirname(container);
    const own = path.posix.relative(container, real);
    return tree.entries(container).filter(([name]) => name !== own);
  };

  const placements = new Map(); // stage path → real path | { forward: real }
  const queue = [];
  const same = (a, b) => (typeof a === 'string' || typeof b === 'string') ? a === b : a.forward === b.forward;

  const lookup = (location, name) => {
    let folder = location;
    for (;;) {
      if (path.basename(folder) !== 'node_modules') {
        const candidate = path.join(folder, 'node_modules', name);
        if (placements.has(candidate)) return placements.get(candidate);
      }
      if (folder === stage) return null;
      folder = path.dirname(folder);
    }
  };

  const place = (location, real) => {
    for (const [name, target] of dependencies(real)) {
      const wanted = workspace.has(target) ? { forward: target } : target;
      const found = lookup(location, name);
      if (found !== null && same(found, wanted)) continue;
      const spot = found === null ? path.join(stage, 'node_modules', name) : path.join(location, 'node_modules', name);
      if (placements.has(spot)) continue; // the workspace root's own: the server's version stays
      placements.set(spot, wanted);
      if (typeof wanted === 'string') queue.push([spot, wanted]);
    }
  };
  const run = () => { while (queue.length) place(...queue.shift()); };

  // The server first (its versions win the root), then the other packages,
  // then the workspace root, then pnpm's hidden hoisting for undeclared ones.
  const order = [...workspace.keys()].sort((a, b) => (a.endsWith('/server') ? -1 : b.endsWith('/server') ? 1 : a.localeCompare(b)));
  for (const real of order) queue.push([workspace.get(real), real]);
  run();
  queue.push([stage, '']);
  run();
  // Only for packages the server needs: the image's store also holds the web
  // frontend's (an install of the whole project), which must stay out.
  const needed = new Set([...placements.values()].filter((what) => typeof what === 'string'));
  for (const [name, target] of tree.entries(`${store}/node_modules`)) {
    const root = path.join(stage, 'node_modules', name);
    if (!placements.has(root) && !workspace.has(target) && needed.has(target)) {
      placements.set(root, target);
      queue.push([root, target]);
    }
  }
  run();

  // The first place of a package gets it moved there, others a copy.
  let moved = 0;
  let copied = 0;
  let forwards = 0;
  const first = new Map(); // real path → stage path it went to
  const depth = (spot) => spot.split(path.sep).length;
  for (const spot of [...placements.keys()].sort((a, b) => depth(a) - depth(b) || a.localeCompare(b))) {
    const what = placements.get(spot);
    if (typeof what !== 'string') {
      const manifest = JSON.parse(fs.readFileSync(path.join(tree.root, what.forward, 'package.json'), 'utf8'));
      const staged = workspace.get(what.forward);
      let main = manifest.main || 'index.js';
      if (fs.existsSync(path.join(tree.root, what.forward, main)) && fs.statSync(path.join(tree.root, what.forward, main)).isDirectory()) main = path.join(main, 'index.js');
      fs.mkdirSync(spot, { recursive: true });
      let entry = path.relative(spot, path.join(staged, main)).split(path.sep).join('/');
      if (!entry.startsWith('.')) entry = `./${entry}`;
      const module = manifest.type === 'module';
      fs.writeFileSync(path.join(spot, 'package.json'), JSON.stringify({ name: manifest.name, version: manifest.version || '0.0.0', main: 'index.js', ...(module ? { type: 'module' } : {}) }, null, 2));
      fs.writeFileSync(path.join(spot, 'index.js'), module ? `export * from ${JSON.stringify(entry)};\n` : `module.exports = require(${JSON.stringify(entry)});\n`);
      forwards++;
      continue;
    }
    fs.mkdirSync(path.dirname(spot), { recursive: true });
    const placed = first.get(what);
    if (!placed) {
      fs.renameSync(path.join(tree.root, what), spot);
      first.set(what, spot);
      moved++;
    } else {
      const skip = path.join(placed, 'node_modules');
      fs.cpSync(placed, spot, { recursive: true, filter: (source) => source !== skip && !source.startsWith(skip + path.sep) });
      copied++;
    }
  }
  log(`flatten: ${moved} packages, ${copied} extra copies for other versions, ${forwards} forwarding packages`);
}

// Moves a folder into another, merging with what is there already.
function moveInto(source, target) {
  if (!fs.existsSync(target)) {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.renameSync(source, target);
    return;
  }
  if (fs.statSync(source).isDirectory() && fs.statSync(target).isDirectory()) {
    for (const name of fs.readdirSync(source)) moveInto(path.join(source, name), path.join(target, name));
    return;
  }
  fs.rmSync(target, { recursive: true, force: true });
  fs.renameSync(source, target);
}

// MARK: main

fs.rmSync(options.work, { recursive: true, force: true });
fs.rmSync(options.out, { recursive: true, force: true });
const unpacked = path.join(options.work, 'app');
fs.mkdirSync(unpacked, { recursive: true });

// --layer <file>: a layer already on disk (tests), no registry.
const { app, digest } = options.layer ? { app: null, digest: 'local' } : await findAppLayer();
let since = Date.now();
const body = options.layer
  ? fs.createReadStream(options.layer)
  : Readable.fromWeb((await registry(`blobs/${app.digest}`)).body);
const extractor = new LayerExtractor(unpacked, 'app/');
let downloaded = 0;
await pipeline(
  body,
  async function* (source) { for await (const chunk of source) { downloaded += chunk.length; yield chunk; } },
  app && /zstd/.test(app.mediaType || '') ? zlib.createZstdDecompress() : zlib.createGunzip(),
  extractor
);
log(`downloaded ${mb(downloaded)} and unpacked ${extractor.files} files (${mb(extractor.bytes)}), ${extractor.links.size} symlinks noted, in ${seconds(since)}`);

since = Date.now();
const tree = new Tree(unpacked, extractor.links);
log(`node_modules layout: ${fs.existsSync(path.join(unpacked, 'node_modules/.pnpm')) ? 'pnpm (symlinks into node_modules/.pnpm)' : 'flat'}`);
const stage = path.resolve(options.out);
fs.mkdirSync(stage, { recursive: true });
// AIOStreams' own packages (those with a package.json).
const workspace = new Map();
for (const name of tree.names('packages')) {
  if (fs.existsSync(path.join(unpacked, 'packages', name, 'package.json'))) workspace.set(`packages/${name}`, path.join(stage, 'packages', name));
}
log(`AIOStreams packages: ${[...workspace.keys()].join(', ')}`);
flatten(tree, stage, workspace);
// The rest of the application as it is; the packages' own node_modules held
// only symlinks (or a build cache), replaced by the layout above.
fs.rmSync(path.join(unpacked, 'node_modules'), { recursive: true, force: true });
for (const name of fs.readdirSync(path.join(unpacked, 'packages'))) {
  fs.rmSync(path.join(unpacked, 'packages', name, 'node_modules'), { recursive: true, force: true });
}
for (const name of fs.readdirSync(unpacked)) moveInto(path.join(unpacked, name), path.join(stage, name));
log(`node_modules laid out in ${seconds(since)}`);

// Native addons → shims.
since = Date.now();
const shims = { 'better-sqlite3': 'better-sqlite3', bcrypt: 'bcrypt', yencode: 'yencode', '@viren070/fsmux-fuse': 'fsmux-fuse' };
const walk = (folder, visit) => {
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    const full = path.join(folder, entry.name);
    if (visit(full, entry) !== false && entry.isDirectory()) walk(full, visit);
  }
};
walk(stage, (full, entry) => {
  if (!entry.isDirectory()) return;
  const relative = path.relative(stage, full).split(path.sep).join('/');
  for (const [name, shim] of Object.entries(shims)) {
    if (relative === `node_modules/${name}` || relative.endsWith(`/node_modules/${name}`)) {
      fs.rmSync(full, { recursive: true, force: true });
      fs.cpSync(path.join(options.shims, shim), full, { recursive: true });
      if (shim === 'bcrypt' && options.bcryptjs) fs.cpSync(options.bcryptjs, path.join(full, 'node_modules', 'bcryptjs'), { recursive: true });
      log(`shim: ${name} → ${relative}`);
      return false;
    }
  }
  return true;
});
const native = [];
walk(stage, (full, entry) => {
  if (entry.isFile() && (entry.name.endsWith('.node') || entry.name.endsWith('.d.ts') || entry.name.endsWith('.map'))) {
    if (entry.name.endsWith('.node')) native.push(path.relative(stage, full));
    fs.rmSync(full);
  }
});
if (native.length) log(`native addons removed (they cannot load on Apple TV): ${native.join(', ')}`);
fs.copyFileSync(options['nuvio-main'], path.join(stage, 'nuvio-main.mjs'));
fs.writeFileSync(path.join(stage, 'nuvio-package.json'), JSON.stringify({ aiostreams: image.tag, source: options.image, image: digest, built: new Date().toISOString() }));
fs.rmSync(options.work, { recursive: true, force: true });

let files = 0;
let bytes = 0;
let symlinks = 0;
walk(stage, (full, entry) => {
  if (entry.isSymbolicLink()) symlinks++;
  else if (entry.isFile()) { files++; bytes += fs.statSync(full).size; }
});
log(`package: ${files} files, ${mb(bytes)}, ${symlinks} symlinks · shims in ${seconds(since)} · total ${seconds(started)}`);
if (symlinks) process.exitCode = 1;
