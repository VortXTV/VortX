import test from "node:test";
import assert from "node:assert/strict";
import { fresh, session, seedOwned, storageEvent, loginCandidate, admit, deferred } from "./auth-adoption.fixtures.mjs";

test("actual login candidate persists a coherent owned pair and preserves nested unknown metadata", async () => {
  const f = await fresh(), a = session(), handle = await loginCandidate(f.vault, a);
  a.account.unknown.keep[1].future = false;
  const result = await f.vault.completeAuthAttempt(handle);
  assert.equal(result.status, "persisted");
  assert.equal(f.vault.loadSession().account.unknown.keep[1].future, true);
  assert.equal(Object.hasOwn(JSON.parse(f.local.getItem("vortx.session.v1")), "dataKey"), false);
  assert.equal(await f.vault.completeAuthAttempt(handle), result, "one-shot historical outcome");
  assert.equal(f.locks.requests[0].name, "vortx.session.writer");
});

test("load is pure; owned embedded legacy migration is explicit and retains ratchets/unknown fields", async () => {
  const f = await fresh(), a = session();
  const legacy = JSON.stringify({ token: a.token, account: a.account, dataKey: Buffer.from(a.dataKey).toString("base64"), future: { keep: true } });
  f.local.setItem("vortx.session.v1", legacy); f.tab.setItem("vortx.dk.v1", "synthetic-unrelated");
  f.local.setItem("vortx.syncVer.other", "100"); const writes = f.local.writes.length;
  assert.equal(f.vault.loadSession().account.id, a.account.id);
  assert.equal(f.local.writes.length, writes);
  assert.equal((await f.vault.migrateSession()).status, "persisted");
  assert.equal(JSON.parse(f.local.getItem("vortx.session.v1")).future.keep, true);
  assert.equal(f.tab.getItem("vortx.dk.v1"), "synthetic-unrelated");
  assert.equal(f.local.getItem("vortx.syncVer.other"), "100");
});

test("key/head failures preserve exact predecessor; throw-after-publish is committed", async () => {
  for (const phase of ["key", "head", "after-head"]) {
    const f = await fresh(), a = session("a"), b = session("b", 9); seedOwned(a);
    const before = [f.local.getItem("vortx.session.v1"), f.tab.getItem("vortx.dk.v2")];
    const handle = await loginCandidate(f.vault, b);
    if (phase === "key") f.tab.fault = (stage, key) => { if (stage === "before-set" && key === "vortx.dk.v2") throw Error("synthetic quota"); };
    else f.local.fault = (stage, key) => { if (stage === (phase === "head" ? "before-set" : "after-set") && key === "vortx.session.v1") throw Error("synthetic quota"); };
    const result = await f.vault.completeAuthAttempt(handle);
    f.local.fault = f.tab.fault = undefined;
    assert.equal(result.status, phase === "after-head" ? "persisted" : "not-persisted");
    if (phase !== "after-head") assert.deepEqual([f.local.getItem("vortx.session.v1"), f.tab.getItem("vortx.dk.v2")], before);
    else assert.equal(f.vault.loadSession().account.id, b.account.id);
  }
});

test("ambiguous readback retains evidence and resolves exact pair without replay", async () => {
  const f = await fresh(), handle = await loginCandidate(f.vault);
  let published = false;
  f.local.fault = (stage, key) => {
    if (stage === "after-set" && key === "vortx.session.v1") published = true;
    if (stage === "get" && published) throw Error("synthetic denied read");
  };
  const historical = await f.vault.completeAuthAttempt(handle);
  assert.equal(historical.status, "uncertain");
  assert.equal(f.vault.pendingAuthPersistence(), true);
  assert.throws(() => f.vault.beginAuthAttempt("login"));
  f.local.fault = undefined; const writes = f.local.writes.length;
  assert.equal((await f.vault.resolveAuthPersistence(f.vault.createAuthSurface())).status, "persisted");
  assert.equal(f.local.writes.length, writes);
  assert.equal(await f.vault.completeAuthAttempt(handle), historical, "old token retains only its uncertain historical outcome");
  assert.equal(f.vault.authAttemptCurrent(handle), false);
});

test("retired attempt and delivered A-B-A cannot publish or revive a receipt", async () => {
  const f = await fresh(), a = session(); seedOwned(a);
  const lease = f.vault.createAuthSurface(), handle = await loginCandidate(f.vault, session("b"), lease);
  storageEvent(); storageEvent(); // equal final bytes do not imply the original generation
  const writes = f.local.writes.length;
  assert.equal((await f.vault.completeAuthAttempt(handle)).status, "retired");
  assert.equal(f.local.writes.length, writes);
  const next = await loginCandidate(f.vault, a);
  const result = await f.vault.completeAuthAttempt(next);
  storageEvent(); assert.equal(f.vault.authEffectCurrent(result.effect), false);
});

test("queued cancellation never steals held lock or performs unlocked writes", async () => {
  const f = await fresh(), lease = f.vault.createAuthSurface(), handle = await loginCandidate(f.vault, session(), lease);
  f.locks.held = true; const writes = f.local.writes.length;
  const pending = f.vault.completeAuthAttempt(handle);
  assert.equal(f.locks.queue.length, 1);
  f.vault.retireAuthSurface(lease);
  assert.equal((await pending).status, "retired");
  f.locks.grant(); assert.equal(f.local.writes.length, writes);
});

test("unavailable locks do not write; readable-empty memory completion is explicit", async () => {
  const f = await fresh(), handle = await loginCandidate(f.vault);
  navigator.locks = undefined;
  assert.equal((await f.vault.completeAuthAttempt(handle)).status, "unavailable");
  assert.equal(f.local.getItem("vortx.session.v1"), null);
  const result = f.vault.completeMemoryOnly(handle);
  assert.equal(result.status, "memory-only");
  assert.equal(f.vault.captureSessionOwnership(f.vault.sessionOwner().session)(), true);
  f.local.fault = () => { throw Error("synthetic denied"); };
  assert.equal(f.vault.captureSessionOwnership(f.vault.sessionOwner().session)(), false);
  assert.equal(f.vault.sessionOwner().mode, "blocked");
  assert.ok(f.vault.sessionOwner().session, "blocked is not guest");
});

test("failed logout stays retired with residual descriptor and can only conditionally clear its own bytes", async () => {
  const f = await fresh({ account: true }); await admit(f.vault, session(), f.account);
  const old = f.local.getItem("vortx.session.v1");
  f.local.fault = (stage) => { if (stage === "before-remove") throw Error("synthetic denial"); };
  const clear = f.account.signOut();
  assert.equal(f.account.currentSession(), null);
  assert.equal((await clear).status, "uncertain");
  assert.equal(f.local.getItem("vortx.session.v1"), old);
  storageEvent(); assert.equal(f.account.currentSession(), null);
  assert.equal(await f.account.ensureValidSession(), null);
  f.local.fault = undefined;
  assert.equal((await f.account.signOut()).status, "not-persisted");
});

