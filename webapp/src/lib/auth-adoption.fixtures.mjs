import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { registerHooks } from "node:module";
import { webcrypto } from "node:crypto";
// Fixture-only module graph isolation. Every production import shares the same fresh vault authority.
registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith(".") && context.parentURL) {
    const parent = new URL(context.parentURL);
    let candidate = new URL(specifier, parent);
    if (!/\.[a-z]+$/i.test(candidate.pathname)) candidate.pathname += ".ts";
    if (candidate.pathname.endsWith(".ts") && existsSync(fileURLToPath(candidate))) {
      if (parent.searchParams.has("auth-fixture")) candidate.searchParams.set("auth-fixture", parent.searchParams.get("auth-fixture"));
      return { url: candidate.href, shortCircuit: true };
    }
  }
  return next(specifier, context);
} });
export class Storage {
  values = new Map(); writes = []; fault;
  get length() { return this.values.size; }
  key(i) { return [...this.values.keys()][i] ?? null; }
  getItem(key) { this.fault?.("get", key); return this.values.get(key) ?? null; }
  setItem(key, value) { this.fault?.("before-set", key); this.values.set(key, String(value)); this.writes.push(["set", key]); this.fault?.("after-set", key); }
  removeItem(key) { this.fault?.("before-remove", key); this.values.delete(key); this.writes.push(["remove", key]); this.fault?.("after-remove", key); }
}
export const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
export class Locks {
  held = false; queue = []; requests = [];
  request(name, options, callback) {
    this.requests.push({ name, options });
    const d = deferred(), job = { options, callback, d };
    const abort = () => { const i = this.queue.indexOf(job); if (i >= 0) this.queue.splice(i, 1); d.reject(new DOMException("aborted", "AbortError")); };
    if (options.signal.aborted) { abort(); return d.promise; }
    options.signal.addEventListener("abort", abort, { once: true });
    this.queue.push(job);
    if (!this.held) this.grant();
    return d.promise;
  }
  grant() {
    const job = this.queue.shift(); if (!job) return;
    if (job.options.signal.aborted) { job.d.reject(new DOMException("aborted", "AbortError")); return; }
    try { job.d.resolve(job.callback()); } catch (x) { job.d.reject(x); }
  }
}
export class Node {
  dataset = {}; value = ""; textContent = ""; hidden = false; disabled = false; className = ""; isConnected = true;
  listeners = new Map(); nodes = new Map(); parent;
  classList = { add() {}, remove() {}, toggle() {} }; style = { setProperty() {}, removeProperty() {} };
  addEventListener(name, fn) { this.listeners.set(name, fn); }
  removeAttribute() {} focus() {} setAttribute() {}
  contains(node) { return node === this || [...this.nodes.values()].some((value) => value === node || value.contains(node)); }
  closest(selector) { if (selector === "[data-action]" && this.dataset.action) return this; return this.parent?.closest(selector) ?? null; }
  querySelector(selector) { return this.nodes.get(selector) ?? [...this.nodes.values()].map((node) => node.querySelector(selector)).find(Boolean) ?? null; }
  querySelectorAll(selector) { return selector === "input" ? [...this.nodes.values()].filter((n) => n.input) : []; }
  insertAdjacentHTML() {}
  set innerHTML(value) {
    for (const node of this.nodes.values()) node.isConnected = false;
    this.nodes.clear(); this.html = value;
    for (const match of value.matchAll(/<(?:p|span)[^>]*\b(data-[\w-]+)[^>]*>/g)) {
      const node = new Node(); node.parent = this; this.nodes.set("[" + match[1] + "]", node);
    }
    for (const match of value.matchAll(/<([a-z]+)[^>]*\bid="([^"]+)"[^>]*>/g)) {
      const node = new Node(); node.input = match[1] === "input"; node.parent = this; this.nodes.set("#" + match[2], node);
      if (match[1] === "form") { const button = new Node(); button.parent = node; node.nodes.set("button[type=submit]", button); }
    }
    const pending = value.match(/<div id="auth-pending"[^>]*>([\s\S]*?)<\/div>/);
    const pendingNode = this.nodes.get("#auth-pending");
    if (pending && pendingNode) pendingNode.innerHTML = pending[1];
    const controls = pending ? value.replace(pending[0], "") : value;
    for (const match of controls.matchAll(/<button[^>]*\bdata-action="([^"]+)"[^>]*>/g)) {
      const node = new Node(); node.parent = this; node.dataset.action = match[1];
      this.nodes.set('[data-action="' + match[1] + '"]', node);
    }
  }
  get innerHTML() { return this.html ?? ""; }
  submit() { return this.listeners.get("submit")?.({ preventDefault() {}, currentTarget: this }); }
}
let realm = 0;
export const session = (id = "synthetic-a", byte = 3) => ({ token: "synthetic-token-" + id, account: { id, username: id, email: id + "@example.invalid", unknown: { keep: [1, { future: true }] } }, dataKey: new Uint8Array(32).fill(byte) });
export function seedOwned(s) {
  localStorage.setItem("vortx.session.v1", JSON.stringify({ token: s.token, account: s.account }));
  sessionStorage.setItem("vortx.dk.v2", JSON.stringify({ schemaVersion: 2, accountId: s.account.id, token: s.token, dataKey: Buffer.from(s.dataKey).toString("base64") }));
}
export function storageEvent() { window.dispatchEvent(Object.assign(new Event("storage"), { key: "vortx.session.v1" })); }
export async function fresh({ account = false } = {}) {
  const local = new Storage(), tab = new Storage(), locks = new Locks(), host = new Node();
  const doc = Object.assign(new EventTarget(), { visibilityState: "visible", hidden: false, documentElement: new Node(), getElementById: (id) => host.querySelector("#" + id) });
  Object.defineProperty(globalThis, "crypto", { configurable: true, value: webcrypto });
  Object.assign(globalThis, { localStorage: local, sessionStorage: tab, Node, HTMLElement: Node,
    window: Object.assign(new EventTarget(), { setTimeout, clearTimeout, matchMedia: () => ({ matches: false }) }),
    document: doc, matchMedia: () => ({ matches: false }), location: { hash: "#/login", pathname: "/", search: "" },
    CustomEvent: class extends Event { constructor(type, options) { super(type); this.detail = options?.detail; } },
    WebSocket: class { close() {} } });
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: { onLine: true, locks, clipboard: { writeText: async () => {} } } });
  globalThis.fetch = async () => { throw Error("unexpected synthetic transport"); };
  const query = "?auth-fixture=" + (++realm);
  const vault = await import("./vault.ts" + query);
  const app = account ? await import("./account.ts" + query) : null;
  return { vault, account: app, local, tab, locks, host, query };
}
export async function loginCandidate(vault, value = session(), surface) {
  const salt = new Uint8Array(16), password = "synthetic-password";
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const master = new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: 210000, hash: "SHA-256" }, key, 256));
  const wrapped = await vault.__syncCryptoTestHooks.sealDocument(master, value.dataKey, value.account.id, 0, false);
  const previous = globalThis.fetch, handle = vault.beginAuthAttempt("login", surface);
  globalThis.fetch = async (url, opts) => {
    if (url.endsWith("/v1/auth/prelogin")) return Response.json({ kdfSalt: Buffer.from(salt).toString("base64"), kdfIters: 210000 });
    if (url.endsWith("/v1/auth/login")) return Response.json({ token: value.token, account: value.account, wrappedKeyPassword: wrapped });
    return previous(url, opts);
  };
  try { await vault.login(value.account.email, password, undefined, handle); return handle; }
  finally { globalThis.fetch = previous; }
}
export async function admit(vault, value = session(), account) {
  const handle = await loginCandidate(vault, value);
  const result = await (account ? account.adoptSession(handle) : vault.completeAuthAttempt(handle));
  if (result.status !== "persisted") throw Error("synthetic admission did not persist");
  return result;
}

export async function loginTransport(vault, value = session(), onLogin) {
  const salt = new Uint8Array(16), password = "synthetic-password";
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const master = new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: 210000, hash: "SHA-256" }, key, 256));
  const wrapped = await vault.__syncCryptoTestHooks.sealDocument(master, value.dataKey, value.account.id, 0, false);
  globalThis.fetch = async (url) => {
    if (url.endsWith("/v1/auth/prelogin")) return Response.json({ kdfSalt: Buffer.from(salt).toString("base64"), kdfIters: 210000 });
    if (url.endsWith("/v1/auth/login")) return onLogin ? onLogin({ token: value.token, account: value.account, wrappedKeyPassword: wrapped }) : Response.json({ token: value.token, account: value.account, wrappedKeyPassword: wrapped });
    if (url.endsWith("/v1/backup")) return new Response(null, { status: 404 });
    throw Error("unexpected synthetic request");
  };
}
export function input(host, id, value) { host.querySelector("#" + id).value = value; }
export function action(host, name) { const node = new Node(); node.dataset.action = name; node.parent = host; host.nodes.set("[action=" + name + "]", node); return node; }
