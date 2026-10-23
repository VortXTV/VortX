import test from "node:test";
import assert from "node:assert/strict";
import { fresh, session, seedOwned, loginTransport, deferred, input, action, storageEvent, admit, Node } from "../lib/auth-adoption.fixtures.mjs";

test("actual Login submit persists the owned session pair before navigating (original-source RED ingress)", async () => {
  const f = await fresh({ account: true }), a = session();
  const view = await import("./login.ts" + f.query);
  await loginTransport(f.vault, a);
  view.renderLogin(f.host);
  input(f.host, "in-login", a.account.email); input(f.host, "in-pw", "synthetic-password");
  await f.host.querySelector("#form-in").submit();
  // These are existing public behaviors, not a proposed-export existence check.
  assert.equal(f.vault.loadSession()?.account.id, a.account.id, "fresh sign-in must actually persist before leaving Login");
  assert.equal(JSON.parse(f.local.getItem("vortx.session.v1")).token, a.token);
  assert.equal(JSON.parse(f.tab.getItem("vortx.dk.v2")).accountId, a.account.id);
  assert.equal(location.hash, "#/");
  view.disposeLogin?.();
});

test("late login success cannot adopt, navigate, or paint a replacement form", async () => {
  const f = await fresh({ account: true }), response = deferred(), entered = deferred();
  const view = await import("./login.ts" + f.query);
  await loginTransport(f.vault, session(), (data) => { entered.resolve(data); return response.promise; });
  view.renderLogin(f.host); input(f.host, "in-login", "a@example.invalid"); input(f.host, "in-pw", "synthetic-password");
  const old = f.host.querySelector("#form-in").submit(); const data = await entered.promise;
  view.renderLogin(f.host); input(f.host, "in-login", "replacement@example.invalid");
  response.resolve(Response.json(data)); await old;
  assert.equal(f.account.currentSession(), null); assert.equal(f.local.getItem("vortx.session.v1"), null);
  assert.equal(location.hash, "#/login"); assert.equal(f.host.querySelector("#in-login").value, "replacement@example.invalid");
  view.disposeLogin();
});

test("late TOTP/error response cannot reveal or rewrite a reused-id replacement form", async () => {
  const f = await fresh({ account: true }), response = deferred(), entered = deferred();
  const view = await import("./login.ts" + f.query);
  await loginTransport(f.vault, session(), () => { entered.resolve(); return response.promise; });
  view.renderLogin(f.host); input(f.host, "in-login", "a@example.invalid"); input(f.host, "in-pw", "synthetic-password");
  const old = f.host.querySelector("#form-in").submit(); await entered.promise;
  view.renderLogin(f.host);
  const wrap = f.host.querySelector("#in-totp-wrap"), error = f.host.querySelector("#in-err");
  wrap.hidden = true; error.textContent = "replacement";
  response.resolve(Response.json({ error: "totp_required" }, { status: 401 })); await old;
  assert.equal(wrap.hidden, true); assert.equal(error.textContent, "replacement");
  view.disposeLogin();
});

test("retirement after persisted adoption fences hydration completion without rolling back saved pair", async () => {
  const f = await fresh({ account: true }), held = deferred(), entered = deferred();
  const view = await import("./login.ts" + f.query); await loginTransport(f.vault);
  const transport = fetch;
  globalThis.fetch = async (url, opts) => { if (url.endsWith("/v1/backup")) { entered.resolve(); return held.promise; } return transport(url, opts); };
  view.renderLogin(f.host); input(f.host, "in-login", "a@example.invalid"); input(f.host, "in-pw", "synthetic-password");
  const submit = f.host.querySelector("#form-in").submit(); await entered.promise;
  const stored = f.local.getItem("vortx.session.v1");
  view.disposeLogin(); location.hash = "#/settings";
  held.resolve(new Response(null, { status: 404 })); await submit;
  assert.equal(f.local.getItem("vortx.session.v1"), stored); assert.equal(location.hash, "#/settings");
});

test("Settings signout consumes asynchronous failure and residual descriptor remains retired", async () => {
  const f = await fresh({ account: true }); seedOwned(session()); f.vault.startSessionAuthority();
  const view = await import("./settings.ts" + f.query); view.renderSettings(f.host);
  f.local.fault = (stage) => { if (stage === "before-remove") throw Error("synthetic denial"); };
  assert.equal(view.handleSettingsClick(action(f.host, "account-signout")), true);
  // The synchronous global click contract remains boolean; volatile owner is already retired.
  assert.equal(f.account.currentSession(), null);
  for (let tick = 0; tick < 12; tick++) await Promise.resolve();
  storageEvent(); assert.equal(f.account.currentSession(), null);
  assert.ok(f.local.getItem("vortx.session.v1"));
  assert.match(f.host.querySelector("[data-logout-status]").textContent, /could not be confirmed/);
});