test("blocked descriptor reads stop hydrate and writes without guest fallback", async () => {
  const f = await fresh({ account: true }), a = session(); await admit(f.vault, a, f.account);
  let requests = 0; globalThis.fetch = async () => { requests++; throw Error("must not reach transport"); };
  f.local.fault = () => { throw Error("synthetic denied"); };
  await f.account.hydrateFromAccount(a);
  await assert.rejects(f.vault.mutateSyncDoc(a, () => {}));
  assert.equal(requests, 0);
  assert.equal(f.account.currentSession().account.id, a.account.id);
});

test("irreversible request has material before dispatch; unknown/malformed responses never replay", async () => {
  for (const malformed of [false, true]) {
    const f = await fresh(), surface = f.vault.createAuthSurface();
    const handle = f.vault.beginAuthAttempt("register", surface); let requests = 0;
    globalThis.fetch = async () => {
      requests++;
      const held = f.vault.pendingAuthOperation();
      assert.equal(held.outcome, "unknown"); assert.equal(held.materialRetained, true); assert.equal(held.codeRetained, true);
      f.vault.retireAuthSurface(surface);
      if (malformed) return Response.json({ token: "synthetic-but-incomplete" });
      throw Error("synthetic response lost after dispatch");
    };
    await assert.rejects(f.vault.register("new@example.invalid", "synthetic-new", "synthetic-password", handle));
    assert.equal(f.vault.pendingAuthOperation().outcome, "unknown");
    assert.equal(f.vault.pendingAuthOperation().codeRetained, true);
    assert.throws(() => f.vault.beginAuthAttempt("register", f.vault.createAuthSurface()));
    assert.equal((await f.vault.resumeAuthOperation(f.vault.createAuthSurface())).status, "unavailable");
    assert.equal(requests, 1);
    assert.equal(f.vault.sessionOwner().session, null);
  }
});

test("accepted retired registration resumes the same result and recovery-code gate without another POST", async () => {
  const f = await fresh(), lease = f.vault.createAuthSurface(), handle = f.vault.beginAuthAttempt("register", lease);
  let requests = 0;
  globalThis.fetch = async () => {
    requests++; f.vault.retireAuthSurface(lease);
    return Response.json({ token: "synthetic-created", account: session("created").account });
  };
  await f.vault.register("created@example.invalid", "created", "synthetic-password", handle);
  assert.equal(f.vault.pendingAuthOperation().outcome, "accepted");
  assert.equal((await f.vault.completeAuthAttempt(handle)).status, "retired");
  const result = await f.vault.resumeAuthOperation(f.vault.createAuthSurface());
  assert.equal(result.status, "persisted"); assert.ok(f.vault.recoveryCodeFor(result.effect));
  assert.equal(requests, 1); assert.equal(f.vault.acknowledgeRecoveryCode(result.effect), true);
  assert.equal(f.vault.pendingAuthOperation(), null);
});

test("accepted reset survives proof-finalization failure without repeating its request", async () => {
  const f = await fresh(), handle = f.vault.beginAuthAttempt("reset");
  const original = crypto.subtle.digest; let posts = 0;
  globalThis.fetch = async (url) => {
    if (url.endsWith("/prelogin")) return Response.json({ kdfSalt: Buffer.alloc(16).toString("base64"), kdfIters: 210000 });
    posts++; return Response.json({ token: "synthetic-reset", account: session("reset").account });
  };
  crypto.subtle.digest = async () => { throw Error("synthetic proof failure"); };
  try { await assert.rejects(f.vault.resetComplete("reset@example.invalid", "123456", "synthetic-password", handle)); }
  finally { crypto.subtle.digest = original; }
  assert.equal(f.vault.pendingAuthOperation().outcome, "accepted");
  assert.equal(f.vault.pendingAuthOperation().proofReady, false);
  const result = await f.vault.resumeAuthOperation(f.vault.createAuthSurface());
  assert.equal(result.status, "persisted"); assert.equal(posts, 1);
  assert.equal(f.vault.pendingAuthOperation().proofReady, true);
});

test("subscriber failure cannot roll back acknowledged persistence", async () => {
  const f = await fresh({ account: true });
  let armed = false;
  f.account.subscribe(() => { if (armed) throw Error("synthetic subscriber"); }); armed = true;
  const handle = await loginCandidate(f.vault);
  const result = await f.account.adoptSession(handle);
  assert.equal(result.status, "persisted");
  assert.ok(f.vault.loadSession());
  assert.equal(await f.vault.completeAuthAttempt(handle), result);
});

test("post-crypto dispatch rechecks the exact original preimage without waiting for a storage event", async () => {
  for (const rival of [false, true]) {
    const f = await fresh(), a = session(); seedOwned(a);
    const lease = f.vault.createAuthSurface(), handle = f.vault.beginAuthAttempt("register", lease);
    const entered = deferred(), release = deferred(), original = crypto.subtle.deriveBits.bind(crypto.subtle);
    let held = false, posts = 0;
    crypto.subtle.deriveBits = async (...args) => { if (!held) { held = true; entered.resolve(); await release.promise; } return original(...args); };
    globalThis.fetch = async () => { posts++; return Response.json({ token: "synthetic-created", account: session("created").account }); };
    const pending = f.vault.register("created@example.invalid", "created", "synthetic-password", handle);
    const outcome = pending.then((value) => ({ value }), (error) => ({ error }));
    try {
      await entered.promise;
      assert.equal(f.vault.pendingAuthOperation().outcome, "not-sent");
      if (rival) f.local.setItem("vortx.session.v1", JSON.stringify({ token: "rival", account: session("rival").account }));
      release.resolve(); const settled = await outcome;
      assert.equal(posts, rival ? 0 : 1);
      if (rival) { assert.ok(settled.error); assert.equal(f.vault.pendingAuthOperation(), null); }
      else { assert.ok(settled.value); assert.equal(f.vault.pendingAuthOperation().outcome, "accepted"); }
    } finally { release.resolve(); crypto.subtle.deriveBits = original; await outcome; }
  }
});

