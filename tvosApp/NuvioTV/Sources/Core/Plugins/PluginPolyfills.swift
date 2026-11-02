import Foundation

/// Browser-style globals for plugin JavaScript, evaluated into every plugin
/// context before the plugin's own code: console, timers, fetch (Headers,
/// Request, Response, AbortController), URL / URLSearchParams, TextEncoder /
/// TextDecoder, atob / btoa, and crypto (getRandomValues, randomUUID, subtle
/// digest and HMAC). Natives come from `__nuvioNative`, which
/// `PluginExecution` installs first. Tested as plain JavaScript as well, so
/// keep it free of Swift interpolation.
enum PluginPolyfills {
    static let source = #"""
(function (G) {
  'use strict';
  var N = G.__nuvioNative;

  G.globalThis = G;
  G.window = G;
  G.self = G;
  G.global = G;
  G.NUVIO_PLATFORM = 'tvos';

  function describe(value) {
    if (typeof value === 'string') return value;
    if (value instanceof Error) return value.stack ? value.message + '\n' + value.stack : String(value);
    if (value === undefined) return 'undefined';
    try {
      var json = JSON.stringify(value);
      return json === undefined ? String(value) : json;
    } catch (e) {
      return String(value);
    }
  }

  function errorText(error) {
    if (error == null) return 'Unknown error';
    if (typeof error === 'string') return error;
    var message = error.message ? String(error.message) : String(error);
    return error.stack ? message + '\n' + error.stack : message;
  }
  G.__nuvioErrorText = errorText;

  function logger(level) {
    return function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) parts.push(describe(arguments[i]));
      N.log(level, parts.join(' '));
    };
  }
  G.console = {
    log: logger('log'), info: logger('info'), debug: logger('debug'),
    warn: logger('warn'), error: logger('error'), trace: logger('debug')
  };

  // ---- timers -------------------------------------------------------------
  var timers = {};
  var timerSeq = 0;
  function schedule(fn, ms, args, repeat) {
    var id = ++timerSeq;
    var delay = Math.max(0, Number(ms) || 0);
    timers[id] = { fn: fn, args: args, repeat: repeat, ms: delay };
    N.setTimer(id, delay);
    return id;
  }
  G.setTimeout = function (fn, ms) { return schedule(fn, ms, Array.prototype.slice.call(arguments, 2), false); };
  G.setInterval = function (fn, ms) { return schedule(fn, ms, Array.prototype.slice.call(arguments, 2), true); };
  G.clearTimeout = G.clearInterval = function (id) {
    if (timers[id]) {
      delete timers[id];
      N.clearTimer(id);
    }
  };
  G.__nuvioTimerFired = function (id) {
    var timer = timers[id];
    if (!timer) return;
    if (timer.repeat) N.setTimer(id, timer.ms); else delete timers[id];
    try {
      if (typeof timer.fn === 'function') timer.fn.apply(G, timer.args);
    } catch (e) {
      N.log('error', 'Timer callback failed: ' + errorText(e));
    }
  };
  G.queueMicrotask = function (fn) { Promise.resolve().then(fn); };

