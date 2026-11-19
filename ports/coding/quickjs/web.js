// zdos:web, a web framework in the manner of Express for QuickJS
// on ZDOS, over zdos:net in qjs's event loop (ZDOSWEB.md)
import * as std from "qjs:std";
import * as os from "qjs:os";
import * as net from "zdos:net";

export const version = "1.0";

// STATUS AND TYPES

export const STATUS_CODES = {
  100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted",
  203: "Non-Authoritative Information", 204: "No Content", 205: "Reset Content", 206: "Partial Content",
  207: "Multi-Status", 300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other",
  304: "Not Modified", 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request",
  401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
  406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict", 410: "Gone", 411: "Length Required",
  412: "Precondition Failed", 413: "Payload Too Large", 414: "URI Too Long", 415: "Unsupported Media Type",
  416: "Range Not Satisfiable", 417: "Expectation Failed", 418: "I'm a Teapot", 422: "Unprocessable Entity",
  423: "Locked", 425: "Too Early", 426: "Upgrade Required", 428: "Precondition Required",
  429: "Too Many Requests", 431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
  500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
  504: "Gateway Timeout", 505: "HTTP Version Not Supported",
};

const TYPES = {
  html: "text/html", htm: "text/html", txt: "text/plain", text: "text/plain", css: "text/css",
  js: "text/javascript", mjs: "text/javascript", json: "application/json", map: "application/json",
  xml: "application/xml", csv: "text/csv", md: "text/markdown", svg: "image/svg+xml", png: "image/png",
  jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp", ico: "image/x-icon",
  bmp: "image/bmp", avif: "image/avif", wasm: "application/wasm", pdf: "application/pdf",
  zip: "application/zip", gz: "application/gzip", tar: "application/x-tar", "7z": "application/x-7z-compressed",
  mp3: "audio/mpeg", ogg: "audio/ogg", wav: "audio/wav", mp4: "video/mp4", webm: "video/webm",
  woff: "font/woff", woff2: "font/woff2", ttf: "font/ttf", otf: "font/otf", bin: "application/octet-stream",
  form: "application/x-www-form-urlencoded", urlencoded: "application/x-www-form-urlencoded",
  multipart: "multipart/form-data",
};

// "json", ".json", "file.json" -> its type; "text/x" as it is
function lookupType(t) {
  if (/^[\w.+-]+\/[\w.+*-]+(\s*;.*)?$/.test(t)) return t;
  return typeOfFile(t);
}

function typeOfFile(path) {
  const ext = String(path).replace(/^.*[\\/]/, "").replace(/^.*\./, "").toLowerCase();
  return TYPES[ext] || "application/octet-stream";
}

// With charset=utf-8 for text, as Express does
function contentType(t) {
  t = lookupType(t);
  if (/charset=/i.test(t)) return t;
  return /^text\/|^application\/(json|javascript|xml)|\+xml$|\+json$/i.test(t) ? t + "; charset=utf-8" : t;
}

// A media type against a pattern: "json", "text/*", "application/json"
function typeMatches(type, pattern) {
  if (!type) return false;
  type = type.split(";")[0].trim().toLowerCase();
  pattern = pattern.toLowerCase();
  if (!pattern.includes("/")) {
    if (pattern === "json" && /[/+]json$/.test(type)) return true;
    pattern = lookupType(pattern);
  }
  if (pattern === "*/*") return true;
  const [a, b] = pattern.split("/"), [c, d] = type.split("/");
  return (a === "*" || a === c) && (b === "*" || b === d || (b.startsWith("*+") && d.endsWith(b.slice(1))));
}

// BYTES

const encode = (s) => new Uint8Array(net.encode(s));
const decode = (u8, from = 0, to = u8.length) => net.decode(u8, from, to - from);

function toBytes(data) {
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  return encode(String(data));
}

function isBinary(x) {
  return x instanceof ArrayBuffer || ArrayBuffer.isView(x);
}

// A buffer that grows: bytes come in at the end, go out at the start
class Buffer {
  constructor() { this.a = new Uint8Array(8192); this.start = 0; this.end = 0; }
  get length() { return this.end - this.start; }
  push(ab) {
    const src = new Uint8Array(ab), n = src.length;
    if (this.end + n > this.a.length) {
      const live = this.length;
      if (live + n <= this.a.length / 2) {
        this.a.copyWithin(0, this.start, this.end);
      } else {
        let size = this.a.length;
        while (size < (live + n) * 2) size *= 2;
        const b = new Uint8Array(size);
        b.set(this.a.subarray(this.start, this.end));
        this.a = b;
      }
      this.start = 0;
      this.end = live;
    }
    this.a.set(src, this.end);
    this.end += n;
  }
  // index of a byte sequence from the start, -1 if not there
  find(seq, from = 0) {
    const a = this.a, last = this.end - seq.length;
    outer: for (let i = this.start + from; i <= last; i++) {
      for (let k = 0; k < seq.length; k++) if (a[i + k] !== seq[k]) continue outer;
      return i - this.start;
    }
    return -1;
  }
  peek(from, to) { return this.a.subarray(this.start + from, this.start + to); }
  take(n) {
    const out = this.a.slice(this.start, this.start + n);
    this.start += n;
    if (this.start === this.end) this.start = this.end = 0;
    return out;
  }
  skip(n) { this.start += n; if (this.start === this.end) this.start = this.end = 0; }
}

const CRLF = [13, 10], CRLFCRLF = [13, 10, 13, 10];

function concat(parts, total) {
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  return out;
}

// FNV-1a of the bytes: Express's weak ETag in spirit
function etagOf(u8) {
  let h = 0x811c9dc5;
  for (let i = 0; i < u8.length; i++) h = Math.imul(h ^ u8[i], 0x01000193);
  return `W/"${u8.length.toString(16)}-${(h >>> 0).toString(16)}"`;
}

// QUERY STRINGS AND COOKIES

function decodeComponent(s) {
  try { return decodeURIComponent(s.replace(/\+/g, " ")); } catch { return s; }
}

// a=1&a=2&b[]=3&c: { a: ["1", "2"], b: ["3"], c: "" }
export function parseQuery(s) {
  const q = Object.create(null);
  if (!s) return q;
  for (const part of s.split("&")) {
    if (!part) continue;
    const eq = part.indexOf("=");
    let k = decodeComponent(eq < 0 ? part : part.slice(0, eq));
    const v = eq < 0 ? "" : decodeComponent(part.slice(eq + 1));
    let list = false;
    if (k.endsWith("[]")) { k = k.slice(0, -2); list = true; }
    if (k in q) q[k] = [].concat(q[k], v);
    else q[k] = list ? [v] : v;
  }
  return q;
}