test("one genuine handle owns exactly one preparation and the originally accepted code/key", async () => {
  for (const boundary of ["preparation", "response"]) {
    const f = await fresh(), handle = f.vault.beginAuthAttempt("register");
    const prepared = deferred(), responseEntered = deferred(), releaseCrypto = deferred(), releaseResponse = deferred();
    const original = crypto.subtle.deriveBits.bind(crypto.subtle); let first = true, posts = 0;
    crypto.subtle.deriveBits = async (...args) => {
      if (first && boundary === "preparation") { first = false; prepared.resolve(); await releaseCrypto.promise; }
      return original(...args);
    };
    globalThis.fetch = async () => { posts++; responseEntered.resolve(); await releaseResponse.promise; return Response.json({ token: "synthetic-created", account: session("created").account }); };
    const firstCall = f.vault.register("created@example.invalid", "created", "synthetic-password", handle);
    const firstOutcome = firstCall.then((value) => ({ value }), (error) => ({ error }));
    try {
      await (boundary === "preparation" ? prepared.promise : responseEntered.promise);
      const secondOutcome = f.vault.register("unsent@example.invalid", "unsent", "different-password", handle).then((value) => ({ value }), (error) => ({ error }));
      releaseCrypto.resolve(); await responseEntered.promise;
      assert.equal(posts, 1);
      releaseResponse.resolve(); const { value, error } = await firstOutcome;
      assert.equal(error, undefined);
      assert.match((await secondOutcome).error?.message ?? "", /already started|already sent/);
      const result = await f.vault.completeAuthAttempt(handle);
      assert.equal(result.status, "persisted");
      assert.equal(f.vault.recoveryCodeFor(result.effect), value.recoveryCode, "the code belongs to the accepted first preparation");
      assert.deepEqual(f.vault.loadSession().dataKey, value.session.dataKey);
      assert.equal(posts, 1);
    } finally { releaseCrypto.resolve(); releaseResponse.resolve(); crypto.subtle.deriveBits = original; await firstOutcome; }
  }
});

test("resumed admission never reactivates old tokens or retargets a held local commit", async () => {
  const f = await fresh(), oldSurface = f.vault.createAuthSurface(), old = f.vault.beginAuthAttempt("register", oldSurface);
  let posts = 0;
  globalThis.fetch = async () => { posts++; return Response.json({ token: "synthetic-created", account: session("created").account }); };
  await f.vault.register("created@example.invalid", "created", "synthetic-password", old);
  f.vault.retireAuthSurface(oldSurface);
  f.locks.held = true;
  const surface = f.vault.createAuthSurface(), resumed = f.vault.resumeAuthOperation(surface);
  assert.equal(f.locks.queue.length, 1);
  assert.equal(f.vault.authAttemptCurrent(old), false);
  assert.equal((await f.vault.completeAuthAttempt(old)).status, "retired");
  assert.equal((await f.vault.resumeAuthOperation(f.vault.createAuthSurface())).status, "unavailable");
  f.locks.grant(); const result = await resumed;
  assert.equal(result.status, "persisted"); assert.equal(f.vault.authEffectCurrent(result.effect), true);
  assert.equal((await f.vault.completeAuthAttempt(old)).status, "retired");
  await assert.rejects(f.vault.register("again@example.invalid", "again", "different-password", old), /retired/);
  assert.equal(posts, 1);
});

test("resume proof await rechecks retained admission and does not revive a delivered ABA", async () => {
  const f = await fresh(), handle = f.vault.beginAuthAttempt("reset");
  const original = crypto.subtle.digest.bind(crypto.subtle); let posts = 0;
  globalThis.fetch = async (url) => url.endsWith("/prelogin")
    ? Response.json({ kdfSalt: Buffer.alloc(16).toString("base64"), kdfIters: 210000 })
    : (posts++, Response.json({ token: "synthetic-reset", account: session("reset").account }));
  crypto.subtle.digest = async () => { throw Error("synthetic first proof failure"); };
  try { await assert.rejects(f.vault.resetComplete("reset@example.invalid", "123456", "synthetic-password", handle)); }
  finally { crypto.subtle.digest = original; }
  const entered = deferred(), release = deferred();
  crypto.subtle.digest = async (...args) => { entered.resolve(); await release.promise; return original(...args); };
  const pending = f.vault.resumeAuthOperation(f.vault.createAuthSurface());
  try {
    await entered.promise; storageEvent(); storageEvent(); release.resolve();
    assert.equal((await pending).status, "retired");
    assert.equal(f.local.getItem("vortx.session.v1"), null);
    assert.equal(f.vault.pendingAuthOperation().outcome, "accepted"); assert.equal(posts, 1);
    assert.equal(f.vault.authAttemptCurrent(handle), false);
  } finally { release.resolve(); crypto.subtle.digest = original; await pending; }
});

test("household consent stops on blocked authority and stays retired after A bytes return", async () => {
  for (const failure of ["foreign", "denied"]) {
    const f = await fresh({ account: true }), a = session(); await admit(f.vault, a, f.account);
    const household = await import("./household.ts" + f.query), entered = deferred(), response = deferred();
    const before = [f.local.getItem("vortx.session.v1"), f.tab.getItem("vortx.dk.v2")];
    let calls = 0;
    globalThis.fetch = async (url) => {
      calls++; assert.ok(url.endsWith("/v1/household")); entered.resolve(); return response.promise;
    };
    const pending = household.acceptShared("content"); await entered.promise;
    if (failure === "foreign") f.local.setItem("vortx.session.v1", JSON.stringify({ token: "rival", account: session("rival").account }));
    else f.local.fault = (stage, key) => { if (stage === "get" && key === "vortx.session.v1") throw Error("synthetic denial"); };
    storageEvent();
    assert.equal(f.account.currentSession().account.id, a.account.id, "known blocked owner is retained, not guest");
    assert.equal(f.vault.sessionOwner().mode, "blocked");
    f.local.fault = undefined; f.local.setItem("vortx.session.v1", before[0]); storageEvent();
    const writes = f.local.writes.length;
    response.resolve(Response.json({ household: { hasBlob: true, hhKeyVersion: 1 } }));
    assert.equal(await pending, false); assert.equal(calls, 1); assert.equal(f.local.writes.length, writes);
    assert.equal(f.tab.getItem("vortx.dk.v2"), before[1]);
  }
});