test("approval binds the rendered owner and code instead of recapturing at click", async () => {
  const f = await fresh({ account: true }); seedOwned(session()); f.vault.startSessionAuthority();
  location.hash = "#/approve?c=SYNTHETIC&k=synthetic-public-key";
  const view = await import("./approve.ts" + f.query); view.renderApprove(f.host);
  let requests = 0; globalThis.fetch = async () => { requests++; throw Error("must not authorize"); };
  location.hash = "#/approve?c=OTHER&k=synthetic-public-key";
  view.handleApproveClick(action(f.host, "approve-device"));
  await Promise.resolve(); assert.equal(requests, 0);
  storageEvent();
  assert.match(f.host.innerHTML, /Account changed/);
  assert.equal(view.handleApproveClick(action(f.host, "approve-device")), false);
  view.disposeApprove();
});

function visibleAction(host, name) {
  const node = host.querySelector('[data-action="' + name + '"]');
  assert.ok(node, "actual rendered control: " + name); assert.equal(host.contains(node), true);
  return node;
}
function nextRendered(host, predicate) {
  const rendered = deferred(), descriptor = Object.getOwnPropertyDescriptor(Node.prototype, "innerHTML");
  Object.defineProperty(host, "innerHTML", {
    configurable: true,
    get() { return descriptor.get.call(this); },
    set(value) { descriptor.set.call(this, value); if (predicate(value)) rendered.resolve(); },
  });
  return rendered.promise;
}

test("Login owner event and signout notify a finite snapshot without replacing listeners endlessly", async () => {
  for (const reason of ["owner-event", "signout"]) {
    const f = await fresh({ account: true }); await admit(f.vault, session(), f.account);
    const view = await import("./login.ts" + f.query); view.renderLogin(f.host);
    const query = f.host.querySelectorAll.bind(f.host); let scrubs = 0, exceeded = false;
    // Bound an unfixed synchronous loop in the fixture: disposal unsubscribes BEFORE this scrub.
    // A fourth replacement throws before appending another listener; the real notifier catches it.
    f.host.querySelectorAll = (selector) => {
      if (selector === "input" && ++scrubs > 3) { exceeded = true; throw Error("unbounded listener replacement"); }
      return query(selector);
    };
    if (reason === "owner-event") storageEvent();
    else view.handleLoginClick(visibleAction(f.host, "sign-out"));
    for (let tick = 0; tick < 12; tick++) await Promise.resolve();
    assert.equal(exceeded, false);
    assert.equal(scrubs, reason === "owner-event" ? 1 : 2, "one listener batch, plus explicit signout status render");
    f.host.querySelectorAll = query; view.disposeLogin();
  }
});

test("same create form exposes accepted-save recovery and warning without another request or route change", async () => {
  const f = await fresh({ account: true }), entered = deferred(), response = deferred();
  const view = await import("./login.ts" + f.query); let posts = 0;
  globalThis.fetch = async () => { posts++; entered.resolve(); return response.promise; };
  view.renderLogin(f.host); view.handleLoginClick(visibleAction(f.host, "auth-tab-up"));
  input(f.host, "up-email", "created@example.invalid"); input(f.host, "up-username", "created"); input(f.host, "up-pw", "synthetic-password");
  const form = f.host.querySelector("#form-up"), submit = form.submit();
  assert.match(f.host.querySelector("#auth-pending").innerHTML, /Keep this tab open/);
  await entered.promise;
  f.tab.fault = (phase) => { if (phase === "before-set") throw Error("synthetic quota"); };
  response.resolve(Response.json({ token: "synthetic-created", account: session("created").account })); await submit;
  assert.equal(f.host.querySelector("#form-up"), form);
  assert.equal(f.host.querySelector("#up-email").value, "created@example.invalid");
  const resume = visibleAction(f.host, "resume-setup");
  assert.equal(location.hash, "#/login"); assert.equal(posts, 1);
  f.tab.fault = undefined;
  const rendered = nextRendered(f.host, (html) => html.includes('id="reccode"'));
  view.handleLoginClick(resume); await rendered;
  assert.equal(f.vault.loadSession().account.id, "created"); assert.equal(posts, 1);
  assert.match(f.host.innerHTML, /VX-/); view.disposeLogin();
});