function parseCookies(header) {
  const out = Object.create(null);
  if (!header) return out;
  for (const part of header.split(";")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const k = part.slice(0, eq).trim();
    let v = part.slice(eq + 1).trim();
    if (v.startsWith('"') && v.endsWith('"')) v = v.slice(1, -1);
    if (!(k in out)) {
      v = decodeComponent(v);
      if (v.startsWith("j:")) { try { v = JSON.parse(v.slice(2)); } catch {} }
      out[k] = v;
    }
  }
  return out;
}

function serializeCookie(name, value, o = {}) {
  let s = `${name}=${(o.encode || encodeURIComponent)(value)}`;
  if (o.maxAge != null) {
    const ms = Number(o.maxAge);
    s += `; Max-Age=${Math.floor(ms / 1000)}`;
    if (!o.expires) s += `; Expires=${new Date(Date.now() + ms).toUTCString()}`;
  }
  if (o.expires) s += `; Expires=${new Date(o.expires).toUTCString()}`;
  if (o.domain) s += `; Domain=${o.domain}`;
  s += `; Path=${o.path || "/"}`;
  if (o.secure) s += "; Secure";
  if (o.httpOnly) s += "; HttpOnly";
  if (o.partitioned) s += "; Partitioned";
  if (o.sameSite) {
    const v = o.sameSite === true ? "Strict" : String(o.sameSite);
    s += `; SameSite=${v[0].toUpperCase()}${v.slice(1).toLowerCase()}`;
  }
  return s;
}

// PATHS

// A route path to a RegExp and its parameter names: "/users/:id",
// "/files/*", "/a/:b?", RegExps, arrays of these. end: the whole
// path (routes), else a prefix up to a '/' (use)
function compilePath(path, { end = true, caseSensitive = false, strict = false } = {}) {
  const keys = [];
  const one = (p) => {
    if (p instanceof RegExp) {
      const groups = new RegExp(p.source + "|").exec("").length - 1;
      for (let i = 0; i < groups; i++) keys.push(keys.length);
      return p.source.replace(/^\^/, "").replace(/\$$/, "");
    }
    let re = "";
    let i = 0;
    while (i < p.length) {
      const c = p[i];
      if (c === ":") {
        const m = /^:([A-Za-z_$][\w$]*)(\([^)]*\))?(\?)?/.exec(p.slice(i));
        if (!m) { re += "\\:"; i++; continue; }
        keys.push(m[1]);
        const capture = m[2] ? m[2] : "([^/]+?)";
        if (m[3] && re.endsWith("\\/")) re = re.slice(0, -2) + `(?:\\/${capture})?`;
        else re += m[3] ? `${capture}?` : capture;
        i += m[0].length;
      } else if (c === "*") {
        const m = /^\*([A-Za-z_$][\w$]*)?/.exec(p.slice(i));
        keys.push(m[1] || keys.filter((k) => typeof k === "number").length);
        re += "(.*)";
        i += m[0].length;
      } else {
        re += c.replace(/[.+?^${}()|[\]\\/]/g, "\\$&");
        i++;
      }
    }
    return re;
  };
  const body = Array.isArray(path) ? path.map(one).join("|") : one(path);
  let src = "^(?:" + body + ")";
  if (end) src += strict ? "$" : "\\/?$";
  else src += body.endsWith("\\/") ? "" : "(?=\\/|$)";
  return { re: new RegExp(src, caseSensitive ? "" : "i"), keys };
}

function decodeParam(v) {
  if (v === undefined) return undefined;
  try { return decodeURIComponent(v); } catch { return v; }
}

// ROUTING

export const METHODS = ["get", "post", "put", "patch", "delete", "head", "options", "trace", "copy", "lock",
  "mkcol", "move", "purge", "propfind", "proppatch", "report", "search", "unlock", "link", "unlink"];

// A handler called so that a throw or a rejected promise goes to next
function invoke(fn, args, next) {
  try {
    const r = fn(...args);
    if (r && typeof r.then === "function") {
      r.then(undefined, (e) => next(e === undefined || e === null ? new Error("Rejected") : e));
    }
  } catch (e) {
    next(e);
  }
}

class Layer {
  constructor(path, opts, fn) {
    this.path = path;
    this.handle = fn;
    this.route = null;
    this.slash = !opts.end && (path === "/" || path === "" || path === "*");
    const c = compilePath(path === "" ? "/" : path, opts);
    this.re = c.re;
    this.keys = c.keys;
  }
  match(path) {
    if (this.slash) return { params: {}, matched: "" };
    const m = this.re.exec(path);
    if (!m) return null;
    const params = {};
    this.keys.forEach((k, i) => { if (m[i + 1] !== undefined) params[k] = decodeParam(m[i + 1]); });
    return { params, matched: m[0] };
  }
}

export class Route {
  constructor(path) {
    this.path = path;
    this.stack = [];
    this.methods = Object.create(null);
  }
  handlesMethod(method) {
    if (this.methods._all) return true;
    method = method.toLowerCase();
    if (method === "head" && !this.methods.head) method = "get";
    return Boolean(this.methods[method]);
  }
  allowed() {
    const m = Object.keys(this.methods).filter((k) => k !== "_all").map((k) => k.toUpperCase());
    if (m.includes("GET") && !m.includes("HEAD")) m.push("HEAD");
    return m;
  }
  dispatch(req, res, done) {
    let idx = 0;
    let method = req.method.toLowerCase();
    if (method === "head" && !this.methods.head) method = "get";
    req.route = this;
    const next = (err) => {
      if (err === "route") return done();
      if (err === "router") return done(err);
      while (idx < this.stack.length) {
        const h = this.stack[idx++];
        if (h.method && h.method !== method) continue;
        req.next = next;
        if (err) {
          if (h.fn.length === 4) return invoke(h.fn, [err, req, res, next], next);
        } else if (h.fn.length < 4) {
          return invoke(h.fn, [req, res, next], next);
        }
      }
      done(err);
    };
    next();
  }
  all(...fns) {
    for (const fn of fns.flat(Infinity)) this.stack.push({ method: null, fn });
    this.methods._all = true;
    return this;
  }
}
for (const m of METHODS) {
  Route.prototype[m] = function (...fns) {
    for (const fn of fns.flat(Infinity)) {
      if (typeof fn !== "function") throw new TypeError(`Route.${m}() needs functions`);
      this.stack.push({ method: m, fn });
    }
    this.methods[m] = true;
    return this;
  };
}