test("endpoint-specific no-change responses release only their own slot; unfamiliar failures stay unknown", async () => {
  const cases = [
    ["register", [[400, "invalid_email"], [400, "invalid_username"], [400, "bad_request"], [409, "email_taken"], [409, "username_taken"]]],
    ["recover", [[400, "bad_request"], [401, "invalid_recovery"]]],
    ["reset", [[400, "bad_request"], [401, "invalid_code"]]],
    ["password", [[400, "bad_request"], [401, "unauthorized"], [401, "invalid_credentials"]]],
    ["activate", [[400, "no_pending"], [401, "unauthorized"], [401, "invalid_code"]]],
    ["disable", [[400, "not_enabled"], [401, "unauthorized"], [401, "invalid_code"]]],
    ["approve", [[404, null], [409, null], [410, null], [400, "bad_request"], [401, "unauthorized"]]],
  ];
  const salt = new Uint8Array(16), password = "synthetic-password", recoveryCode = "VX-SYNTHETIC";
  for (const [kind, supported] of cases) {
    for (const [status, error, rejected = true] of [...supported, [supported[0][0], "future_unrecognized", false], [503, "unavailable", false], [200, "malformed_success", false]]) {
      const f = await fresh(), a = session();
      if (["password", "activate", "disable", "approve"].includes(kind)) await admit(f.vault, a);
      let wrappedRecovery, publicKey;
      if (kind === "recover") {
        const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(recoveryCode), "PBKDF2", false, ["deriveBits"]);
        const raw = new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: 210000, hash: "SHA-256" }, key, 256));
        wrappedRecovery = await f.vault.__syncCryptoTestHooks.sealDocument(raw, a.dataKey, a.account.id, 0, false);
      }
      if (kind === "approve") publicKey = (await f.vault.newHouseholdEphemeral()).publicKeyB64url;
      let posts = 0;
      globalThis.fetch = async (url) => {
        if (url.endsWith("/prelogin")) return Response.json({ kdfSalt: Buffer.from(salt).toString("base64"), kdfIters: 210000 });
        if (url.endsWith("/recover-start")) return Response.json({ kdfSalt: Buffer.from(salt).toString("base64"), kdfIters: 210000, wrappedKeyRecovery: wrappedRecovery });
        posts++; return error === null ? new Response(null, { status }) : Response.json({ error }, { status });
      };
      const invoke = () => {
        if (kind === "register") return f.vault.register("a@example.invalid", "synthetic", password);
        if (kind === "recover") return f.vault.recover("a@example.invalid", recoveryCode, password);
        if (kind === "reset") return f.vault.resetComplete("a@example.invalid", "123456", password);
        if (kind === "password") return f.vault.changePassword(a, password, password);
        if (kind === "activate") return f.vault.activate2fa(a, "123456");
        if (kind === "disable") return f.vault.disable2fa(a, "123456");
        return f.vault.qrApprove(a, "SYNTHETIC", publicKey);
      };
      // Empty success is endpoint-valid for metadata/QR operations; malformed-success belongs only
      // to endpoints that require a validated token/account, not to those no-body success contracts.
      if (status === 200 && ["activate", "disable", "approve"].includes(kind)) continue;
      await assert.rejects(invoke());
      assert.equal(posts, 1, kind + ":" + status + ":" + error);
      if (rejected) {
        assert.equal(f.vault.pendingAuthOperation(), null);
        assert.doesNotThrow(() => f.vault.beginAuthAttempt("register"));
      } else {
        assert.equal(f.vault.pendingAuthOperation().outcome, "unknown");
        assert.equal((await f.vault.resumeAuthOperation(f.vault.createAuthSurface())).status, "unavailable");
        assert.throws(() => f.vault.beginAuthAttempt("register"));
        assert.equal(posts, 1);
      }
    }
  }
});

test("one original lock deadline cancels queued admission but cannot revoke granted work", async () => {
  for (const grant of [false, true]) {
    const f = await fresh(), handle = await loginCandidate(f.vault);
    const schedule = [], originalSet = globalThis.setTimeout, originalClear = globalThis.clearTimeout;
    globalThis.setTimeout = (run, delay) => { const timer = { run, delay, cleared: false }; schedule.push(timer); return timer; };
    globalThis.clearTimeout = (timer) => { timer.cleared = true; };
    f.locks.held = true;
    const pending = f.vault.completeAuthAttempt(handle);
    try {
      assert.equal(schedule.length, 1); assert.equal(schedule[0].delay, 10000);
      if (grant) {
        f.locks.grant(); assert.equal(schedule[0].cleared, true);
        const result = await pending; assert.equal(result.status, "persisted");
        schedule[0].run(); assert.equal(await f.vault.completeAuthAttempt(handle), result);
      } else {
        schedule[0].run(); assert.equal((await pending).status, "unavailable");
        assert.equal(f.locks.queue.length, 0); f.locks.grant();
        assert.equal(f.local.getItem("vortx.session.v1"), null); assert.equal(f.tab.getItem("vortx.dk.v2"), null);
      }
    } finally { globalThis.setTimeout = originalSet; globalThis.clearTimeout = originalClear; }
  }
});

test("conditional compensation never overwrites rival tab bytes and leaves ambiguity retained", async () => {
  const f = await fresh(), a = session(); seedOwned(a);
  const handle = await loginCandidate(f.vault, session("replacement"));
  const rivalKey = JSON.stringify({ schemaVersion: 99, future: "retain-rival" });
  f.local.fault = (stage, key) => {
    if (stage === "before-set" && key === "vortx.session.v1") {
      f.tab.setItem("vortx.dk.v2", rivalKey); throw Error("synthetic rival during publication");
    }
  };
  assert.equal((await f.vault.completeAuthAttempt(handle)).status, "uncertain");
  f.local.fault = undefined;
  assert.equal(f.tab.getItem("vortx.dk.v2"), rivalKey);
  assert.equal(f.vault.pendingAuthPersistence(), true);
  assert.equal((await f.vault.resolveAuthPersistence(f.vault.createAuthSurface())).status, "uncertain");
  assert.equal(f.tab.getItem("vortx.dk.v2"), rivalKey);
});

test("identical already-durable candidate remains persisted even when a redundant write throws", async () => {
  const f = await fresh(), a = session(); seedOwned(a);
  const handle = await loginCandidate(f.vault, a);
  f.tab.fault = (phase) => { if (phase === "before-set") throw Error("synthetic no-op quota"); };
  const result = await f.vault.completeAuthAttempt(handle);
  assert.equal(result.status, "persisted"); assert.deepEqual(f.vault.loadSession(), a);
  assert.equal(await f.vault.completeAuthAttempt(handle), result);
});