test("same reset form exposes accepted proof-failure recovery with no reset replay", async () => {
  const f = await fresh({ account: true }), view = await import("./login.ts" + f.query);
  let posts = 0;
  globalThis.fetch = async (url) => url.endsWith("/prelogin")
    ? Response.json({ kdfSalt: Buffer.alloc(16).toString("base64"), kdfIters: 210000 })
    : (posts++, Response.json({ token: "synthetic-reset", account: session("reset").account }));
  view.renderLogin(f.host); view.handleLoginClick(visibleAction(f.host, "to-recover"));
  view.handleLoginClick(visibleAction(f.host, "to-reset"));
  input(f.host, "rs-email", "reset@example.invalid"); input(f.host, "rs-code", "123456"); input(f.host, "rs-pw", "synthetic-password");
  const form = f.host.querySelector("#form-reset"), original = crypto.subtle.digest.bind(crypto.subtle);
  crypto.subtle.digest = async () => { throw Error("synthetic finalization failure"); };
  try { await form.submit(); } finally { crypto.subtle.digest = original; }
  assert.equal(f.host.querySelector("#form-reset"), form);
  assert.match(f.host.querySelector("#auth-pending").innerHTML, /Keep this tab open/);
  const resume = visibleAction(f.host, "resume-setup");
  const rendered = nextRendered(f.host, (html) => html.includes('id="reccode"'));
  view.handleLoginClick(resume); await rendered;
  assert.equal(f.vault.loadSession().account.id, "reset"); assert.equal(posts, 1);
  assert.equal(f.vault.pendingAuthOperation().proofReady, true); view.disposeLogin();
});

test("same form shows unknown retention warning without inventing a resume or replay control", async () => {
  const f = await fresh({ account: true }), view = await import("./login.ts" + f.query); let posts = 0;
  globalThis.fetch = async () => { posts++; throw Error("synthetic response lost"); };
  view.renderLogin(f.host); view.handleLoginClick(visibleAction(f.host, "auth-tab-up"));
  input(f.host, "up-email", "created@example.invalid"); input(f.host, "up-username", "created"); input(f.host, "up-pw", "synthetic-password");
  await f.host.querySelector("#form-up").submit();
  assert.match(f.host.querySelector("#auth-pending").innerHTML, /Keep this tab open/);
  assert.match(f.host.querySelector("#auth-pending").innerHTML, /outcome is unknown/);
  assert.equal(f.host.querySelector('[data-action="resume-setup"]'), null);
  assert.equal(posts, 1); view.disposeLogin();
  assert.equal(f.vault.pendingAuthOperation().outcome, "unknown");
});

test("username availability binds its exact query/node and cannot overwrite a later input", async () => {
  const f = await fresh({ account: true }), view = await import("./login.ts" + f.query), response = deferred();
  let timer, requests = 0;
  window.setTimeout = (run) => { timer = run; return 1; }; window.clearTimeout = () => {};
  globalThis.fetch = async () => { requests++; return response.promise; };
  view.renderLogin(f.host); view.handleLoginClick(visibleAction(f.host, "auth-tab-up"));
  const name = f.host.querySelector("#up-username"), hint = f.host.querySelector("#up-uhint");
  name.value = "original"; name.listeners.get("input")();
  const pending = timer(); assert.equal(requests, 1);
  name.value = "replacement"; name.listeners.get("input")(); hint.textContent = "new query owns this hint";
  response.resolve(Response.json({ available: true })); await pending;
  assert.equal(hint.textContent, "new query owns this hint"); view.disposeLogin();
});

test("recovery code and late clipboard effects retire with the original Login surface", async () => {
  const f = await fresh({ account: true }), view = await import("./login.ts" + f.query);
  globalThis.fetch = async () => Response.json({ token: "synthetic-created", account: session("created").account });
  view.renderLogin(f.host); view.handleLoginClick(visibleAction(f.host, "auth-tab-up"));
  input(f.host, "up-email", "created@example.invalid"); input(f.host, "up-username", "created"); input(f.host, "up-pw", "synthetic-password");
  await f.host.querySelector("#form-up").submit();
  const copied = deferred(), entered = deferred();
  navigator.clipboard.writeText = async (value) => { entered.resolve(value); await copied.promise; };
  const button = visibleAction(f.host, "copy-reccode");
  view.handleLoginClick(button);
  const secret = await entered.promise; assert.match(secret, /^VX-/);
  view.disposeLogin(); view.renderLogin(f.host);
  const current = f.host.innerHTML; copied.resolve();
  for (let tick = 0; tick < 6; tick++) await Promise.resolve();
  assert.notEqual(button.textContent, "Copied");
  assert.equal(f.host.innerHTML, current); assert.equal(f.host.innerHTML.includes(secret), false);
  assert.equal(f.vault.pendingAuthOperation().codeRetained, true, "retirement does not discard unacknowledged code");
  view.disposeLogin();
});