export class Router {
  constructor(opts = {}) {
    this.stack = [];
    this.opts = { caseSensitive: Boolean(opts.caseSensitive), strict: Boolean(opts.strict) };
    this.mergeParams = Boolean(opts.mergeParams);
    // a Router is also a middleware function
    const router = (req, res, next) => router.handle(req, res, next);
    Object.setPrototypeOf(router, new.target.prototype);
    Object.assign(router, this);
    return router;
  }
  use(path, ...fns) {
    if (typeof path !== "string" && !(path instanceof RegExp) && !Array.isArray(path)) {
      fns.unshift(path);
      path = "/";
    } else if (Array.isArray(path) && path.length && typeof path[0] === "function") {
      fns.unshift(path);
      path = "/";
    }
    for (const fn of fns.flat(Infinity)) {
      if (typeof fn !== "function") throw new TypeError("use() needs middleware functions");
      this.stack.push(new Layer(path, { ...this.opts, end: false }, fn));
    }
    return this;
  }
  route(path) {
    const route = new Route(path);
    const layer = new Layer(path, { ...this.opts, end: true }, (req, res, next) => route.dispatch(req, res, next));
    layer.route = route;
    this.stack.push(layer);
    return route;
  }
  all(path, ...fns) { this.route(path).all(...fns); return this; }
  param(name, fn) {
    // run fn(req, res, next, value) once per request before routes with :name
    (this.params || (this.params = {}))[name] = fn;
    return this;
  }
  handle(req, res, out) {
    let idx = 0;
    const stack = this.stack;
    const parentUrl = req.url, parentBase = req.baseUrl || "", parentParams = req.params || {};
    let removed = "";
    const restore = () => { req.url = parentUrl; req.baseUrl = parentBase; req.params = parentParams; };
    const allow = new Set();
    const next = (err) => {
      if (removed) { req.url = parentUrl; req.baseUrl = parentBase; removed = ""; }
      if (err === "router") { restore(); return out(); }
      const path = pathOf(req.url);
      while (idx < stack.length) {
        const layer = stack[idx++];
        const m = layer.match(path);
        if (!m) continue;
        if (layer.route) {
          if (err) continue;
          if (!layer.route.handlesMethod(req.method)) {
            if (req.method === "OPTIONS") layer.route.allowed().forEach((a) => allow.add(a));
            continue;
          }
          req.params = this.mergeParams ? { ...parentParams, ...m.params } : m.params;
          return this.runParams(req, res, layer, (e) => {
            if (e) return next(e);
            layer.handle(req, res, next);
          });
        }
        // middleware: the matched start taken off req.url
        req.params = this.mergeParams ? { ...parentParams, ...m.params } : { ...parentParams, ...m.params };
        if (m.matched && m.matched !== "/") {
          removed = m.matched.replace(/\/$/, "");
          req.baseUrl = parentBase + removed;
          req.url = parentUrl.slice(removed.length) || "/";
          if (!req.url.startsWith("/")) req.url = "/" + req.url;
        }
        const fn = layer.handle;
        req.next = next;
        if (err) {
          if (fn.length === 4) return invoke(fn, [err, req, res, next], next);
        } else if (fn.length < 4) {
          return invoke(fn, [req, res, next], next);
        }
        if (removed) { req.url = parentUrl; req.baseUrl = parentBase; removed = ""; }
      }
      restore();
      if (!err && req.method === "OPTIONS" && allow.size && !res.headersSent) {
        const list = [...allow].join(",");
        return res.set("Allow", list).type("text/plain").send(list);
      }
      out(err);
    };
    next();
  }
  runParams(req, res, layer, done) {
    const params = this.params;
    if (!params) return done();
    const seen = req._paramsCalled || (req._paramsCalled = {});
    const names = layer.keys.filter((k) => params[k] && req.params[k] !== undefined && seen[k] !== req.params[k]);
    let i = 0;
    const step = (err) => {
      if (err || i >= names.length) return done(err);
      const k = names[i++];
      seen[k] = req.params[k];
      invoke(params[k], [req, res, step, req.params[k], k], step);
    };
    step();
  }
}
for (const m of METHODS) {
  Router.prototype[m] = function (path, ...fns) {
    this.route(path)[m](...fns);
    return this;
  };
}

function pathOf(url) {
  const q = url.indexOf("?");
  return q < 0 ? url : url.slice(0, q);
}

// REQUEST

export class Request {
  constructor(conn, head, body) {
    this.connection = conn;
    this.method = head.method;
    this.url = head.target;
    this.originalUrl = head.target;
    this.httpVersion = head.version;
    this.headers = head.headers;
    this.rawHeaders = head.rawHeaders;
    this.rawBody = body;
    this.body = undefined;
    this.baseUrl = "";
    this.params = {};
    this.ip = conn.ip;
    this.socket = { remoteAddress: conn.ip, remotePort: conn.port, encrypted: Boolean(conn.tls) };
    this.secure = Boolean(conn.tls);
    this.protocol = this.secure ? "https" : "http";
    this.app = null;
    this.res = null;
  }
  get path() { return pathOf(this.url); }
  get query() {
    if (!this._query) {
      const q = this.url.indexOf("?");
      this._query = parseQuery(q < 0 ? "" : this.url.slice(q + 1));
    }
    return this._query;
  }
  set query(v) { this._query = v; }
  get hostname() {
    const h = this.headers.host || "";
    return h.startsWith("[") ? h.slice(0, h.indexOf("]") + 1) : h.split(":")[0];
  }
  get host() { return this.headers.host || ""; }
  get cookies() { return this._cookies || (this._cookies = parseCookies(this.headers.cookie)); }
  get xhr() { return (this.headers["x-requested-with"] || "").toLowerCase() === "xmlhttprequest"; }
  get(name) {
    name = name.toLowerCase();
    if (name === "referer" || name === "referrer") return this.headers.referer || this.headers.referrer;
    return this.headers[name];
  }
  header(name) { return this.get(name); }
  is(...types) {
    const ct = this.headers["content-type"];
    if (!ct || !this.rawBody || !this.rawBody.length) return types.length ? false : null;
    for (const t of types.flat()) if (typeMatches(ct, t)) return t;
    return false;
  }
  // the first of the types the Accept header takes, else false
  accepts(...types) {
    types = types.flat();
    const accept = (this.headers.accept || "*/*").split(",").map((p) => {
      const [t, ...ps] = p.trim().split(";");
      const q = ps.map((x) => x.trim()).find((x) => x.startsWith("q="));
      return { t: t.trim().toLowerCase(), q: q ? parseFloat(q.slice(2)) : 1 };
    }).filter((a) => a.q > 0).sort((a, b) => b.q - a.q);
    if (!types.length) return accept.map((a) => a.t);
    for (const a of accept) {
      for (const t of types) if (typeMatches(lookupType(t), a.t)) return t;
    }
    return false;
  }
}