  // ---- base64 / UTF-8 -----------------------------------------------------
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function bytesToBase64(bytes) {
    var out = '';
    var i = 0;
    for (; i + 2 < bytes.length; i += 3) {
      var n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
    }
    if (i < bytes.length) {
      var rest = bytes.length - i;
      var m = (bytes[i] << 16) | (rest > 1 ? bytes[i + 1] << 8 : 0);
      out += B64[(m >> 18) & 63] + B64[(m >> 12) & 63] + (rest > 1 ? B64[(m >> 6) & 63] : '=') + '=';
    }
    return out;
  }
  function base64ToBytes(text) {
    var clean = String(text).replace(/[\s=]/g, '').replace(/-/g, '+').replace(/_/g, '/');
    if (/[^A-Za-z0-9+/]/.test(clean)) throw new Error('Invalid base64');
    var out = new Uint8Array(Math.floor(clean.length * 3 / 4));
    var buffer = 0, bits = 0, index = 0;
    for (var i = 0; i < clean.length; i++) {
      buffer = (buffer << 6) | B64.indexOf(clean[i]);
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out[index++] = (buffer >> bits) & 255;
      }
    }
    return out.subarray(0, index);
  }
  function utf8Encode(text) {
    var str = String(text);
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
        var next = str.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
          i++;
        } else {
          code = 0xfffd;
        }
      } else if (code >= 0xd800 && code <= 0xdfff) {
        code = 0xfffd;
      }
      if (code < 0x80) out.push(code);
      else if (code < 0x800) out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
      else if (code < 0x10000) out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      else out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
    }
    return new Uint8Array(out);
  }
  function utf8Decode(bytes) {
    var out = '';
    var i = 0;
    while (i < bytes.length) {
      var b = bytes[i++];
      var code;
      if (b < 0x80) code = b;
      else if (b >= 0xc2 && b < 0xe0 && i < bytes.length && (bytes[i] & 0xc0) === 0x80) {
        code = ((b & 31) << 6) | (bytes[i++] & 63);
      } else if (b >= 0xe0 && b < 0xf0 && i + 1 < bytes.length && (bytes[i] & 0xc0) === 0x80 && (bytes[i + 1] & 0xc0) === 0x80) {
        code = ((b & 15) << 12) | ((bytes[i] & 63) << 6) | (bytes[i + 1] & 63);
        i += 2;
      } else if (b >= 0xf0 && b < 0xf5 && i + 2 < bytes.length && (bytes[i] & 0xc0) === 0x80 && (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80) {
        code = ((b & 7) << 18) | ((bytes[i] & 63) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63);
        i += 3;
      } else {
        code = 0xfffd;
      }
      if (code > 0xffff) {
        code -= 0x10000;
        out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 1023));
      } else {
        out += String.fromCharCode(code);
      }
    }
    return out;
  }
  function toBytes(data) {
    if (data == null) return new Uint8Array(0);
    if (typeof data === 'string') return utf8Encode(data);
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    return utf8Encode(String(data));
  }
  function bufferFrom(bytes) {
    var copy = new Uint8Array(bytes.length);
    copy.set(bytes);
    return copy.buffer;
  }

  G.btoa = function (text) {
    var str = String(text);
    var bytes = new Uint8Array(str.length);
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code > 255) throw new Error("btoa: the string contains characters outside of the Latin1 range");
      bytes[i] = code;
    }
    return bytesToBase64(bytes);
  };
  G.atob = function (text) {
    var bytes = base64ToBytes(text);
    var out = '';
    for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
    return out;
  };

  function TextEncoder() {}
  TextEncoder.prototype.encoding = 'utf-8';
  TextEncoder.prototype.encode = function (text) { return utf8Encode(text === undefined ? '' : text); };
  G.TextEncoder = TextEncoder;
  function TextDecoder(label) {
    var name = String(label || 'utf-8').toLowerCase();
    if (name !== 'utf-8' && name !== 'utf8') throw new RangeError('TextDecoder supports only UTF-8');
  }
  TextDecoder.prototype.encoding = 'utf-8';
  TextDecoder.prototype.decode = function (data) { return utf8Decode(toBytes(data === undefined ? new Uint8Array(0) : data)); };
  G.TextDecoder = TextDecoder;

  // ---- URLSearchParams ----------------------------------------------------
  function decodeComponent(text) {
    try { return decodeURIComponent(text.replace(/\+/g, ' ')); } catch (e) { return text; }
  }
  function encodeComponent(text) {
    return encodeURIComponent(text).replace(/%20/g, '+').replace(/[!'()~]/g, function (c) {
      return '%' + c.charCodeAt(0).toString(16).toUpperCase();
    });
  }
  function URLSearchParams(init) {
    this._list = [];
    this._url = null;
    if (init == null || init === '') return;
    if (init instanceof URLSearchParams) {
      this._list = init._list.map(function (pair) { return [pair[0], pair[1]]; });
    } else if (typeof init === 'string') {
      this._parse(init);
    } else if (Array.isArray(init)) {
      for (var i = 0; i < init.length; i++) this._list.push([String(init[i][0]), String(init[i][1])]);
    } else if (typeof init === 'object') {
      for (var key in init) if (Object.prototype.hasOwnProperty.call(init, key)) this._list.push([key, String(init[key])]);
    }
  }
  URLSearchParams.prototype._parse = function (text) {
    var query = String(text);
    if (query.charAt(0) === '?') query = query.slice(1);
    this._list = [];
    if (!query) return;
    var parts = query.split('&');
    for (var i = 0; i < parts.length; i++) {
      if (!parts[i]) continue;
      var eq = parts[i].indexOf('=');
      var name = eq >= 0 ? parts[i].slice(0, eq) : parts[i];
      var value = eq >= 0 ? parts[i].slice(eq + 1) : '';
      this._list.push([decodeComponent(name), decodeComponent(value)]);
    }
  };
  URLSearchParams.prototype._update = function () {
    if (this._url) {
      var text = this.toString();
      this._url._search = text ? '?' + text : '';
    }
  };
  URLSearchParams.prototype.append = function (name, value) { this._list.push([String(name), String(value)]); this._update(); };
  URLSearchParams.prototype.delete = function (name) {
    name = String(name);
    this._list = this._list.filter(function (pair) { return pair[0] !== name; });
    this._update();
  };
  URLSearchParams.prototype.get = function (name) {
    name = String(name);
    for (var i = 0; i < this._list.length; i++) if (this._list[i][0] === name) return this._list[i][1];
    return null;
  };
  URLSearchParams.prototype.getAll = function (name) {
    name = String(name);
    return this._list.filter(function (pair) { return pair[0] === name; }).map(function (pair) { return pair[1]; });
  };
  URLSearchParams.prototype.has = function (name) { return this.get(name) !== null; };
  URLSearchParams.prototype.set = function (name, value) {
    name = String(name);
    var found = false;
    var next = [];
    for (var i = 0; i < this._list.length; i++) {
      if (this._list[i][0] === name) {
        if (!found) next.push([name, String(value)]);
        found = true;
      } else {
        next.push(this._list[i]);
      }
    }
    if (!found) next.push([name, String(value)]);
    this._list = next;
    this._update();
  };
  URLSearchParams.prototype.sort = function () {
    this._list.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
    this._update();
  };
  URLSearchParams.prototype.forEach = function (callback, thisArg) {
    for (var i = 0; i < this._list.length; i++) callback.call(thisArg, this._list[i][1], this._list[i][0], this);
  };
  URLSearchParams.prototype.toString = function () {
    return this._list.map(function (pair) { return encodeComponent(pair[0]) + '=' + encodeComponent(pair[1]); }).join('&');
  };
  URLSearchParams.prototype.entries = function () { return this._list.map(function (p) { return [p[0], p[1]]; })[Symbol.iterator](); };
  URLSearchParams.prototype.keys = function () { return this._list.map(function (p) { return p[0]; })[Symbol.iterator](); };
  URLSearchParams.prototype.values = function () { return this._list.map(function (p) { return p[1]; })[Symbol.iterator](); };
  URLSearchParams.prototype[Symbol.iterator] = URLSearchParams.prototype.entries;
  Object.defineProperty(URLSearchParams.prototype, 'size', { get: function () { return this._list.length; } });
  G.URLSearchParams = URLSearchParams;

  // ---- URL (hierarchical schemes; enough for API clients) ------------------
  var DEFAULT_PORTS = { 'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443', 'ftp:': '21' };
  var URL_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(\/\/([^/?#]*))?([^?#]*)(\?[^#]*)?(#[\s\S]*)?$/;

  function removeDotSegments(path) {
    var input = path.split('/');
    var output = [];
    for (var i = 0; i < input.length; i++) {
      var seg = input[i];
      if (seg === '..') {
        if (output.length > 1) output.pop();
        if (i === input.length - 1) output.push('');
      } else if (seg === '.') {
        if (i === input.length - 1) output.push('');
      } else {
        output.push(seg);
      }
    }
    var joined = output.join('/');
    if (path.charAt(0) === '/' && joined.charAt(0) !== '/') joined = '/' + joined;
    return joined;
  }

  function encodePathLike(text) {
    return text.replace(/[^A-Za-z0-9\-._~!$&'()*+,;=:@/%]/g, function (c) { return encodeURIComponent(c); })
      .replace(/%(?![0-9A-Fa-f]{2})/g, '%25');
  }
  function encodeQueryLike(text) {
    return text.replace(/[^A-Za-z0-9\-._~!$&'()*+,;=:@/?%]/g, function (c) { return encodeURIComponent(c); })
      .replace(/%(?![0-9A-Fa-f]{2})/g, '%25');
  }

  function parseAuthority(authority) {
    var result = { username: '', password: '', hostname: '', port: '' };
    var at = authority.lastIndexOf('@');
    if (at >= 0) {
      var userinfo = authority.slice(0, at);
      authority = authority.slice(at + 1);
      var colon = userinfo.indexOf(':');
      result.username = colon >= 0 ? userinfo.slice(0, colon) : userinfo;
      result.password = colon >= 0 ? userinfo.slice(colon + 1) : '';
    }
    var portMatch = /^(\[[^\]]*\]|[^:]*)(?::(\d*))?$/.exec(authority);
    if (!portMatch) throw new TypeError('Invalid URL');
    result.hostname = portMatch[1].toLowerCase();
    result.port = portMatch[2] || '';
    return result;
  }

  function URL(input, base) {
    if (!(this instanceof URL)) throw new TypeError("Constructor URL requires 'new'");
    var text = String(input).replace(/^[\u0000- ]+|[\u0000- ]+$/g, '').replace(/[\t\n\r]/g, '');
    var match = URL_RE.exec(text);
    if (!match) throw new TypeError('Invalid URL: ' + text);
    var scheme = match[1];
    if (!scheme) {
      if (base === undefined) throw new TypeError('Invalid URL: ' + text);
      var baseURL = base instanceof URL ? base : new URL(base);
      this._protocol = baseURL._protocol;
      if (match[2] !== undefined) {
        this._setAuthority(match[3]);
        this._pathname = removeDotSegments(match[4] || '/') || '/';
        this._search = match[5] || '';
      } else {
        this._username = baseURL._username;
        this._password = baseURL._password;
        this._hostname = baseURL._hostname;
        this._port = baseURL._port;
        var path = match[4];
        if (path === '') {
          this._pathname = baseURL._pathname;
          this._search = match[5] !== undefined ? match[5] : baseURL._search;
        } else {
          if (path.charAt(0) !== '/') {
            var dir = baseURL._pathname.slice(0, baseURL._pathname.lastIndexOf('/') + 1) || '/';
            path = dir + path;
          }
          this._pathname = removeDotSegments(path);
          this._search = match[5] || '';
        }
      }
    } else {
      this._protocol = scheme.toLowerCase();
      if (match[2] === undefined && this._special()) {
        throw new TypeError('Invalid URL: ' + text);
      }
      if (match[2] !== undefined) {
        this._setAuthority(match[3]);
        this._pathname = removeDotSegments(match[4] || '') || (this._special() ? '/' : '');
      } else {
        this._username = this._password = this._hostname = this._port = '';
        this._pathname = match[4] || '';
        this._opaque = true;
      }
      this._search = match[5] || '';
    }
    this._hash = match[6] || '';
    if (this._search === '?') this._search = '';
    if (this._hash === '#') this._hash = '';
    this._pathname = this._opaque ? this._pathname : encodePathLike(this._pathname);
    this._search = encodeQueryLike(this._search);
    if (DEFAULT_PORTS[this._protocol] === this._port) this._port = '';
    var params = new URLSearchParams(this._search);
    params._url = this;
    this._params = params;
  }
  URL.prototype._special = function () { return Object.prototype.hasOwnProperty.call(DEFAULT_PORTS, this._protocol) || this._protocol === 'file:'; };
  URL.prototype._setAuthority = function (authority) {
    var parsed = parseAuthority(authority || '');
    this._username = parsed.username;
    this._password = parsed.password;
    this._hostname = parsed.hostname;
    this._port = parsed.port;
    if (!this._hostname && this._special() && this._protocol !== 'file:') throw new TypeError('Invalid URL');
  };
  function accessor(name, get, set) {
    Object.defineProperty(URL.prototype, name, { get: get, set: set, enumerable: true, configurable: true });
  }
  accessor('protocol', function () { return this._protocol; }, function (v) {
    var p = String(v).toLowerCase();
    this._protocol = p.charAt(p.length - 1) === ':' ? p : p + ':';
  });
  accessor('username', function () { return this._username; }, function (v) { this._username = String(v); });
  accessor('password', function () { return this._password; }, function (v) { this._password = String(v); });
  accessor('hostname', function () { return this._hostname; }, function (v) { this._hostname = String(v).toLowerCase(); });
  accessor('port', function () { return this._port; }, function (v) {
    var p = String(v);
    this._port = DEFAULT_PORTS[this._protocol] === p ? '' : p;
  });
  accessor('host', function () { return this._hostname + (this._port ? ':' + this._port : ''); }, function (v) {
    var parsed = parseAuthority(String(v));
    this._hostname = parsed.hostname;
    this._port = DEFAULT_PORTS[this._protocol] === parsed.port ? '' : parsed.port;
  });
  accessor('origin', function () {
    if (this._opaque || !this._special() || this._protocol === 'file:') return 'null';
    return this._protocol + '//' + this.host;
  });
  accessor('pathname', function () { return this._pathname; }, function (v) {
    var p = String(v);
    if (!this._opaque && p.charAt(0) !== '/') p = '/' + p;
    this._pathname = this._opaque ? p : encodePathLike(p);
  });
  accessor('search', function () { return this._search; }, function (v) {
    var s = String(v);
    if (s && s.charAt(0) !== '?') s = '?' + s;
    this._search = s === '?' ? '' : encodeQueryLike(s);
    this._params._parse(this._search);
  });
  accessor('searchParams', function () { return this._params; });
  accessor('hash', function () { return this._hash; }, function (v) {
    var h = String(v);
    if (h && h.charAt(0) !== '#') h = '#' + h;
    this._hash = h === '#' ? '' : h;
  });
  accessor('href', function () {
    if (this._opaque) return this._protocol + this._pathname + this._search + this._hash;
    var auth = this._username ? this._username + (this._password ? ':' + this._password : '') + '@' : '';
    return this._protocol + '//' + auth + this.host + this._pathname + this._search + this._hash;
  }, function (v) {
    var next = new URL(String(v));
    for (var key in next) if (Object.prototype.hasOwnProperty.call(next, key)) this[key] = next[key];
    this._params._url = this;
  });
  URL.prototype.toString = function () { return this.href; };
  URL.prototype.toJSON = function () { return this.href; };
  URL.canParse = function (input, base) {
    try { new URL(input, base); return true; } catch (e) { return false; }
  };
  G.URL = URL;

  // ---- events / abort -----------------------------------------------------
  function SimpleEventTarget() { this._listeners = {}; }
  SimpleEventTarget.prototype.addEventListener = function (type, listener) {
    if (typeof listener !== 'function') return;
    (this._listeners[type] = this._listeners[type] || []).push(listener);
  };
  SimpleEventTarget.prototype.removeEventListener = function (type, listener) {
    var list = this._listeners[type];
    if (list) this._listeners[type] = list.filter(function (l) { return l !== listener; });
  };
  SimpleEventTarget.prototype.dispatchEvent = function (event) {
    var list = (this._listeners[event.type] || []).slice();
    var handler = this['on' + event.type];
    if (typeof handler === 'function') list.unshift(handler);
    for (var i = 0; i < list.length; i++) {
      try { list[i].call(this, event); } catch (e) { N.log('error', 'Event listener failed: ' + errorText(e)); }
    }
    return true;
  };
  G.EventTarget = SimpleEventTarget;

  function makeAbortError(reason) {
    if (reason !== undefined) return reason;
    var error = new Error('The operation was aborted.');
    error.name = 'AbortError';
    return error;
  }
  function AbortSignal() {
    SimpleEventTarget.call(this);
    this.aborted = false;
    this.reason = undefined;
    this.onabort = null;
  }
  AbortSignal.prototype = Object.create(SimpleEventTarget.prototype);
  AbortSignal.prototype.constructor = AbortSignal;
  AbortSignal.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };
  AbortSignal.prototype._abort = function (reason) {
    if (this.aborted) return;
    this.aborted = true;
    this.reason = makeAbortError(reason);
    this.dispatchEvent({ type: 'abort', target: this });
  };
  AbortSignal.abort = function (reason) { var s = new AbortSignal(); s._abort(reason); return s; };
  AbortSignal.timeout = function (ms) {
    var s = new AbortSignal();
    G.setTimeout(function () {
      var error = new Error('The operation timed out.');
      error.name = 'TimeoutError';
      s._abort(error);
    }, ms);
    return s;
  };
  AbortSignal.any = function (signals) {
    var s = new AbortSignal();
    for (var i = 0; i < signals.length; i++) {
      (function (source) {
        if (source.aborted) s._abort(source.reason);
        else source.addEventListener('abort', function () { s._abort(source.reason); });
      })(signals[i]);
    }
    return s;
  };
  function AbortController() { this.signal = new AbortSignal(); }
  AbortController.prototype.abort = function (reason) { this.signal._abort(reason); };
  G.AbortSignal = AbortSignal;
  G.AbortController = AbortController;

  // ---- Headers / Response / fetch -----------------------------------------
  function Headers(init) {
    this._map = {};
    if (init == null) return;
    if (init instanceof Headers) {
      for (var k in init._map) this._map[k] = init._map[k].slice();
    } else if (Array.isArray(init)) {
      for (var i = 0; i < init.length; i++) this.append(init[i][0], init[i][1]);
    } else if (typeof init === 'object') {
      for (var key in init) if (Object.prototype.hasOwnProperty.call(init, key)) this.append(key, init[key]);
    }
  }
  Headers.prototype.append = function (name, value) {
    var key = String(name).toLowerCase();
    (this._map[key] = this._map[key] || []).push(String(value));
  };
  Headers.prototype.set = function (name, value) { this._map[String(name).toLowerCase()] = [String(value)]; };
  Headers.prototype.get = function (name) {
    var list = this._map[String(name).toLowerCase()];
    return list ? list.join(', ') : null;
  };
  Headers.prototype.has = function (name) { return Object.prototype.hasOwnProperty.call(this._map, String(name).toLowerCase()); };
  Headers.prototype.delete = function (name) { delete this._map[String(name).toLowerCase()]; };
  Headers.prototype.forEach = function (callback, thisArg) {
    var keys = Object.keys(this._map).sort();
    for (var i = 0; i < keys.length; i++) callback.call(thisArg, this.get(keys[i]), keys[i], this);
  };
  Headers.prototype.entries = function () {
    var self = this;
    return Object.keys(this._map).sort().map(function (k) { return [k, self.get(k)]; })[Symbol.iterator]();
  };
  Headers.prototype.keys = function () { return Object.keys(this._map).sort()[Symbol.iterator](); };
  Headers.prototype.values = function () {
    var self = this;
    return Object.keys(this._map).sort().map(function (k) { return self.get(k); })[Symbol.iterator]();
  };
  Headers.prototype[Symbol.iterator] = Headers.prototype.entries;
  Headers.prototype.getSetCookie = function () { return (this._map['set-cookie'] || []).slice(); };
  G.Headers = Headers;

  function Response(body, init) {
    init = init || {};
    this.status = init.status === undefined ? 200 : init.status;
    this.statusText = init.statusText || '';
    this.ok = this.status >= 200 && this.status < 300;
    this.headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers);
    this.url = init.url || '';
    this.redirected = !!init.redirected;
    this.type = 'basic';
    this.bodyUsed = false;
    this._base64 = init._base64 || null;
    if (body == null) this._text = this._base64 != null ? null : '';
    else if (typeof body === 'string') this._text = body;
    else if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
      this._base64 = bytesToBase64(toBytes(body));
      this._text = null;
    } else this._text = String(body);
  }
  Response.prototype._consume = function () {
    if (this.bodyUsed) return Promise.reject(new TypeError('Body has already been consumed.'));
    this.bodyUsed = true;
    return Promise.resolve();
  };
  Response.prototype._bytes = function () {
    if (this._base64 != null) return base64ToBytes(this._base64);
    return utf8Encode(this._text || '');
  };
  Response.prototype.text = function () {
    var self = this;
    return this._consume().then(function () {
      return self._text != null ? self._text : utf8Decode(self._bytes());
    });
  };
  Response.prototype.json = function () {
    var self = this;
    return this._consume().then(function () {
      var text = self._text != null ? self._text : utf8Decode(self._bytes());
      return JSON.parse(text);
    });
  };
  Response.prototype.arrayBuffer = function () {
    var self = this;
    return this._consume().then(function () { return bufferFrom(self._bytes()); });
  };
  Response.prototype.bytes = function () {
    var self = this;
    return this._consume().then(function () { return new Uint8Array(bufferFrom(self._bytes())); });
  };
  Response.prototype.clone = function () {
    if (this.bodyUsed) throw new TypeError('Response body is already used');
    return new Response(this._text, {
      status: this.status, statusText: this.statusText, headers: new Headers(this.headers),
      url: this.url, redirected: this.redirected, _base64: this._base64
    });
  };
  Response.json = function (data, init) {
    init = init || {};
    var headers = new Headers(init.headers);
    if (!headers.has('content-type')) headers.set('content-type', 'application/json');
    return new Response(JSON.stringify(data), { status: init.status, statusText: init.statusText, headers: headers });
  };
  G.Response = Response;

  function Request(input, init) {
    init = init || {};
    var source = input instanceof Request ? input : null;
    this.url = source ? source.url : String(input instanceof URL ? input.href : input);
    this.method = String(init.method || (source && source.method) || 'GET').toUpperCase();
    this.headers = new Headers(init.headers || (source && source.headers));
    this.body = init.body !== undefined ? init.body : (source ? source.body : null);
    this.signal = init.signal || (source && source.signal) || null;
    this.redirect = init.redirect || (source && source.redirect) || 'follow';
  }
  G.Request = Request;

  var pending = {};
  var fetchSeq = 0;
  G.fetch = function (input, init) {
    return new Promise(function (resolve, reject) {
      var request;
      try { request = new Request(input, init); } catch (e) { reject(e); return; }
      var url;
      try { url = new URL(request.url).href; } catch (e) { reject(new TypeError('Invalid URL: ' + request.url)); return; }
      var headers = {};
      request.headers.forEach(function (value, key) { headers[key] = value; });
      var body = request.body;
      var payload = { method: request.method, headers: headers, redirect: request.redirect };
      if (body != null) {
        if (body instanceof URLSearchParams) {
          payload.body = body.toString();
          if (!request.headers.has('content-type')) payload.headers['content-type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
        } else if (typeof body === 'string') {
          payload.body = body;
        } else if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
          payload.bodyBase64 = bytesToBase64(toBytes(body));
        } else {
          payload.body = String(body);
        }
      }
      var signal = request.signal;
      if (signal && signal.aborted) { reject(signal.reason || makeAbortError()); return; }
      var id = ++fetchSeq;
      pending[id] = { resolve: resolve, reject: reject };
      if (signal) {
        signal.addEventListener('abort', function () {
          if (!pending[id]) return;
          delete pending[id];
          N.abortFetch(id);
          reject(signal.reason || makeAbortError());
        });
      }
      N.fetch(id, url, JSON.stringify(payload));
    });
  };
  G.__nuvioFetchDone = function (id, json) {
    var entry = pending[id];
    if (!entry) return;
    delete pending[id];
    var result;
    try { result = JSON.parse(json); } catch (e) { entry.reject(new TypeError('Network response could not be read')); return; }
    if (result.error) { entry.reject(new TypeError(result.error)); return; }
    var headers = new Headers();
    var raw = result.headers || {};
    for (var key in raw) if (Object.prototype.hasOwnProperty.call(raw, key)) headers.append(key, raw[key]);
    entry.resolve(new Response(result.text != null ? result.text : null, {
      status: result.status,
      statusText: result.statusText || '',
      headers: headers,
      url: result.url || '',
      redirected: !!result.redirected,
      _base64: result.base64 || null
    }));
  };

  // ---- crypto -------------------------------------------------------------
  var HASHES = { 'SHA-1': 'SHA-1', 'SHA1': 'SHA-1', 'SHA-256': 'SHA-256', 'SHA256': 'SHA-256',
    'SHA-384': 'SHA-384', 'SHA384': 'SHA-384', 'SHA-512': 'SHA-512', 'SHA512': 'SHA-512', 'MD5': 'MD5' };
  function hashName(algorithm) {
    var name = typeof algorithm === 'string' ? algorithm : (algorithm && (algorithm.name || (algorithm.hash && (algorithm.hash.name || algorithm.hash))));
    var normalized = HASHES[String(name || '').toUpperCase()];
    if (!normalized) throw new Error('Unsupported algorithm: ' + name);
    return normalized;
  }
  var subtle = {
    digest: function (algorithm, data) {
      try {
        var out = N.digest(hashName(algorithm), bytesToBase64(toBytes(data)));
        return Promise.resolve(bufferFrom(base64ToBytes(out)));
      } catch (e) { return Promise.reject(e); }
    },
    importKey: function (format, keyData, algorithm, extractable, usages) {
      if (format !== 'raw') return Promise.reject(new Error('Only raw keys are supported'));
      var name = algorithm && algorithm.name ? String(algorithm.name).toUpperCase() : String(algorithm).toUpperCase();
      if (name !== 'HMAC') return Promise.reject(new Error('Only HMAC keys are supported'));
      return Promise.resolve({ type: 'secret', algorithm: { name: 'HMAC', hash: { name: hashName(algorithm.hash) } },
        extractable: !!extractable, usages: usages || [], _raw: bytesToBase64(toBytes(keyData)) });
    },
    sign: function (algorithm, key, data) {
      try {
        var out = N.hmac(key.algorithm.hash.name, key._raw, bytesToBase64(toBytes(data)));
        return Promise.resolve(bufferFrom(base64ToBytes(out)));
      } catch (e) { return Promise.reject(e); }
    }
  };
  G.crypto = {
    subtle: subtle,
    getRandomValues: function (array) {
      if (!ArrayBuffer.isView(array)) throw new TypeError('Expected a typed array');
      var bytes = base64ToBytes(N.randomBytes(array.byteLength));
      new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
      return array;
    },
    randomUUID: function () {
      var b = base64ToBytes(N.randomBytes(16));
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      var hex = '';
      for (var i = 0; i < 16; i++) hex += (b[i] < 16 ? '0' : '') + b[i].toString(16);
      return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
    }
  };

  G.structuredClone = function (value) { return value === undefined ? undefined : JSON.parse(JSON.stringify(value)); };

  G.require = function (name) {
    throw new Error("require('" + name + "') is not available in Nuvio plugins on Apple TV; bundle the module into the plugin file.");
  };

  // ---- invocation ---------------------------------------------------------
  G.__nuvioInvoke = function (name, args) {
    var exported = G.module && G.module.exports;
    var target = exported && typeof exported[name] === 'function' ? exported[name]
      : (typeof G[name] === 'function' ? G[name] : null);
    if (!target) {
      N.done(null, '__missing__');
      return;
    }
    var settled = false;
    function succeed(value) {
      if (settled) return;
      settled = true;
      var json;
      try { json = JSON.stringify(value === undefined ? null : value); } catch (e) {
        N.done(null, 'The result could not be serialized: ' + errorText(e));
        return;
      }
      N.done(json === undefined ? 'null' : json, null);
    }
    function fail(error) {
      if (settled) return;
      settled = true;
      N.done(null, errorText(error));
    }
    try {
      Promise.resolve(target.apply(exported || G, args || [])).then(succeed, fail);
    } catch (e) {
      fail(e);
    }
  };
})(this);
"""#
}