test("password and QR preparation cannot send after their captured owner changes", async () => {
  for (const kind of ["password", "qr"]) {
    const f = await fresh(), a = session(); await admit(f.vault, a);
    const entered = deferred(), release = deferred(); let posts = 0;
    const method = kind === "password" ? "deriveBits" : "generateKey";
    const original = crypto.subtle[method].bind(crypto.subtle);
    const publicKey = kind === "qr" ? (await f.vault.newHouseholdEphemeral()).publicKeyB64url : undefined;
    let first = true;
    crypto.subtle[method] = async (...args) => { if (first) { first = false; entered.resolve(); await release.promise; } return original(...args); };
    globalThis.fetch = async (url) => {
      if (url.endsWith("/prelogin")) return Response.json({ kdfSalt: Buffer.alloc(16).toString("base64"), kdfIters: 210000 });
      posts++; return Response.json({ token: "should-not-be-used" });
    };
    const work = kind === "password" ? f.vault.changePassword(a, "synthetic-password", "new-password") : f.vault.qrApprove(a, "SYNTHETIC", publicKey);
    const outcome = work.then((value) => ({ value }), (error) => ({ error }));
    try {
      await entered.promise;
      f.local.setItem("vortx.session.v1", JSON.stringify({ token: "rival", account: session("rival").account }));
      release.resolve(); assert.ok((await outcome).error);
      assert.equal(posts, 0); assert.equal(f.vault.pendingAuthOperation(), null);
      assert.equal(JSON.parse(f.local.getItem("vortx.session.v1")).token, "rival");
    } finally { release.resolve(); crypto.subtle[method] = original; await outcome; }
  }
});

test("a dispatch-observed mismatch permanently retires older permissions after A bytes return without an event", async () => {
  for (const failure of ["foreign", "denied"]) {
    const f = await fresh(), a = session(), receipt = await admit(f.vault, a);
    const owns = f.vault.captureSessionOwnership(a), before = f.local.getItem("vortx.session.v1");
    const tabBefore = f.tab.getItem("vortx.dk.v2"), revision = f.vault.sessionOwner().revision;
    f.local.setItem("vortx.syncVer.synthetic-preserved", "100");
    assert.equal(owns(), true); assert.equal(f.vault.authEffectCurrent(receipt.effect), true);
    const handle = f.vault.beginAuthAttempt("register"), entered = deferred(), release = deferred();
    const original = crypto.subtle.deriveBits.bind(crypto.subtle); let held = false, posts = 0;
    crypto.subtle.deriveBits = async (...args) => { if (!held) { held = true; entered.resolve(); await release.promise; } return original(...args); };
    globalThis.fetch = async () => { posts++; return Response.json({ token: "should-not-be-used", account: session("rival").account }); };
    const result = f.vault.register("new@example.invalid", "new", "synthetic-password", handle)
      .then((value) => ({ value }), (error) => ({ error }));
    try {
      await entered.promise;
      if (failure === "foreign") f.local.setItem("vortx.session.v1", JSON.stringify({ token: "rival", account: session("rival").account }));
      else f.local.fault = (stage, key) => { if (stage === "get" && key === "vortx.session.v1") throw Error("synthetic denied read"); };
      const writes = [f.local.writes.length, f.tab.writes.length];
      release.resolve(); assert.ok((await result).error); assert.equal(posts, 0);
      assert.deepEqual([f.local.writes.length, f.tab.writes.length], writes, "denial does not persist, compensate or clear");
      assert.ok(f.vault.sessionOwner().revision > revision);
      assert.equal(f.vault.sessionOwner().mode, "blocked");
      assert.equal(f.vault.sessionOwner().session.account.id, a.account.id, "known A is retained");
      f.local.fault = undefined;
      if (failure === "foreign") f.local.setItem("vortx.session.v1", before);
      // Intentionally NO storage event: this regression is an observed-dispatch witness,
      // not a claim that undelivered and unobserved ABA can be detected.
      assert.equal(f.vault.loadSession().account.id, a.account.id, "pure inspection can see restored A bytes");
      assert.equal(owns(), false);
      assert.equal(f.vault.authEffectCurrent(receipt.effect), false);
      assert.equal(f.vault.authAttemptCurrent(handle), false);
      assert.throws(() => f.vault.beginAuthAttempt("login"));
      assert.equal(f.vault.sessionOwner().mode, "blocked");
      assert.equal(f.tab.getItem("vortx.dk.v2"), tabBefore);
      assert.equal(f.local.getItem("vortx.syncVer.synthetic-preserved"), "100");
      assert.equal(posts, 0);
    } finally { release.resolve(); f.local.fault = undefined; crypto.subtle.deriveBits = original; await result; }
  }
});

function ownerEvidence(f, value, receipt) {
  const proof = { value, receipt, owns: f.vault.captureSessionOwnership(value), revision: f.vault.sessionOwner().revision,
    raw: f.local.getItem("vortx.session.v1"), key: f.tab.getItem("vortx.dk.v2") };
  assert.equal(proof.owns(), true); assert.equal(f.vault.authEffectCurrent(receipt.effect), true);
  return proof;
}
function assertWitnessRetired(f, proof, handle) {
  assert.ok(f.vault.sessionOwner().revision > proof.revision);
  assert.equal(f.vault.sessionOwner().mode, "blocked");
  assert.equal(f.vault.sessionOwner().session.account.id, proof.value.account.id, "known owner survives the witness");
  assert.equal(proof.owns(), false); assert.equal(f.vault.authEffectCurrent(proof.receipt.effect), false);
  if (handle) assert.equal(f.vault.authAttemptCurrent(handle), false);
}
function restorePairWithoutEvent(f, proof) {
  f.local.fault = f.tab.fault = undefined;
  if (proof.raw === null) f.local.removeItem("vortx.session.v1"); else f.local.setItem("vortx.session.v1", proof.raw);
  if (proof.key === null) f.tab.removeItem("vortx.dk.v2"); else f.tab.setItem("vortx.dk.v2", proof.key);
  // Deliberately no storage event: only an observation made by this realm retires these permissions.
}