// RESPONSE

export class Response {
  constructor(conn, req) {
    this.connection = conn;
    this.req = req;
    this.statusCode = 200;
    this.statusMessage = undefined;
    this.headers = new Map(); // lower case name -> [name, value]
    this.headersSent = false;
    this.finished = false;
    this.locals = Object.create(null);
    this.listeners = {};
    this.chunked = false;
    this.app = null;
  }
  on(event, fn) { (this.listeners[event] || (this.listeners[event] = [])).push(fn); return this; }
  once(event, fn) { return this.on(event, fn); }
  emit(event) {
    for (const fn of this.listeners[event] || []) {
      try { fn(); } catch (e) { logError(e); }
    }
  }
  status(code) { this.statusCode = Number(code); return this; }
  set(field, value) {
    if (typeof field === "object") {
      for (const [k, v] of Object.entries(field)) this.set(k, v);
      return this;
    }
    if (value === undefined) return this;
    let v = Array.isArray(value) ? value.map(String) : String(value);
    if (field.toLowerCase() === "content-type" && !Array.isArray(v)) v = contentType(v);
    this.headers.set(field.toLowerCase(), [field, v]);
    return this;
  }
  header(field, value) { return this.set(field, value); }
  setHeader(field, value) { this.set(field, value); return this; }
  get(field) { const h = this.headers.get(field.toLowerCase()); return h ? h[1] : undefined; }
  getHeader(field) { return this.get(field); }
  getHeaders() { const o = {}; for (const [k, [, v]] of this.headers) o[k] = v; return o; }
  hasHeader(field) { return this.headers.has(field.toLowerCase()); }
  removeHeader(field) { this.headers.delete(field.toLowerCase()); return this; }
  append(field, value) {
    const prev = this.get(field);
    if (prev === undefined) return this.set(field, value);
    return this.set(field, [].concat(prev, value));
  }
  type(t) { return this.set("Content-Type", t); }
  contentType(t) { return this.type(t); }
  vary(field) {
    const prev = (this.get("Vary") || "").split(",").map((s) => s.trim()).filter(Boolean);
    if (!prev.some((p) => p.toLowerCase() === field.toLowerCase() || p === "*")) prev.push(field);
    return this.set("Vary", prev.join(", "));
  }
  location(url) { return this.set("Location", url === "back" ? this.req.get("referer") || "/" : url); }
  redirect(a, b) {
    const [code, url] = b === undefined ? [302, a] : [a, b];
    this.location(url).status(code);
    const text = `${STATUS_CODES[code] || "Redirecting"}. Redirecting to ${url}`;
    return this.type("text/plain").send(text);
  }
  attachment(filename) {
    if (filename) this.type(typeOfFile(filename));
    return this.set("Content-Disposition", filename ? `attachment; filename="${String(filename).replace(/^.*[\\/]/, "").replace(/"/g, "")}"` : "attachment");
  }
  cookie(name, value, opts = {}) {
    const v = typeof value === "object" ? "j:" + JSON.stringify(value) : String(value);
    return this.append("Set-Cookie", serializeCookie(name, v, opts));
  }
  clearCookie(name, opts = {}) {
    return this.cookie(name, "", { ...opts, maxAge: undefined, expires: new Date(1) });
  }
  sendStatus(code) {
    return this.status(code).type("text/plain").send(STATUS_CODES[code] || String(code));
  }
  json(obj) {
    const app = this.app;
    const body = JSON.stringify(obj, app ? app.get("json replacer") : undefined, app ? app.get("json spaces") : undefined);
    if (!this.hasHeader("Content-Type")) this.type("application/json");
    return this.send(body === undefined ? "" : body);
  }
  send(body) {
    if (typeof body === "number" && arguments.length === 1) {
      return this.sendStatus(body);
    }
    if (body === null || (typeof body === "object" && !isBinary(body)) || typeof body === "boolean") {
      return this.json(body);
    }
    let bytes;
    if (typeof body === "string") {
      if (!this.hasHeader("Content-Type")) this.type("text/html");
      bytes = encode(body);
    } else if (body === undefined) {
      bytes = new Uint8Array(0);
    } else {
      if (!this.hasHeader("Content-Type")) this.type("application/octet-stream");
      bytes = toBytes(body);
    }
    // a weak ETag; a GET or HEAD whose If-None-Match has it: 304
    const app = this.app;
    const method = this.req.method;
    if ((!app || app.enabled("etag")) && !this.hasHeader("ETag") && bytes.length && (method === "GET" || method === "HEAD")) {
      this.set("ETag", etagOf(bytes));
    }
    if (this.fresh()) this.statusCode = 304;
    return this.end(bytes);
  }
  // the client's copy is current (If-None-Match, If-Modified-Since)
  fresh() {
    const s = this.statusCode, method = this.req.method;
    if ((method !== "GET" && method !== "HEAD") || !((s >= 200 && s < 300) || s === 304)) return false;
    const inm = this.req.headers["if-none-match"], ims = this.req.headers["if-modified-since"];
    if (!inm && !ims) return false;
    if (this.req.headers["cache-control"] && /no-cache/.test(this.req.headers["cache-control"])) return false;
    if (inm) {
      const etag = this.get("ETag");
      if (inm.trim() !== "*") {
        if (!etag) return false;
        const strip = (t) => t.trim().replace(/^W\//, "");
        if (!inm.split(",").some((t) => strip(t) === strip(etag))) return false;
      }
      return true;
    }
    const lm = this.get("Last-Modified");
    return Boolean(lm && Date.parse(lm) <= Date.parse(ims));
  }
  writeHead(code, message, headers) {
    if (typeof message === "object") { headers = message; message = undefined; }
    this.statusCode = code;
    if (message) this.statusMessage = message;
    if (headers) this.set(headers);
    return this;
  }
  // the status line and headers into the connection's queue
  sendHead(length) {
    if (this.headersSent) return;
    this.emit("header");
    const req = this.req, code = this.statusCode;
    const noBody = code === 204 || code === 304 || (code >= 100 && code < 200);
    if (noBody) {
      for (const h of ["content-type", "content-length", "transfer-encoding"]) this.headers.delete(h);
    } else if (length === null) {
      if (req.httpVersion === "1.1") { this.chunked = true; this.set("Transfer-Encoding", "chunked"); }
      else this.connection.keepAlive = false;
      this.headers.delete("content-length");
    } else if (!this.hasHeader("Content-Length")) {
      this.set("Content-Length", length);
    }
    if (!this.hasHeader("Date")) this.set("Date", new Date().toUTCString());
    if (this.app && this.app.enabled("x-powered-by") && !this.hasHeader("X-Powered-By")) this.set("X-Powered-By", "ZDOS");
    const keep = this.connection.keepAlive && !/close/i.test(this.get("Connection") || "");
    this.connection.keepAlive = keep;
    this.set("Connection", keep ? "keep-alive" : "close");
    let head = `HTTP/1.1 ${code} ${this.statusMessage || STATUS_CODES[code] || "Unknown"}\r\n`;
    for (const [, [name, value]] of this.headers) {
      for (const v of [].concat(value)) head += `${name}: ${String(v).replace(/[\r\n]/g, "")}\r\n`;
    }
    this.headersSent = true;
    this.noBody = noBody || req.method === "HEAD";
    this.connection.send(encode(head + "\r\n"));
  }
  // a piece of a body whose length isn't known yet (chunked)
  write(data, encoding, cb) {
    if (this.finished) return false;
    if (!this.headersSent) {
      if (!this.hasHeader("Content-Type")) this.type("text/plain");
      this.sendHead(this.hasHeader("Content-Length") ? Number(this.get("Content-Length")) : null);
    }
    const bytes = toBytes(data);
    if (bytes.length && !this.noBody) {
      if (this.chunked) this.connection.send(encode(bytes.length.toString(16) + "\r\n"));
      this.connection.send(bytes);
      if (this.chunked) this.connection.send(encode("\r\n"));
    }
    if (typeof cb === "function") this.connection.whenDrained(cb);
    else if (typeof encoding === "function") this.connection.whenDrained(encoding);
    return this.connection.queued < 1 << 20;
  }
  end(data) {
    if (this.finished) return this;
    if (!this.headersSent) {
      const bytes = data === undefined ? new Uint8Array(0) : toBytes(data);
      this.sendHead(bytes.length);
      if (!this.noBody && bytes.length) this.connection.send(bytes);
    } else {
      if (data !== undefined) this.write(data);
      if (this.chunked && !this.noBody) this.connection.send(encode("0\r\n\r\n"));
    }
    this.finished = true;
    this.writableEnded = true;
    this.connection.responseDone(this);
    return this;
  }
  sendFile(path, opts = {}, cb) {
    if (typeof opts === "function") { cb = opts; opts = {}; }
    const done = (err) => {
      if (cb) cb(err);
      else if (err) this.req.next(err);
    };
    let full = String(path);
    if (opts.root) {
      if (full.split(/[\\/]/).includes("..")) return done(httpError(403, "Forbidden"));
      full = joinPath(opts.root, full);
    } else if (!isAbsolute(full)) {
      return done(new TypeError("sendFile needs an absolute path or the root option"));
    }
    const [st, err] = os.stat(full);
    if (err || (st.mode & os.S_IFMT) === os.S_IFDIR) return done(httpError(404, "Not Found"));
    if (opts.headers) this.set(opts.headers);
    if (!this.hasHeader("Content-Type")) this.type(typeOfFile(full));
    if (opts.lastModified !== false && !this.hasHeader("Last-Modified")) this.set("Last-Modified", new Date(st.mtime).toUTCString());
    if (!this.hasHeader("ETag") && opts.etag !== false) this.set("ETag", `W/"${st.size.toString(16)}-${Math.floor(st.mtime).toString(16)}"`);
    if (opts.maxAge != null && !this.hasHeader("Cache-Control")) this.set("Cache-Control", `public, max-age=${Math.floor(Number(opts.maxAge) / 1000)}`);
    if (this.fresh()) {
      this.statusCode = 304;
      this.end();
      return done();
    }
    if (this.req.method === "HEAD") {
      this.sendHead(st.size);
      this.end();
      return done();
    }
    const f = std.open(full, "rb");
    if (!f) return done(httpError(404, "Not Found"));
    this.sendHead(st.size);
    // in pieces as the connection takes them
    const piece = new Uint8Array(65536);
    const pump = () => {
      if (this.connection.closed) { f.close(); return; }
      while (this.connection.queued < 1 << 18) {
        const n = f.read(piece.buffer, 0, piece.length);
        if (n <= 0) {
          f.close();
          this.end();
          return done();
        }
        this.connection.send(piece.slice(0, n));
      }
      this.connection.whenDrained(pump);
    };
    pump();
  }
  download(path, filename, opts, cb) {
    if (typeof filename === "function") { cb = filename; filename = undefined; }
    else if (typeof opts === "function") { cb = opts; opts = undefined; }
    this.attachment(filename || String(path));
    return this.sendFile(path, opts || {}, cb);
  }
}

export function httpError(status, message) {
  const e = new Error(message || STATUS_CODES[status] || "Error");
  e.status = e.statusCode = status;
  e.expose = status < 500;
  return e;
}

// C:/x, C:\x, /x, \x
function isAbsolute(p) {
  return /^([A-Za-z]:)?[\\/]/.test(String(p));
}

// a relative folder from the current one, as Express resolves it
function absolute(p) {
  if (isAbsolute(p)) return String(p);
  const [cwd] = os.getcwd();
  return joinPath(cwd || "/", p);
}

function joinPath(root, rel) {
  return String(root).replace(/[\\/]+$/, "") + "/" + String(rel).replace(/^[\\/]+/, "");
}

function logError(e) {
  std.err.puts(`zdos:web: ${e && e.stack ? e.message + "\n" + e.stack : String(e)}\n`);
  std.err.flush();
}

// CONNECTIONS

const MAX_HEAD = 32768;

class Connection {
  constructor(server, fd, ip, port, tls) {
    this.server = server;
    this.fd = fd;
    this.ip = ip;
    this.port = port;
    this.tls = tls; // a TlsConnection, or null
    this.handshaking = Boolean(tls);
    this.inbuf = new Buffer();
    this.out = [];
    this.outAt = 0;
    this.queued = 0;
    this.drained = [];
    this.busy = false; // a request is being answered
    this.keepAlive = true;
    this.eof = false;
    this.closed = false;
    this.served = 0;
    this.head = null;
    this.tlsWant = null; // what TLS waits for: "read" / "write"
    this.timer = null;
    this.reading = false;
    this.writing = false;
    this.armTimer(server.headersTimeout);
    this.update();
    if (this.handshaking) this.handshake();
  }
  armTimer(ms) {
    if (this.timer) os.clearTimeout(this.timer);
    this.timer = ms ? os.setTimeout(() => { this.timer = null; this.close(); }, ms) : null;
  }
  // the read and write handlers this state needs
  update() {
    if (this.closed) return;
    const wantWrite = this.tlsWant === "write" || this.out.length > 0;
    const wantRead = this.tlsWant === "read" || (!this.eof && this.inbuf.length < (this.server.maxBodySize + MAX_HEAD));
    if (wantRead !== this.reading) {
      os.setReadHandler(this.fd, wantRead ? () => this.onReadable() : null);
      this.reading = wantRead;
    }
    if (wantWrite !== this.writing) {
      os.setWriteHandler(this.fd, wantWrite ? () => this.onWritable() : null);
      this.writing = wantWrite;
    }
  }
  handshake() {
    let r;
    try { r = this.tls.handshake(); } catch (e) { this.close(); return; }
    if (r === true) {
      this.handshaking = false;
      this.tlsWant = null;
      // data may have come with the handshake's last record
      return this.onReadable();
    } else {
      this.tlsWant = r;
    }
    this.update();
  }
  onReadable() {
    if (this.handshaking) return this.handshake();
    if (this.tlsWant === "read" || (this.tlsWant === "write" && this.out.length === 0)) this.tlsWant = null;
    for (;;) {
      const r = this.tls ? this.tls.read(65536) : net.read(this.fd, 65536);
      if (r === null || r === "read") break;
      if (r === "write") { this.tlsWant = "write"; break; }
      if (r.byteLength === 0) { this.eof = true; break; }
      this.inbuf.push(r);
      // a body still coming: the clock starts again
      if (!this.busy) this.armTimer(this.server.headersTimeout);
      if (!this.tls) break; // a plain socket: once per wake-up is enough
    }
    // TLS writing may have waited for this read
    if (this.out.length && !this.closed) this.flush();
    this.process();
    if (this.eof && !this.busy) return this.close();
    this.update();
  }
  onWritable() {
    if (this.handshaking) return this.handshake();
    if (this.tlsWant === "write" && this.out.length === 0) {
      this.tlsWant = null;
      this.onReadable();
      return;
    }
    this.flush();
  }
  send(bytes) {
    if (this.closed || !bytes.length) return;
    this.out.push(bytes);
    this.queued += bytes.length;
    this.flush();
  }
  whenDrained(fn) {
    if (this.queued === 0) os.setTimeout(fn, 0);
    else this.drained.push(fn);
  }
  flush() {
    while (this.out.length) {
      const b = this.out[0];
      const n = this.tls ? this.tls.write(b, this.outAt, b.length - this.outAt) : net.write(this.fd, b, this.outAt, b.length - this.outAt);
      if (n === "read" || n === "write") { this.tlsWant = n; break; }
      if (n < 0) { this.close(); return; }
      if (n === 0) break;
      this.outAt += n;
      this.queued -= n;
      if (this.outAt >= b.length) { this.out.shift(); this.outAt = 0; }
    }
    if (this.out.length === 0) {
      if (this.tlsWant === "write") this.tlsWant = null;
      const fns = this.drained;
      this.drained = [];
      for (const fn of fns) { try { fn(); } catch (e) { logError(e); } }
      if (this.out.length === 0 && this.finishing) this.afterResponse();
    }
    this.update();
  }
  // HTTP/1.1 requests, one at a time
  process() {
    while (!this.busy && !this.closed) {
      const req = this.parse();
      if (!req) return;
      this.busy = true;
      this.served++;
      this.armTimer(0);
      this.server.dispatch(this, req);
    }
  }
  error(code) {
    this.keepAlive = false;
    this.busy = true;
    const body = encode(STATUS_CODES[code] || "Error");
    this.send(encode(`HTTP/1.1 ${code} ${STATUS_CODES[code]}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.length}\r\nConnection: close\r\nDate: ${new Date().toUTCString()}\r\n\r\n`));
    this.send(body);
    this.finishing = true;
    if (this.out.length === 0) this.afterResponse();
    return null;
  }
  parse() {
    const b = this.inbuf;
    if (!this.head) {
      const end = b.find(CRLFCRLF);
      if (end < 0) return b.length > MAX_HEAD ? this.error(431) : null;
      if (end > MAX_HEAD) return this.error(431);
      // empty lines before a request are allowed (RFC 9112)
      let text = decode(b.peek(0, end));
      b.skip(end + 4);
      text = text.replace(/^(\r\n)+/, "");
      const lines = text.split("\r\n");
      const m = /^([A-Za-z!#$%&'*+.^_`|~-]+) (\S+) HTTP\/(1\.[01])$/.exec(lines[0]);
      if (!m) return this.error(400);
      const headers = Object.create(null), rawHeaders = [];
      for (let i = 1; i < lines.length; i++) {
        const line = lines[i];
        const c = line.indexOf(":");
        if (c <= 0 || /\s/.test(line[c - 1])) return this.error(400);
        const name = line.slice(0, c), value = line.slice(c + 1).trim();
        rawHeaders.push(name, value);
        const k = name.toLowerCase();
        if (k in headers) headers[k] += (k === "cookie" ? "; " : ", ") + value;
        else headers[k] = value;
      }
      const head = { method: m[1].toUpperCase(), target: m[2], version: m[3], headers, rawHeaders };
      const conn = (headers.connection || "").toLowerCase();
      this.keepAlive = head.version === "1.1" ? !conn.includes("close") : conn.includes("keep-alive");
      if (this.served >= this.server.maxRequestsPerSocket) this.keepAlive = false;
      if (headers["transfer-encoding"]) {
        if (!/chunked\s*$/i.test(headers["transfer-encoding"])) return this.error(501);
        head.chunked = true;
        head.chunks = [];
        head.got = 0;
      } else if (headers["content-length"] !== undefined) {
        if (!/^\d+$/.test(headers["content-length"])) return this.error(400);
        head.length = Number(headers["content-length"]);
        if (head.length > this.server.maxBodySize) return this.error(413);
      } else {
        head.length = 0;
      }
      if ((headers.expect || "").toLowerCase() === "100-continue" && head.version === "1.1") {
        this.send(encode("HTTP/1.1 100 Continue\r\n\r\n"));
      }
      this.head = head;
    }
    const head = this.head;
    let body;
    if (head.chunked) {
      for (;;) {
        if (head.trailers) {
          const e = b.find(CRLF);
          if (e < 0) return null;
          b.skip(e + 2);
          if (e === 0) break; // the empty line after the trailers
          continue;
        }
        const e = b.find(CRLF);
        if (e < 0) return b.length > 1024 ? this.error(400) : null;
        const size = parseInt(decode(b.peek(0, e)).split(";")[0].trim(), 16);
        if (!(size >= 0)) return this.error(400);
        if (size === 0) { b.skip(e + 2); head.trailers = true; continue; }
        if (b.length < e + 2 + size + 2) {
          if (head.got + size > this.server.maxBodySize) return this.error(413);
          return null;
        }
        b.skip(e + 2);
        head.chunks.push(b.take(size));
        head.got += size;
        b.skip(2);
        if (head.got > this.server.maxBodySize) return this.error(413);
      }
      body = concat(head.chunks, head.got);
    } else {
      if (b.length < head.length) return null;
      body = b.take(head.length);
    }
    this.head = null;
    return { head, body };
  }
  responseDone(res) {
    this.finishing = res;
    if (this.queued === 0) this.afterResponse();
  }
  afterResponse() {
    const res = this.finishing;
    this.finishing = null;
    // after the handler's own code, as Node: res.on("finish") right
    // after res.send() still hears it
    if (res && res.emit) queueMicrotask(() => res.emit("finish"));
    this.busy = false;
    // a server closing: no more requests on this connection
    if (!this.keepAlive || this.closed || !this.server.listening) return this.close();
    this.armTimer(this.server.keepAliveTimeout);
    this.process();
    if (this.eof && !this.busy) return this.close();
    this.update();
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    if (this.timer) { os.clearTimeout(this.timer); this.timer = null; }
    os.setReadHandler(this.fd, null);
    os.setWriteHandler(this.fd, null);
    if (this.tls) { try { this.tls.close(); } catch {} }
    net.close(this.fd);
    this.server.connections.delete(this);
    if (this.current && !this.current.finished) this.current.emit("close");
    this.server.maybeClosed();
  }
}

// SERVERS

export class Server {
  constructor(handler, opts = {}) {
    this.handler = handler;
    this.tlsServer = null;
    this.connections = new Set();
    this.listening = false;
    this.closeCallbacks = [];
    this.maxBodySize = opts.maxBodySize || 16 * 1024 * 1024;
    this.keepAliveTimeout = opts.keepAliveTimeout ?? 15000;
    this.headersTimeout = opts.headersTimeout ?? 30000;
    this.maxRequestsPerSocket = opts.maxRequestsPerSocket || 1000;
    const tls = opts.tls;
    if (tls) {
      const cert = tls.cert || std.loadFile(tls.certFile);
      const key = tls.key || std.loadFile(tls.keyFile);
      if (!cert) throw new Error(`zdos:web: no certificate (${tls.certFile})`);
      if (!key) throw new Error(`zdos:web: no key (${tls.keyFile})`);
      this.tlsServer = new net.TlsServer(cert, key);
    }
  }
  listen(port = 0, host, cb) {
    if (typeof host === "function") { cb = host; host = undefined; }
    this.fd = net.listen(Number(port), host || "0.0.0.0");
    this.port = Number(port);
    this.host = host || "0.0.0.0";
    this.listening = true;
    os.setReadHandler(this.fd, () => this.acceptAll());
    if (cb) os.setTimeout(() => cb.call(this), 0);
    return this;
  }
  address() { return { address: this.host, family: "IPv4", port: this.port }; }
  acceptAll() {
    for (;;) {
      const a = net.accept(this.fd);
      if (!a) return;
      const [fd, ip, port] = a;
      let tls = null;
      if (this.tlsServer) {
        try { tls = this.tlsServer.accept(fd); } catch (e) { net.close(fd); logError(e); continue; }
      }
      this.connections.add(new Connection(this, fd, ip, port, tls));
    }
  }
  dispatch(conn, { head, body }) {
    const req = new Request(conn, head, body);
    const res = new Response(conn, req);
    req.res = res;
    conn.current = res;
    try {
      this.handler(req, res);
    } catch (e) {
      logError(e);
      if (!res.headersSent) res.status(500).type("text/plain").end("Internal Server Error");
      else conn.close();
    }
  }
  close(cb) {
    if (cb) this.closeCallbacks.push(cb);
    if (this.listening) {
      os.setReadHandler(this.fd, null);
      net.close(this.fd);
      this.listening = false;
    }
    for (const c of [...this.connections]) if (!c.busy) c.close();
    this.maybeClosed();
    return this;
  }
  maybeClosed() {
    if (this.listening || this.connections.size) return;
    const cbs = this.closeCallbacks;
    this.closeCallbacks = [];
    for (const cb of cbs) os.setTimeout(cb, 0);
  }
}

export function createServer(opts, handler) {
  if (typeof opts === "function") { handler = opts; opts = {}; }
  return new Server(handler, opts);
}

// THE APPLICATION

function finalHandler(req, res) {
  return (err) => {
    if (res.headersSent) {
      if (err) { logError(err); if (!res.finished) res.connection.close(); }
      return;
    }
    if (err) {
      let status = Number(err.status || err.statusCode);
      if (!(status >= 400 && status < 600)) status = 500;
      if (status >= 500) logError(err);
      res.statusCode = status;
      res.headers.clear();
      if (err.headers) res.set(err.headers);
      const msg = status < 500 || err.expose ? err.message || STATUS_CODES[status] : STATUS_CODES[status];
      res.set("Content-Security-Policy", "default-src 'none'").set("X-Content-Type-Options", "nosniff");
      return res.type("text/plain").end(msg);
    }
    res.statusCode = 404;
    res.set("Content-Security-Policy", "default-src 'none'").set("X-Content-Type-Options", "nosniff");
    res.type("text/plain").end(`Cannot ${req.method} ${pathOf(req.originalUrl)}`);
  };
}

export function express() {
  const app = function (req, res, next) { app.handle(req, res, next); };
  const router = new Router();
  const settings = { etag: true, "x-powered-by": false, env: "production", "json spaces": undefined };
  Object.assign(app, {
    locals: Object.create(null),
    settings,
    router,
    mountpath: "/",
    servers: [],
    set(name, value) { settings[name] = value; return app; },
    get(name, ...fns) {
      if (fns.length === 0) return settings[name];
      router.get(name, ...fns);
      return app;
    },
    enable(name) { settings[name] = true; return app; },
    disable(name) { settings[name] = false; return app; },
    enabled(name) { return Boolean(settings[name]); },
    disabled(name) { return !settings[name]; },
    use(...args) {
      // a sub-app keeps its own settings; it learns where it is mounted
      for (const a of args.flat()) if (typeof a === "function" && a.settings && a !== app) a.parent = app;
      router.use(...args);
      return app;
    },
    route(path) { return router.route(path); },
    all(path, ...fns) { router.all(path, ...fns); return app; },
    param(name, fn) { router.param(name, fn); return app; },
    handle(req, res, next) {
      const top = !req.app;
      const prevApp = req.app;
      req.app = res.app = app;
      req.res = res;
      const out = next ? (err) => { req.app = res.app = prevApp; next(err); } : finalHandler(req, res);
      if (top) req.next = out;
      router.handle(req, res, out);
    },
    listen(port, host, cb) {
      let opts = {};
      if (typeof port === "object" && port !== null) { opts = port; cb = host; host = opts.host; port = opts.port; }
      if (typeof host === "function") { cb = host; host = undefined; }
      const server = new Server(app, { ...opts, maxBodySize: opts.maxBodySize || settings["max body size"] });
      server.listen(port ?? (opts.tls ? 443 : 80), host, cb);
      app.servers.push(server);
      return server;
    },
  });
  for (const m of METHODS) {
    if (m === "get") continue;
    app[m] = (path, ...fns) => { router[m](path, ...fns); return app; };
  }
  app.delete = app["delete"];
  return app;
}

// MIDDLEWARE

function limitOf(v, dflt) {
  if (v == null) return dflt;
  if (typeof v === "number") return v;
  const m = /^(\d+(?:\.\d+)?)\s*(b|kb|mb|gb)?$/i.exec(String(v).trim());
  if (!m) return dflt;
  return Math.floor(parseFloat(m[1]) * { b: 1, kb: 1024, mb: 1048576, gb: 1073741824 }[(m[2] || "b").toLowerCase()]);
}

// A body parser: when the request's type matches, req.body = parse(bytes)
function bodyParser(defaultType, defaultLimit, parse, opts = {}) {
  const limit = limitOf(opts.limit, defaultLimit);
  const types = [].concat(opts.type || defaultType);
  const matches = typeof opts.type === "function" ? opts.type : (req) => types.some((t) => typeMatches(req.headers["content-type"], t));
  return function parser(req, res, next) {
    if (req._bodyParsed) return next();
    if (req.body === undefined && defaultType !== "application/octet-stream" && defaultType !== "text/plain") req.body = {};
    const raw = req.rawBody;
    if (!raw || raw.length === 0 || !req.headers["content-type"] || !matches(req)) return next();
    if (raw.length > limit) return next(httpError(413, "request entity too large"));
    try {
      req.body = parse(raw, req);
      req._bodyParsed = true;
      if (opts.verify) opts.verify(req, res, raw);
    } catch (e) {
      const err = e && e.status ? e : httpError(400, e && e.message ? e.message : "Bad Request");
      err.body = decode(raw);
      return next(err);
    }
    next();
  };
}

express.json = (opts = {}) => bodyParser("application/json", 102400, (raw) => {
  const text = decode(raw).replace(/^\uFEFF/, "");
  if (opts.strict !== false && !/^\s*[[{]/.test(text)) throw httpError(400, "JSON body: an object or an array");
  return JSON.parse(text, opts.reviver);
}, opts);

express.urlencoded = (opts = {}) => bodyParser("application/x-www-form-urlencoded", 102400, (raw) => {
  const q = parseQuery(decode(raw));
  return Object.assign({}, q);
}, opts);

express.text = (opts = {}) => bodyParser("text/plain", 102400, (raw) => decode(raw), opts);

express.raw = (opts = {}) => bodyParser("application/octet-stream", 102400, (raw) => raw, opts);

// Files of a folder: GET and HEAD, index.html for a folder, else next()
express.static = (root, opts = {}) => {
  root = absolute(root);
  const index = opts.index === undefined ? ["index.html"] : opts.index === false ? [] : [].concat(opts.index);
  const fallthrough = opts.fallthrough !== false;
  return function serveStatic(req, res, next) {
    if (req.method !== "GET" && req.method !== "HEAD") {
      if (fallthrough) return next();
      return res.set("Allow", "GET, HEAD").sendStatus(405);
    }
    let rel;
    try { rel = decodeURIComponent(req.path); } catch { return next(fallthrough ? undefined : httpError(400)); }
    const parts = rel.split("/");
    if (parts.includes("..") || rel.includes("\\") || rel.includes("\0") || /^[A-Za-z]:/.test(parts[1] || "")) {
      return next(httpError(403, "Forbidden"));
    }
    if (parts.some((p) => p.startsWith(".") && p.length > 1) && opts.dotfiles !== "allow") {
      if (opts.dotfiles === "deny") return next(httpError(403, "Forbidden"));
      return fallthrough ? next() : next(httpError(404));
    }
    let full = joinPath(root, rel);
    let [st, err] = os.stat(full);
    if (err) return fallthrough ? next() : next(httpError(404));
    if ((st.mode & os.S_IFMT) === os.S_IFDIR) {
      if (!rel.endsWith("/")) {
        if (opts.redirect === false) return next();
        const q = req.originalUrl.indexOf("?");
        const path = q < 0 ? req.originalUrl : req.originalUrl.slice(0, q);
        return res.redirect(301, path + "/" + (q < 0 ? "" : req.originalUrl.slice(q)));
      }
      const found = index.map((i) => joinPath(full, i)).find((p) => {
        const [s, e] = os.stat(p);
        return !e && (s.mode & os.S_IFMT) !== os.S_IFDIR;
      });
      if (!found) return fallthrough ? next() : next(httpError(404));
      full = found;
    }
    if (opts.setHeaders) opts.setHeaders(res, full, st);
    res.sendFile(full, { maxAge: limitOf(opts.maxAge, 0), etag: opts.etag, lastModified: opts.lastModified }, (e) => {
      if (e) next(e.status === 404 && fallthrough ? undefined : e);
    });
  };
};

// One line a request when it is answered: method, URL, status,
// milliseconds, bytes of the body
express.logger = (opts = {}) => (req, res, next) => {
  const start = Date.now();
  res.on("finish", () => {
    const line = `${new Date().toISOString()} ${req.ip} ${req.method} ${req.originalUrl} ${res.statusCode} ${Date.now() - start}ms ${res.get("Content-Length") ?? "-"}`;
    (opts.stream || std.out).puts(line + "\n");
    (opts.stream || std.out).flush();
  });
  next();
};

express.Router = (opts) => new Router(opts);
express.Route = Route;
express.Request = Request;
express.Response = Response;
express.createServer = createServer;
express.httpError = httpError;
express.STATUS_CODES = STATUS_CODES;
express.METHODS = METHODS.map((m) => m.toUpperCase());
express.parseQuery = parseQuery;
express.version = version;

export default express;
