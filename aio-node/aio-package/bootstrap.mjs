// Nuvio's entry point for AIOStreams in the embedded Node.js.
//
//   node bootstrap.mjs <aio.tar.gz> <install dir>
//
// Unpacks the AIOStreams package (a tar.gz with the same layout as the
// official Docker image, symlinks included) into <install dir>/<package id>
// unless it is there already, removes older versions, and starts
// nuvio-main.mjs from it. Only Node's own modules: nothing else exists yet.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Writable } from 'node:stream';
import { pathToFileURL } from 'node:url';

const [packagePath, installDir] = process.argv.slice(2);
if (!packagePath || !installDir) {
  throw new Error('[nuvio] usage: bootstrap.mjs <aio.tar.gz> <install dir>');
}

function packageId(file) {
  const stat = fs.statSync(file);
  return crypto.createHash('sha256').update(`${path.basename(file)}:${stat.size}:${stat.mtimeMs}`).digest('hex').slice(0, 16);
}

// A small streaming tar reader: regular files, directories, symlinks and the
// long-name records of PAX (x) and GNU (L/K) archives.
class TarExtractor extends Writable {
  constructor(root) {
    super();
    this.root = path.resolve(root);
    this.buffer = Buffer.alloc(0);
    this.entry = null; // { remaining, padding, fd | collect }
    this.pax = {};
    this.longName = null;
    this.longLink = null;
    this.files = 0;
  }

  target(name) {
    const resolved = path.resolve(this.root, name);
    if (resolved !== this.root && !resolved.startsWith(this.root + path.sep)) {
      throw new Error(`tar entry outside the package: ${name}`);
    }
    return resolved;
  }

  static text(block, start, length) {
    const end = block.indexOf(0, start);
    return block.toString('utf8', start, end === -1 || end > start + length ? start + length : end);
  }

  static octal(block, start, length) {
    const text = TarExtractor.text(block, start, length).trim();
    return text ? parseInt(text, 8) : 0;
  }

  header(block) {
    if (block.every((byte) => byte === 0)) return;
    let name = TarExtractor.text(block, 0, 100);
    const size = TarExtractor.octal(block, 124, 12);
    const mode = TarExtractor.octal(block, 100, 8) || 0o644;
    const type = String.fromCharCode(block[156] || 48);
    let link = TarExtractor.text(block, 157, 100);
    const prefix = block.toString('utf8', 257, 263).startsWith('ustar') ? TarExtractor.text(block, 345, 155) : '';
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
    const target = this.target(name);
    if (type === '5') {
      fs.mkdirSync(target, { recursive: true });
    } else if (type === '2') {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.rmSync(target, { force: true });
      fs.symlinkSync(link, target);
    } else if (type === '1') {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.rmSync(target, { force: true });
      fs.copyFileSync(this.target(link), target);
      this.files++;
    } else if (type === '0' || type === '\0' || type === '7') {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      const fd = fs.openSync(target, 'w', mode & 0o777);
      this.files++;
      if (size === 0) {
        fs.closeSync(fd);
      } else {
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
    if (entry.collect) {
      const data = Buffer.concat(entry.collect);
      if (entry.kind === 'L') this.longName = TarExtractor.text(data, 0, data.length);
      else if (entry.kind === 'K') this.longLink = TarExtractor.text(data, 0, data.length);
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

const id = packageId(packagePath);
const root = path.join(installDir, id);
const marker = path.join(root, '.nuvio-complete');
if (!fs.existsSync(marker)) {
  const started = Date.now();
  const temporary = `${root}.partial`;
  fs.rmSync(temporary, { recursive: true, force: true });
  fs.mkdirSync(temporary, { recursive: true });
  console.log(`[nuvio] unpacking ${path.basename(packagePath)} (${Math.round(fs.statSync(packagePath).size / 1048576)} MB)…`);
  const extractor = new TarExtractor(temporary);
  await pipeline(fs.createReadStream(packagePath), zlib.createGunzip(), extractor);
  fs.writeFileSync(path.join(temporary, '.nuvio-complete'), new Date().toISOString());
  fs.rmSync(root, { recursive: true, force: true });
  fs.renameSync(temporary, root);
  console.log(`[nuvio] unpacked ${extractor.files} files in ${((Date.now() - started) / 1000).toFixed(1)} s`);
}
for (const name of fs.readdirSync(installDir)) {
  if (name !== id) fs.rmSync(path.join(installDir, name), { recursive: true, force: true });
}

process.env.AIO_ROOT = root;
await import(pathToFileURL(path.join(root, 'nuvio-main.mjs')).href);