test("admission and explicit migration latch their first observed owner pair without a storage event", async () => {
  for (const boundary of ["begin", "migrate"]) for (const failure of ["blocked", "denied", "owned-rival", "empty"]) {
    const f = await fresh(), a = session(), receipt = await admit(f.vault, a), proof = ownerEvidence(f, a, receipt);
    const old = f.vault.beginAuthAttempt("login");
    if (boundary === "migrate") {
      const writes = [f.local.writes.length, f.tab.writes.length];
      assert.equal((await f.vault.migrateSession()).status, "unavailable", "owned nonlegacy remains a no-op");
      assert.deepEqual([f.local.writes.length, f.tab.writes.length], writes);
      assert.equal(f.vault.sessionOwner().revision, proof.revision); assert.equal(proof.owns(), true);
    }
    if (failure === "denied") f.local.fault = (phase) => { if (phase === "get") throw Error("synthetic denied"); };
    else if (failure === "owned-rival") seedOwned(session("rival", 8));
    else if (failure === "empty") { f.local.removeItem("vortx.session.v1"); f.tab.removeItem("vortx.dk.v2"); }
    else f.local.setItem("vortx.session.v1", JSON.stringify({ token: "rival", account: session("rival").account }));
    const writes = [f.local.writes.length, f.tab.writes.length];
    f.vault.loadSession(); assert.equal(f.vault.sessionOwner().revision, proof.revision, "load itself is pure");
    if (boundary === "begin") assert.throws(() => f.vault.beginAuthAttempt("login"));
    else assert.equal((await f.vault.migrateSession()).status, "unavailable");
    assert.deepEqual([f.local.writes.length, f.tab.writes.length], writes);
    restorePairWithoutEvent(f, proof);
    assert.equal(f.vault.loadSession().account.id, a.account.id, "load remains pure despite blocked authority");
    assertWitnessRetired(f, proof, old);
    assert.throws(() => f.vault.beginAuthAttempt("login"));
  }
  for (const schedule of ["known-A-first-B-then-A", "known-A-first-A-then-B", "guest-first-A-then-B"]) {
    const f = await fresh(), a = session("legacy-a"), b = session("legacy-b", 8);
    const legacy = (value) => JSON.stringify({ token: value.token, account: value.account,
      dataKey: Buffer.from(value.dataKey).toString("base64"), future: { retain: value.account.id } });
    const rawA = legacy(a), rawB = legacy(b), guest = schedule.startsWith("guest");
    if (!guest) f.local.setItem("vortx.session.v1", rawA);
    f.vault.startSessionAuthority();
    if (guest) {
      const writes = f.local.writes.length;
      assert.equal((await f.vault.migrateSession()).status, "unavailable", "true guest empty migration is a no-op");
      assert.equal(f.local.writes.length, writes); assert.equal(f.vault.sessionOwner().mode, "guest");
    }
    const owns = guest ? undefined : f.vault.captureSessionOwnership(a);
    if (owns) assert.equal(owns(), true);
    const old = f.vault.beginAuthAttempt("login"), revision = f.vault.sessionOwner().revision;
    const firstB = schedule.includes("first-B");
    f.local.values.set("vortx.session.v1", firstB ? rawB : rawA);
    const rawGet = f.local.getItem.bind(f.local); let reads = 0;
    f.local.getItem = (key) => {
      const value = rawGet(key);
      if (key === "vortx.session.v1" && ++reads === 2) f.local.values.set(key, firstB ? rawA : rawB);
      return value; // first coherent inspection sees one pair; the next admission sees the other.
    };
    const writes = [f.local.writes.length, f.tab.writes.length];
    const result = await f.vault.migrateSession().then((value) => ({ value }), (error) => ({ error }));
    f.local.getItem = rawGet;
    if (firstB) assert.equal(result.value?.status, "unavailable");
    else if (guest) assert.equal(result.value?.status, "retired", "first candidate cannot attach to second preimage");
    else assert.match(result.error?.message ?? "", /ownership changed/);
    assert.deepEqual([f.local.writes.length, f.tab.writes.length], writes, "no candidate publication or migration writes");
    if (guest) f.local.values.delete("vortx.session.v1"); else f.local.values.set("vortx.session.v1", rawA);
    assert.ok(f.vault.sessionOwner().revision > revision); assert.equal(f.vault.sessionOwner().mode, "blocked");
    assert.equal(f.vault.sessionOwner().session?.account.id ?? null, guest ? null : a.account.id);
    if (owns) assert.equal(owns(), false);
    assert.equal(f.vault.authAttemptCurrent(old), false);
  }
});

test("completion validates captured predecessor before metadata derivation or lock queueing", async () => {
  for (const failure of ["candidate-pair", "denied"]) {
    const f = await fresh(), a = session(), b = session("b", 8);
    seedOwned(a);
    f.local.setItem("vortx.session.v1", JSON.stringify({ ...JSON.parse(f.local.getItem("vortx.session.v1")), privateA: { retain: true } }));
    f.tab.setItem("vortx.dk.v2", JSON.stringify({ ...JSON.parse(f.tab.getItem("vortx.dk.v2")), privateAKey: [1, 2] }));
    const receipt = await admit(f.vault, a), proof = ownerEvidence(f, a, receipt), handle = await loginCandidate(f.vault, b);
    if (failure === "candidate-pair") seedOwned(b);
    else f.local.fault = (phase) => { if (phase === "get") throw Error("synthetic denied"); };
    f.locks.held = true;
    const writes = [f.local.writes.length, f.tab.writes.length], requests = f.locks.requests.length;
    const pending = f.vault.completeAuthAttempt(handle);
    // A is restored before any possible grant. It must not turn the observed B into A metadata for B.
    restorePairWithoutEvent(f, proof);
    f.locks.grant();
    assert.equal((await pending).status, "retired");
    assert.equal(f.locks.requests.length, requests); assert.equal(f.locks.queue.length, 0);
    assert.deepEqual([f.local.writes.length, f.tab.writes.length], [writes[0] + 1, writes[1] + 1], "only explicit fixture restoration wrote");
    assert.equal(f.local.getItem("vortx.session.v1"), proof.raw); assert.equal(f.tab.getItem("vortx.dk.v2"), proof.key);
    assertWitnessRetired(f, proof, handle);
  }
});

test("metadata comes from the proven predecessor only: same-owner preserved, other-owner excluded", async () => {
  for (const same of [true, false]) {
    const f = await fresh(), a = session(); seedOwned(a);
    f.local.setItem("vortx.session.v1", JSON.stringify({ ...JSON.parse(f.local.getItem("vortx.session.v1")), privateA: { nested: ["keep"] } }));
    f.tab.setItem("vortx.dk.v2", JSON.stringify({ ...JSON.parse(f.tab.getItem("vortx.dk.v2")), privateAKey: { nested: ["keep"] } }));
    const candidate = same ? { ...a, token: "synthetic-refreshed" } : session("b", 8);
    const handle = await loginCandidate(f.vault, candidate);
    assert.equal((await f.vault.completeAuthAttempt(handle)).status, "persisted");
    const raw = JSON.parse(f.local.getItem("vortx.session.v1")), key = JSON.parse(f.tab.getItem("vortx.dk.v2"));
    if (same) { assert.deepEqual(raw.privateA, { nested: ["keep"] }); assert.deepEqual(key.privateAKey, { nested: ["keep"] }); }
    else { assert.equal(Object.hasOwn(raw, "privateA"), false); assert.equal(Object.hasOwn(key, "privateAKey"), false); }
    assert.equal(raw.account.unknown.keep[1].future, true, "candidate's own unknown account metadata survives");
  }
});

