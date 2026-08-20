// VortX community JS provider runtime preamble.
//
// This file is the host-API shim that a bare JavaScriptCore context does NOT provide. The native
// runtime (JSProviderRuntime.swift) creates a FRESH JSContext per provider call, injects a small set
// of native primitives (all names prefixed `__vortx_native_*`), captures the two bundled libraries as
// `globalThis.__vortx_cryptojs` / `globalThis.__vortx_cheerio`, evaluates THIS file, then calls
// `__vortx_run(...)`. Everything a compatible community provider expects (fetch, axios, a gated require that
// only yields cheerio + crypto-js, console, timers, JSON/Date/Math, encode/decodeURIComponent, URL /
// URLSearchParams, atob/btoa, TextEncoder/TextDecoder, module/exports/global + a window alias,
// globalThis.SCRAPER_SETTINGS / SCRAPER_ID, and an injected TMDB_API_KEY) is assembled HERE, on top of
// those primitives, so the provider contract is a strict superset of the community host contract and
// unmodified providers load.
//
// SANDBOX: the provider runs inside `new Function(...)` (a plain function scope, not eval, not a
// WebView), exactly the community harness shape, so `getStreams` resolves the same three ways. The
// context is disposable and holds NOTHING from the host bridge except the injected primitives; the
// outbound URL policy and the hard per-call timeout are enforced natively (they cannot be reached or
// disabled from here). No filesystem, no native modules, no host secrets.
//
// TESTABILITY: this is a single self-contained file with no external dependency, so it is exercised
// offline in a bare VM context (see the node harness used during development) against the real bundled
// crypto-js + cheerio before it ever ships. Keep it dependency-free.
(function () {
  'use strict';

  var G = (typeof globalThis !== 'undefined') ? globalThis : this;

  // ------------------------------------------------------------------ console
  // Route console.* to the native logger (rate-limited on the Swift side). Levels map to a single
  // native call so the host controls volume and redaction.
  function nativeLog(level, args) {
    try {
      var parts = [];
      for (var i = 0; i < args.length; i++) {
        var a = args[i];
        if (typeof a === 'string') { parts.push(a); }
        else { try { parts.push(JSON.stringify(a)); } catch (e) { parts.push(String(a)); } }
      }
      __vortx_native_log(level, parts.join(' '));
    } catch (e) { /* logging must never throw into provider code */ }
  }
  G.console = {
    log: function () { nativeLog('log', arguments); },
    info: function () { nativeLog('log', arguments); },
    warn: function () { nativeLog('warn', arguments); },
    error: function () { nativeLog('error', arguments); },
    debug: function () { nativeLog('log', arguments); },
  };

  // ------------------------------------------------------------------ timers
  // setTimeout / clearTimeout delegate to native scheduling on the runtime queue so the host can cancel
  // every pending timer at teardown. A bare JSC context provides neither.
  G.setTimeout = function (fn, ms) {
    if (typeof fn !== 'function') { return 0; }
    return __vortx_native_set_timeout(fn, (typeof ms === 'number' && ms >= 0) ? ms : 0);
  };
  G.clearTimeout = function (id) {
    if (id != null) { __vortx_native_clear_timeout(id); }
  };
  // setInterval is intentionally a bounded no-op-ish shim: providers rarely need it and an interval
  // that outlives a call must never keep the context alive. Emulate with a single delayed tick.
  G.setInterval = function (fn, ms) { return G.setTimeout(fn, ms); };
  G.clearInterval = function (id) { G.clearTimeout(id); };

  // ------------------------------------------------------------------ base64 (atob / btoa)
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  G.btoa = function (input) {
    var str = String(input);
    var out = '';
    for (var block = 0, charCode, i = 0, map = B64;
         str.charAt(i | 0) || (map = '=', i % 1);
         out += map.charAt(63 & (block >> (8 - (i % 1) * 8)))) {
      charCode = str.charCodeAt(i += 3 / 4);
      if (charCode > 0xff) { throw new Error("btoa: character out of range"); }
      block = (block << 8) | charCode;
    }
    return out;
  };
  G.atob = function (input) {
    var str = String(input).replace(/[=]+$/, '');
    var out = '';
    if (str.length % 4 === 1) { throw new Error("atob: invalid base64 length"); }
    for (var bc = 0, bs = 0, buffer, i = 0;
         (buffer = str.charAt(i++));
         ~buffer && (bs = bc % 4 ? bs * 64 + buffer : buffer, bc++ % 4)
           ? (out += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6)))) : 0) {
      buffer = B64.indexOf(buffer);
    }
    return out;
  };

  // ------------------------------------------------------------------ TextEncoder / TextDecoder (UTF-8)
  // Bare JSC has neither. Providers use them for byte-level crypto/hashing input. UTF-8 only, which is
  // the only encoding the community providers exercise.
  function TextEncoderShim() {}
  TextEncoderShim.prototype.encode = function (str) {
    str = String(str == null ? '' : str);
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) { bytes.push(c); }
      else if (c < 0x800) { bytes.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
      else if (c >= 0xd800 && c < 0xdc00) {
        var c2 = str.charCodeAt(++i);
        var cp = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
        bytes.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
          0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
      } else { bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
    }
    return new Uint8Array(bytes);
  };
  function TextDecoderShim() {}
  TextDecoderShim.prototype.decode = function (buf) {
    if (!buf) { return ''; }
    var bytes = (buf instanceof Uint8Array) ? buf : new Uint8Array(buf.buffer || buf);
    var out = '', i = 0;
    while (i < bytes.length) {
      var c = bytes[i++];
      if (c < 0x80) { out += String.fromCharCode(c); }
      else if (c < 0xe0) { out += String.fromCharCode(((c & 0x1f) << 6) | (bytes[i++] & 0x3f)); }
      else if (c < 0xf0) {
        out += String.fromCharCode(((c & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f));
      } else {
        var cp = ((c & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) | ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      }
    }
    return out;
  };
  if (typeof G.TextEncoder === 'undefined') { G.TextEncoder = TextEncoderShim; }
  if (typeof G.TextDecoder === 'undefined') { G.TextDecoder = TextDecoderShim; }

  // ------------------------------------------------------------------ URLSearchParams / URL
  // Pragmatic pure-JS implementations covering the surface community providers use for building and
  // reading query strings and picking apart a URL (protocol/host/hostname/pathname/search/href +
  // searchParams). Not a full WHATWG URL, by design; enough for the scraper contract.
  function URLSearchParamsShim(init) {
    this._pairs = [];
    if (init == null) { return; }
    if (init instanceof URLSearchParamsShim) {
      for (var k = 0; k < init._pairs.length; k++) { this._pairs.push([init._pairs[k][0], init._pairs[k][1]]); }
      return;
    }
    if (typeof init === 'string') {
      var s = init.charAt(0) === '?' ? init.slice(1) : init;
      if (!s) { return; }
      var seg = s.split('&');
      for (var i = 0; i < seg.length; i++) {
        if (!seg[i]) { continue; }
        var eq = seg[i].indexOf('=');
        var name = eq < 0 ? seg[i] : seg[i].slice(0, eq);
        var val = eq < 0 ? '' : seg[i].slice(eq + 1);
        this._pairs.push([decodeURIComponent(name.replace(/\+/g, ' ')), decodeURIComponent(val.replace(/\+/g, ' '))]);
      }
      return;
    }
    if (typeof init === 'object') {
      for (var key in init) { if (Object.prototype.hasOwnProperty.call(init, key)) { this._pairs.push([String(key), String(init[key])]); } }
    }
  }
  URLSearchParamsShim.prototype.append = function (n, v) { this._pairs.push([String(n), String(v)]); };
  URLSearchParamsShim.prototype.set = function (n, v) {
    var found = false;
    for (var i = this._pairs.length - 1; i >= 0; i--) {
      if (this._pairs[i][0] === n) { if (found) { this._pairs.splice(i, 1); } else { this._pairs[i][1] = String(v); found = true; } }
    }
    if (!found) { this._pairs.push([String(n), String(v)]); }
  };
  URLSearchParamsShim.prototype.get = function (n) {
    for (var i = 0; i < this._pairs.length; i++) { if (this._pairs[i][0] === n) { return this._pairs[i][1]; } }
    return null;
  };
  URLSearchParamsShim.prototype.getAll = function (n) {
    var out = []; for (var i = 0; i < this._pairs.length; i++) { if (this._pairs[i][0] === n) { out.push(this._pairs[i][1]); } } return out;
  };
  URLSearchParamsShim.prototype.has = function (n) { return this.get(n) !== null; };
  URLSearchParamsShim.prototype['delete'] = function (n) {
    for (var i = this._pairs.length - 1; i >= 0; i--) { if (this._pairs[i][0] === n) { this._pairs.splice(i, 1); } }
  };
  URLSearchParamsShim.prototype.forEach = function (cb, thisArg) {
    for (var i = 0; i < this._pairs.length; i++) { cb.call(thisArg, this._pairs[i][1], this._pairs[i][0], this); }
  };
  URLSearchParamsShim.prototype.entries = function () {
    var arr = this._pairs.map(function (p) { return [p[0], p[1]]; }); var idx = 0;
    return { next: function () { return idx < arr.length ? { value: arr[idx++], done: false } : { value: undefined, done: true }; } };
  };
  URLSearchParamsShim.prototype.keys = function () { return this._pairs.map(function (p) { return p[0]; }); };
  URLSearchParamsShim.prototype.values = function () { return this._pairs.map(function (p) { return p[1]; }); };
  URLSearchParamsShim.prototype.toString = function () {
    return this._pairs.map(function (p) {
      return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
    }).join('&');
  };
  if (typeof G.URLSearchParams === 'undefined') { G.URLSearchParams = URLSearchParamsShim; }

  function URLShim(url, base) {
    var input = String(url);
    // Resolve a relative URL against a base (only the common cases scrapers hit).
    if (base && !/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(input)) {
      var b = new URLShim(base);
      if (input.charAt(0) === '/') { input = b.protocol + '//' + b.host + input; }
      else if (input.charAt(0) === '?') { input = b.protocol + '//' + b.host + b.pathname + input; }
      else { input = b.protocol + '//' + b.host + b.pathname.replace(/[^/]*$/, '') + input; }
    }
    var m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(input);
    if (!m) { throw new TypeError('Invalid URL: ' + input); }
    this.protocol = m[1];
    var authority = m[2];
    var at = authority.indexOf('@');
    if (at >= 0) {
      var userinfo = authority.slice(0, at);
      authority = authority.slice(at + 1);
      var colon = userinfo.indexOf(':');
      this.username = colon < 0 ? userinfo : userinfo.slice(0, colon);
      this.password = colon < 0 ? '' : userinfo.slice(colon + 1);
    } else { this.username = ''; this.password = ''; }
    this.host = authority;
    var hp = authority.split(':');
    this.hostname = hp[0];
    this.port = hp.length > 1 ? hp[1] : '';
    this.pathname = m[3] || '/';
    this.search = m[4] || '';
    this.hash = m[5] || '';
    this.origin = this.protocol + '//' + this.host;
    this.searchParams = new URLSearchParamsShim(this.search);
  }
  URLShim.prototype.toString = function () {
    var search = this.searchParams && this.searchParams._pairs.length
      ? '?' + this.searchParams.toString()
      : this.search;
    return this.protocol + '//' + this.host + this.pathname + (search || '') + (this.hash || '');
  };
  Object.defineProperty(URLShim.prototype, 'href', {
    get: function () { return this.toString(); },
    configurable: true, enumerable: true,
  });
  if (typeof G.URL === 'undefined') { G.URL = URLShim; }

  // ------------------------------------------------------------------ fetch (native, user-IP egress)
  // The response object mirrors the community host's fetch shim: { ok, status, statusText, headers,
  // json(), text() }, and it does NOT throw on an HTTP error status (validateStatus-equivalent). The
  // actual request is made by the NATIVE URLSession call, so it egresses the user's own device IP; the
  // outbound URL policy and header defaults are enforced natively and cannot be bypassed from here.
  function makeResponse(raw) {
    var body = raw && typeof raw.body === 'string' ? raw.body : '';
    var status = raw && typeof raw.status === 'number' ? raw.status : 0;
    var headers = (raw && raw.headers) || {};
    var lower = {};
    for (var k in headers) { if (Object.prototype.hasOwnProperty.call(headers, k)) { lower[String(k).toLowerCase()] = headers[k]; } }
    return {
      ok: status >= 200 && status < 300,
      status: status,
      statusText: (raw && raw.statusText) || '',
      url: (raw && raw.url) || '',
      headers: {
        get: function (name) { var v = lower[String(name).toLowerCase()]; return v == null ? null : v; },
        has: function (name) { return Object.prototype.hasOwnProperty.call(lower, String(name).toLowerCase()); },
        forEach: function (cb) { for (var kk in headers) { if (Object.prototype.hasOwnProperty.call(headers, kk)) { cb(headers[kk], kk); } } },
        raw: function () { return headers; },
      },
      text: function () { return Promise.resolve(body); },
      json: function () { return Promise.resolve().then(function () { return JSON.parse(body); }); },
      arrayBuffer: function () {
        return Promise.resolve().then(function () {
          var enc = new G.TextEncoder(); return enc.encode(body).buffer;
        });
      },
    };
  }
  G.fetch = function (url, options) {
    return new Promise(function (resolve, reject) {
      var optsJSON;
      try { optsJSON = JSON.stringify(options || {}); } catch (e) { optsJSON = '{}'; }
      __vortx_native_fetch(String(url), optsJSON, function (raw) {
        try { resolve(makeResponse(raw)); } catch (e) { reject(e); }
      }, function (errMessage) {
        reject(new Error(typeof errMessage === 'string' ? errMessage : 'fetch failed'));
      });
    });
  };

  // ------------------------------------------------------------------ axios (adapter over fetch)
  // A minimal axios-compatible instance: providers that `require('axios')` or use the injected `axios`
  // get get/post/request plus `axios.create`. Response is { data, status, statusText, headers, config }
  // and, like the community host, does NOT throw on non-2xx (validateStatus: () => true).
  function axiosRequest(config) {
    config = config || {};
    var method = (config.method || 'get').toUpperCase();
    var url = config.url;
    if (config.baseURL && !/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(String(url))) { url = config.baseURL + url; }
    if (config.params) {
      var sp = new URLSearchParamsShim(config.params).toString();
      if (sp) { url += (String(url).indexOf('?') < 0 ? '?' : '&') + sp; }
    }
    var opts = { method: method, headers: config.headers || {} };
    if (config.data != null) {
      opts.body = (typeof config.data === 'string') ? config.data : JSON.stringify(config.data);
      if (typeof config.data !== 'string' && !(/content-type/i.test(Object.keys(opts.headers).join(',')))) {
        opts.headers['Content-Type'] = 'application/json';
      }
    }
    return G.fetch(url, opts).then(function (res) {
      var isJSON = false;
      var ct = res.headers.get('content-type') || '';
      if (config.responseType === 'json' || /json/i.test(ct)) { isJSON = true; }
      return res.text().then(function (body) {
        var data = body;
        if (isJSON) { try { data = JSON.parse(body); } catch (e) { data = body; } }
        var hdrs = res.headers.raw();
        return { data: data, status: res.status, statusText: res.statusText, headers: hdrs, config: config, request: {} };
      });
    });
  }
  function makeAxios(defaults) {
    defaults = defaults || {};
    var instance = function (config) {
      if (typeof config === 'string') { config = { url: config }; }
      return axiosRequest(mergeConfig(defaults, config));
    };
    instance.request = function (config) { return axiosRequest(mergeConfig(defaults, config)); };
    ['get', 'delete', 'head', 'options'].forEach(function (m) {
      instance[m] = function (url, config) { return axiosRequest(mergeConfig(defaults, Object.assign({}, config, { method: m, url: url }))); };
    });
    ['post', 'put', 'patch'].forEach(function (m) {
      instance[m] = function (url, data, config) { return axiosRequest(mergeConfig(defaults, Object.assign({}, config, { method: m, url: url, data: data }))); };
    });
    instance.create = function (cfg) { return makeAxios(mergeConfig(defaults, cfg || {})); };
    instance.defaults = defaults;
    instance.interceptors = { request: { use: function () {} }, response: { use: function () {} } };
    return instance;
  }
  function mergeConfig(a, b) {
    var out = {};
    for (var k in a) { if (Object.prototype.hasOwnProperty.call(a, k)) { out[k] = a[k]; } }
    for (var j in b) { if (Object.prototype.hasOwnProperty.call(b, j)) { out[j] = b[j]; } }
    out.headers = Object.assign({}, a.headers || {}, b.headers || {});
    return out;
  }
  var axios = makeAxios({});

  // ------------------------------------------------------------------ require (hard gate)
  // Exactly the community host's gate: only a cheerio-compatible parser and a crypto-js-compatible lib
  // resolve; every other module throws with the same shape, so provider failures are legible and no
  // filesystem / native module is ever reachable.
  function requireShim(name) {
    switch (name) {
      case 'cheerio':
      case 'cheerio-without-node-native':
      case 'react-native-cheerio':
        if (!G.__vortx_cheerio) { throw new Error("Module 'cheerio' is not available in sandbox"); }
        return G.__vortx_cheerio;
      case 'crypto-js':
        if (!G.__vortx_cryptojs) { throw new Error("Module 'crypto-js' is not available in sandbox"); }
        return G.__vortx_cryptojs;
      case 'axios':
        return axios;
      case 'url':
        return { URL: G.URL, URLSearchParams: G.URLSearchParams };
      default:
        throw new Error("Module '" + name + "' is not available in sandbox");
    }
  }

  // ------------------------------------------------------------------ provider execution
  // Mirrors the community harness: build a sandbox, splice the provider code into a `new Function`
  // scope with the sandbox destructured into locals, and locate `getStreams` the same three ways.
  // Runs whatever the provider returns (sync or Promise) and pipes the settled result back to the
  // native completion primitives, JSON-serialized. This is the strict-superset entry point.
  G.__vortx_run = function (code, paramsJSON, settingsJSON, scraperId, tmdbKey) {
    try {
      var params = JSON.parse(paramsJSON || '{}');
      var settings = {};
      try { settings = JSON.parse(settingsJSON || '{}'); } catch (e) { settings = {}; }

      // Per-provider settings + id, exactly where the community contract puts them.
      G.SCRAPER_SETTINGS = settings;
      G.SCRAPER_ID = scraperId || '';

      var moduleObj = { exports: {} };
      var sandbox = {
        console: G.console,
        setTimeout: G.setTimeout, clearTimeout: G.clearTimeout,
        setInterval: G.setInterval, clearInterval: G.clearInterval,
        Promise: Promise, JSON: JSON, Date: Date, Math: Math,
        parseInt: parseInt, parseFloat: parseFloat, isNaN: isNaN, isFinite: isFinite,
        encodeURIComponent: encodeURIComponent, decodeURIComponent: decodeURIComponent,
        encodeURI: encodeURI, decodeURI: decodeURI,
        require: requireShim, axios: axios, fetch: G.fetch,
        URL: G.URL, URLSearchParams: G.URLSearchParams,
        atob: G.atob, btoa: G.btoa,
        TextEncoder: G.TextEncoder, TextDecoder: G.TextDecoder,
        module: moduleObj, exports: moduleObj.exports, global: G,
        URL_VALIDATION_ENABLED: (typeof G.URL_VALIDATION_ENABLED === 'boolean') ? G.URL_VALIDATION_ENABLED : true,
      };

      var runner = new Function('sandbox', 'params', 'PRIMARY_KEY', 'TMDB_API_KEY', [
        "const { console, setTimeout, clearTimeout, setInterval, clearInterval, Promise, JSON, Date, Math,",
        "        parseInt, parseFloat, isNaN, isFinite, encodeURIComponent, decodeURIComponent, encodeURI, decodeURI,",
        "        require, axios, fetch, URL, URLSearchParams, atob, btoa, TextEncoder, TextDecoder,",
        "        module, exports, global, URL_VALIDATION_ENABLED } = sandbox;",
        "global.PRIMARY_KEY = PRIMARY_KEY; global.TMDB_API_KEY = TMDB_API_KEY;",
        "if (typeof window !== 'undefined') { window.PRIMARY_KEY = PRIMARY_KEY; window.TMDB_API_KEY = TMDB_API_KEY; }",
        code,
        "if (typeof getStreams === 'function') {",
        "  return getStreams(params.tmdbId, params.mediaType, params.season, params.episode);",
        "} else if (typeof module !== 'undefined' && module.exports && typeof module.exports.getStreams === 'function') {",
        "  return module.exports.getStreams(params.tmdbId, params.mediaType, params.season, params.episode);",
        "} else if (typeof global !== 'undefined' && global.getStreams && typeof global.getStreams === 'function') {",
        "  return global.getStreams(params.tmdbId, params.mediaType, params.season, params.episode);",
        "} else { throw new Error('No getStreams function found in scraper'); }",
      ].join('\n'));

      var result = runner(sandbox, params, (typeof G.PRIMARY_KEY === 'string' ? G.PRIMARY_KEY : ''),
        (typeof tmdbKey === 'string' && tmdbKey) ? tmdbKey : (typeof G.TMDB_API_KEY === 'string' ? G.TMDB_API_KEY : ''));

      Promise.resolve(result).then(function (streams) {
        var arr = Array.isArray(streams) ? streams : [];
        var json;
        try { json = JSON.stringify(arr); } catch (e) { json = '[]'; }
        __vortx_native_complete(json);
      }).catch(function (err) {
        __vortx_native_fail(err && err.message ? String(err.message) : String(err));
      });
    } catch (err) {
      __vortx_native_fail(err && err.message ? String(err.message) : String(err));
    }
  };

  // A `window` alias pointing at the same global (the community harness writes window.* ; providers may
  // read it). Kept last so everything above is already installed on it.
  if (typeof G.window === 'undefined') { G.window = G; }
})();