test("lock-entry ownership witnesses notify only after the lock and stay retired after restoration", async () => {
  for (const failure of ["foreign", "denied"]) {
    const f = await fresh(), a = session(), receipt = await admit(f.vault, a), proof = ownerEvidence(f, a, receipt);
    const handle = await loginCandidate(f.vault, session("b", 8));
    let inLock = false; const notifications = [], request = f.locks.request.bind(f.locks);
    f.locks.request = (name, options, callback) => request(name, options, () => { inLock = true; try { return callback(); } finally { inLock = false; } });
    f.vault.onSessionAuthority(() => { notifications.push(inLock); });
    f.locks.held = true; const pending = f.vault.completeAuthAttempt(handle);
    assert.equal(f.locks.queue.length, 1);
    if (failure === "foreign") seedOwned(session("rival", 9));
    else f.local.fault = (phase) => { if (phase === "get") throw Error("synthetic denied"); };
    const writes = [f.local.writes.length, f.tab.writes.length];
    f.locks.grant(); assert.equal((await pending).status, "retired");
    assert.deepEqual(notifications, [false]); assert.deepEqual([f.local.writes.length, f.tab.writes.length], writes);
    restorePairWithoutEvent(f, proof); assertWitnessRetired(f, proof, handle);
  }
});

test("staged/readback witnesses preserve compensation but not authority; quota alone is not a witness", async () => {
  for (const failure of ["descriptor", "tab-key", "denied", "readback-key", "key-quota", "head-quota"]) {
    const f = await fresh(), a = session(), receipt = await admit(f.vault, a), proof = ownerEvidence(f, a, receipt);
    const handle = f.vault.beginAuthAttempt("register"); let posts = 0;
    globalThis.fetch = async () => { posts++; return Response.json({ token: "synthetic-created", account: session("created").account }); };
    const accepted = await f.vault.register("created@example.invalid", "created", "synthetic-password", handle);
    const retained = f.vault.pendingAuthOperation();
    let staged = false, observed = false, inLock = false, readback = false;
    const notifications = [], request = f.locks.request.bind(f.locks);
    f.locks.request = (name, options, callback) => request(name, options, () => { inLock = true; try { return callback(); } finally { inLock = false; } });
    f.vault.onSessionAuthority(() => { notifications.push(inLock); });
    const rawGet = f.local.getItem.bind(f.local), keyGet = f.tab.getItem.bind(f.tab);
    f.tab.fault = (phase, key) => {
      if (key !== "vortx.dk.v2") return;
      if (phase === "before-set" && failure === "key-quota") throw Error("synthetic quota");
      if (phase === "after-set" && !staged) {
        staged = true;
        if (failure === "descriptor") f.local.values.set("vortx.session.v1", JSON.stringify({ token: "rival", account: session("rival").account }));
      }
    };
    f.local.fault = (phase, key) => {
      if (phase !== "before-set" || key !== "vortx.session.v1") return;
      if (failure === "head-quota") throw Error("synthetic quota");
      if (failure === "readback-key") {
        readback = true; f.tab.values.set("vortx.dk.v2", JSON.stringify({ schemaVersion: 99, future: "rival" }));
        throw Error("synthetic publication failure with rival tab slot");
      }
    };
    f.local.getItem = (key) => {
      const value = rawGet(key);
      if (staged && !observed && key === "vortx.session.v1" && failure === "descriptor") {
        observed = true; f.local.values.set(key, proof.raw); return value; // B was read; A returns before classification.
      }
      return value;
    };
    f.tab.getItem = (key) => {
      const value = keyGet(key);
      if (readback && !observed && key === "vortx.dk.v2" && failure === "readback-key") {
        observed = true; f.tab.values.set(key, proof.key); return value; // readback sees rival, next compensation read sees A.
      }
      if (staged && !observed && key === "vortx.dk.v2" && (failure === "tab-key" || failure === "denied")) {
        observed = true;
        if (failure === "denied") throw Error("synthetic denied staged read");
        return "synthetic-rival-tab-key"; // the next read sees our staged slot again
      }
      return value;
    };
    const result = await f.vault.completeAuthAttempt(handle);
    f.local.getItem = rawGet; f.tab.getItem = keyGet; f.local.fault = f.tab.fault = undefined;
    assert.equal(result.status, "not-persisted");
    assert.equal(f.local.getItem("vortx.session.v1"), proof.raw); assert.equal(f.tab.getItem("vortx.dk.v2"), proof.key);
    assert.deepEqual(f.vault.pendingAuthOperation(), retained); assert.equal(posts, 1);
    assert.equal(f.vault.pendingAuthOperation().codeRetained, true); assert.ok(accepted.recoveryCode);
    assert.equal(f.vault.pendingAuthPersistence(), false, "exact compensated predecessor is definite nonpublication");
    if (failure.endsWith("quota")) {
      assert.equal(observed, false); assert.deepEqual(notifications, []);
      assert.equal(f.vault.sessionOwner().revision, proof.revision); assert.equal(proof.owns(), true);
      assert.equal(f.vault.authEffectCurrent(receipt.effect), true); assert.equal(f.vault.authAttemptCurrent(handle), true);
    } else {
      assert.equal(observed, true); assert.deepEqual(notifications, [false]); assertWitnessRetired(f, proof, handle);
      assert.equal(f.vault.recoveryCodeFor(receipt.effect), null);
    }
  }
});

test("explicit memory completion latches nonempty or denied storage without turning known memory owner into guest", async () => {
  for (const failure of ["foreign", "denied"]) {
    const f = await fresh(), a = session(), first = await loginCandidate(f.vault, a);
    const receipt = f.vault.completeMemoryOnly(first), proof = ownerEvidence(f, a, receipt);
    const handle = await loginCandidate(f.vault, session("b", 8));
    if (failure === "foreign") seedOwned(session("rival", 9));
    else f.local.fault = (phase) => { if (phase === "get") throw Error("synthetic denied"); };
    const writes = [f.local.writes.length, f.tab.writes.length];
    assert.equal(f.vault.completeMemoryOnly(handle).status, "unavailable");
    assert.deepEqual([f.local.writes.length, f.tab.writes.length], writes);
    restorePairWithoutEvent(f, proof); assert.equal(f.vault.loadSession(), null);
    assertWitnessRetired(f, proof, handle); assert.throws(() => f.vault.completeMemoryOnly(handle));
  }
});

test("resume latches invalid or unmatched reads but accepts the explicitly allowed accepted-candidate preimage", async () => {
  for (const failure of ["blocked", "denied", "owned-rival", "accepted-candidate"]) {
    const f = await fresh(), a = session(), receipt = await admit(f.vault, a), proof = ownerEvidence(f, a, receipt);
    const oldSurface = f.vault.createAuthSurface(), handle = f.vault.beginAuthAttempt("register", oldSurface);
    let posts = 0;
    globalThis.fetch = async () => { posts++; return Response.json({ token: "synthetic-created", account: session("created").account }); };
    const accepted = await f.vault.register("created@example.invalid", "created", "synthetic-password", handle);
    f.vault.retireAuthSurface(oldSurface);
    if (failure === "accepted-candidate") seedOwned(accepted.session);
    else if (failure === "owned-rival") seedOwned(session("rival", 9));
    else if (failure === "blocked") f.local.setItem("vortx.session.v1", JSON.stringify({ token: "rival", account: session("rival").account }));
    else f.local.fault = (phase) => { if (phase === "get") throw Error("synthetic denied"); };
    const writes = [f.local.writes.length, f.tab.writes.length];
    const result = await f.vault.resumeAuthOperation(f.vault.createAuthSurface());
    assert.equal(posts, 1); assert.equal(f.vault.authAttemptCurrent(handle), false);
    assert.equal(f.vault.pendingAuthOperation().outcome, "accepted");
    assert.equal(f.vault.pendingAuthOperation().codeRetained, true);
    if (failure === "accepted-candidate") {
      assert.equal(result.status, "persisted"); assert.equal(f.vault.recoveryCodeFor(result.effect), accepted.recoveryCode);
      assert.deepEqual(f.vault.loadSession().dataKey, accepted.session.dataKey);
      assert.equal((await f.vault.completeAuthAttempt(handle)).status, "retired");
    } else {
      assert.equal(result.status, failure === "owned-rival" ? "retired" : "unavailable");
      assert.deepEqual([f.local.writes.length, f.tab.writes.length], writes);
      restorePairWithoutEvent(f, proof); assertWitnessRetired(f, proof, handle);
      assert.equal((await f.vault.resumeAuthOperation(f.vault.createAuthSurface())).status, "unavailable");
      assert.equal(posts, 1);
    }
  }
});

test("resume post-proof ownership witness retires A without replay or loss of accepted reset proof", async () => {
  for (const failure of ["foreign", "denied"]) {
    const f = await fresh(), a = session(), receipt = await admit(f.vault, a), proof = ownerEvidence(f, a, receipt);
    f.local.setItem("vortx.syncVer.synthetic-preserved", "100");
    const handle = f.vault.beginAuthAttempt("reset"), original = crypto.subtle.digest.bind(crypto.subtle); let posts = 0;
    globalThis.fetch = async (url) => url.endsWith("/prelogin")
      ? Response.json({ kdfSalt: Buffer.alloc(16).toString("base64"), kdfIters: 210000 })
      : (posts++, Response.json({ token: "synthetic-reset", account: session("reset").account }));
    crypto.subtle.digest = async () => { throw Error("synthetic first proof failure"); };
    try { await assert.rejects(f.vault.resetComplete("reset@example.invalid", "123456", "synthetic-password", handle)); }
    finally { crypto.subtle.digest = original; }
    const entered = deferred(), release = deferred();
    crypto.subtle.digest = async (...args) => { entered.resolve(); await release.promise; return original(...args); };
    const pending = f.vault.resumeAuthOperation(f.vault.createAuthSurface());
    try {
      await entered.promise;
      if (failure === "foreign") seedOwned(session("rival", 9));
      else f.local.fault = (phase, key) => { if (phase === "get" && key === "vortx.session.v1") throw Error("synthetic denied"); };
      release.resolve(); assert.equal((await pending).status, "retired");
      assert.equal(f.vault.pendingAuthOperation().outcome, "accepted");
      assert.equal(f.vault.pendingAuthOperation().proofReady, true);
      assert.equal(f.vault.pendingAuthOperation().codeRetained, true);
      assert.equal([...f.local.values.keys()].filter((key) => key.startsWith("vortx.syncGeneration.v1.")).length, 1, "original accepted reset proof remains");
      restorePairWithoutEvent(f, proof); assertWitnessRetired(f, proof, handle);
      assert.equal(f.local.getItem("vortx.syncVer.synthetic-preserved"), "100");
      assert.equal((await f.vault.resumeAuthOperation(f.vault.createAuthSurface())).status, "unavailable");
      assert.equal(posts, 1);
    } finally { release.resolve(); f.local.fault = undefined; crypto.subtle.digest = original; await pending; }
  }
});

test("torn descriptor confirmation stays visible to admission while pure load does not mutate authority", async () => {
  for (const boundary of ["begin", "complete"]) {
    const f = await fresh(), a = session(), receipt = await admit(f.vault, a), proof = ownerEvidence(f, a, receipt);
    const handle = boundary === "complete" ? await loginCandidate(f.vault, session("candidate", 8)) : f.vault.beginAuthAttempt("login");
    const rawGet = f.local.getItem.bind(f.local), rival = JSON.stringify({ token: "rival", account: session("rival").account });
    let armed = false, reads = 0; const notifications = [];
    f.vault.onSessionAuthority(() => { notifications.push(f.vault.sessionOwner().mode); });
    f.local.getItem = (key) => {
      const value = rawGet(key);
      if (armed && key === "vortx.session.v1") {
        reads++;
        if (reads === 1) f.local.values.set(key, rival); // A was read; key A is next.
        else if (reads === 2) { f.local.values.set(key, proof.raw); armed = false; } // confirmation returns B; A is already restored.
      }
      return value;
    };
    const writes = [f.local.writes.length, f.tab.writes.length], requests = f.locks.requests.length;
    try {
      assert.equal(f.vault.loadSession().account.id, a.account.id, "same-pair inspection still works");
      armed = true; reads = 0;
      assert.equal(f.vault.loadSession(), null, "pure load refuses torn A/keyA/confirmB instead of retrying into A");
      assert.equal(reads, 2); assert.equal(f.local.getItem("vortx.session.v1"), proof.raw);
      assert.equal(f.vault.sessionOwner().revision, proof.revision); assert.deepEqual(notifications, []);
      assert.equal(proof.owns(), true); assert.equal(f.vault.authEffectCurrent(receipt.effect), true);
      armed = true; reads = 0;
      if (boundary === "begin") assert.throws(() => f.vault.beginAuthAttempt("login"));
      else assert.equal((await f.vault.completeAuthAttempt(handle)).status, "retired");
      assert.equal(reads, 2); assert.equal(f.locks.requests.length, requests);
      assert.equal(f.local.getItem("vortx.session.v1"), proof.raw); assert.equal(f.tab.getItem("vortx.dk.v2"), proof.key);
      assert.deepEqual([f.local.writes.length, f.tab.writes.length], writes, "only adversarial fixture values changed; module wrote nothing");
      assert.deepEqual(notifications, ["blocked"]); assertWitnessRetired(f, proof, handle);
    } finally { f.local.getItem = rawGet; f.local.values.set("vortx.session.v1", proof.raw); }
  }
});
