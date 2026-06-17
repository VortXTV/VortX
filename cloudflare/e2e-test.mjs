import { webcrypto as wc } from "node:crypto";
const subtle = wc.subtle;
const API = "https://api.vortx.tv";
const te = new TextEncoder(), td = new TextDecoder();
const enc = (s) => te.encode(s);
const b64 = (u8) => Buffer.from(u8).toString("base64");
const unb64 = (s) => new Uint8Array(Buffer.from(s, "base64"));

let pass = 0, fail = 0;
const ok = (c, m) => { if (c) { pass++; console.log("  PASS", m); } else { fail++; console.log("  FAIL", m); } };

async function pbkdf2(ikm, salt, iters) {
  const km = await subtle.importKey("raw", ikm, "PBKDF2", false, ["deriveBits"]);
  return new Uint8Array(await subtle.deriveBits({ name: "PBKDF2", salt, iterations: iters, hash: "SHA-256" }, km, 256));
}
async function seal(keyBytes, pt) {
  const k = await subtle.importKey("raw", keyBytes, "AES-GCM", false, ["encrypt"]);
  const iv = wc.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv }, k, pt));
  const out = new Uint8Array(12 + ct.length); out.set(iv, 0); out.set(ct, 12);
  return b64(out);
}
async function open(keyBytes, b64str) {
  const comb = unb64(b64str), iv = comb.subarray(0, 12), body = comb.subarray(12);
  const k = await subtle.importKey("raw", keyBytes, "AES-GCM", false, ["decrypt"]);
  return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv }, k, body));
}
const eqBytes = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
async function post(path, body, token) {
  const h = { "content-type": "application/json" };
  if (token) h.authorization = "Bearer " + token;
  const r = await fetch(API + path, { method: "POST", headers: h, body: JSON.stringify(body) });
  return { status: r.status, json: r.status !== 204 && r.headers.get("content-type")?.includes("json") ? await r.json() : null };
}

const ts = process.env.TS;
const email = `e2e+${ts}@vortx.tv`;
const username = `e2e${ts}`.slice(0, 20);
const password = "Sup3r-Secret-Pw!";
const ITERS = 210000;

// --- build register payload (the client crypto contract) ---
const kdfSaltBytes = wc.getRandomValues(new Uint8Array(16));
const kdfSalt = b64(kdfSaltBytes);
const masterKey = await pbkdf2(enc(password), kdfSaltBytes, ITERS);
const authVerifier = b64(await pbkdf2(masterKey, enc(password), 1));
const dataKey = wc.getRandomValues(new Uint8Array(32));
const wrappedKeyPassword = await seal(masterKey, dataKey);
const recoveryCode = b64(wc.getRandomValues(new Uint8Array(16))).replace(/[^a-zA-Z0-9]/g, "").slice(0, 20); // strong
const recoveryKey = await pbkdf2(enc(recoveryCode), kdfSaltBytes, ITERS);
const wrappedKeyRecovery = await seal(recoveryKey, dataKey);
const recVerifier = b64(await pbkdf2(recoveryKey, enc(recoveryCode), 1));

console.log("REGISTER");
let r = await post("/v1/auth/register", { email, username, kdfSalt, kdfIters: ITERS, authVerifier, wrappedKeyPassword, wrappedKeyRecovery, recVerifier });
ok(r.status === 200 && r.json?.token, `register -> 200 + token (${r.status})`);
let token = r.json?.token;

console.log("PRELOGIN");
r = await post("/v1/auth/prelogin", { login: email });
ok(r.json?.kdfSalt === kdfSalt && r.json?.kdfIters === ITERS, "prelogin returns our salt/iters");
r = await post("/v1/auth/prelogin", { login: "nobody-" + ts });
ok(r.status === 200 && typeof r.json?.kdfSalt === "string", "prelogin unknown -> decoy salt (non-revealing)");

console.log("LOGIN (email, then username) + unwrap dataKey");
for (const who of [email, username]) {
  const pre = (await post("/v1/auth/prelogin", { login: who })).json;
  const mk = await pbkdf2(enc(password), unb64(pre.kdfSalt), pre.kdfIters);
  const av = b64(await pbkdf2(mk, enc(password), 1));
  r = await post("/v1/auth/login", { login: who, authVerifier: av });
  const unwrapped = r.json?.wrappedKeyPassword ? await open(mk, r.json.wrappedKeyPassword) : null;
  ok(r.status === 200 && unwrapped && eqBytes(unwrapped, dataKey), `login by ${who === email ? "email" : "username"} + dataKey recovered`);
  token = r.json?.token || token;
}
r = await post("/v1/auth/login", { login: email, authVerifier: "wrong" });
ok(r.status === 401, "login wrong verifier -> 401");

console.log("BACKUP (encrypt under dataKey) put/get");
const doc = JSON.stringify({ v: 1, profiles: ["Main", "Kids"], accent: "ember", library: [1, 2, 3] });
const ciphertext = await seal(dataKey, enc(doc));
r = await post("/v1/backup", undefined, token); // ensure auth required for PUT done below
let put = await fetch(API + "/v1/backup", { method: "PUT", headers: { "content-type": "application/json", authorization: "Bearer " + token }, body: JSON.stringify({ document: ciphertext, version: Date.now() }) });
ok(put.status === 200, `backup PUT -> 200 (${put.status})`);
let get = await fetch(API + "/v1/backup", { headers: { authorization: "Bearer " + token } });
let gj = await get.json();
const decDoc = await open(dataKey, gj.document);
ok(td.decode(decDoc) === doc, "backup GET + decrypt matches original doc");
let noauth = await fetch(API + "/v1/backup", { headers: {} });
ok(noauth.status === 401, "backup GET without token -> 401");

console.log("CHANGE USERNAME (first allowed, second blocked by cooldown)");
const newUser = `e2e${ts}b`.slice(0, 20);
r = await post("/v1/auth/change-username", { username: newUser }, token);
ok(r.status === 200, `first change -> 200 (${r.status})`);
r = await post("/v1/auth/change-username", { username: `e2e${ts}c`.slice(0, 20) }, token);
ok(r.status === 429 && r.json?.error === "cooldown", `second change -> 429 cooldown (${r.status})`);

console.log("RECOVER (recovery code -> unwrap -> reset password)");
const rs = (await post("/v1/auth/recover-start", { email })).json;
const recKey2 = await pbkdf2(enc(recoveryCode), unb64(rs.kdfSalt), rs.kdfIters);
const recoveredDataKey = await open(recKey2, rs.wrappedKeyRecovery);
ok(recoveredDataKey && eqBytes(recoveredDataKey, dataKey), "recover-start: dataKey recovered via recovery code");
const newPw = "Even-Better-Pw2!";
// M-4: derive the new master key from the account's EXISTING kdfSalt (it is never rotated, so the
// recovery key, also derived from kdfSalt, stays valid for future recoveries).
const newMk = await pbkdf2(enc(newPw), unb64(rs.kdfSalt), rs.kdfIters);
const newAuthVerifier = b64(await pbkdf2(newMk, enc(newPw), 1));
const newWrappedKeyPassword = await seal(newMk, recoveredDataKey);
const recVer2 = b64(await pbkdf2(recKey2, enc(recoveryCode), 1));
r = await post("/v1/auth/recover-complete", { email, recVerifier: recVer2, newAuthVerifier, newWrappedKeyPassword });
ok(r.status === 200 && r.json?.token, `recover-complete -> 200 + token (${r.status})`);
// login with NEW password works
const pre2 = (await post("/v1/auth/prelogin", { login: email })).json;
const mk2 = await pbkdf2(enc(newPw), unb64(pre2.kdfSalt), pre2.kdfIters);
r = await post("/v1/auth/login", { login: email, authVerifier: b64(await pbkdf2(mk2, enc(newPw), 1)) });
const dk2 = r.json?.wrappedKeyPassword ? await open(mk2, r.json.wrappedKeyPassword) : null;
ok(r.status === 200 && dk2 && eqBytes(dk2, dataKey), "login with NEW password + same dataKey");
token = r.json?.token || token;
// M-4 regression: the recovery code STILL unwraps the data key after a password reset (kdfSalt unchanged).
const rs3 = (await post("/v1/auth/recover-start", { email })).json;
const recKey3 = await pbkdf2(enc(recoveryCode), unb64(rs3.kdfSalt), rs3.kdfIters);
const reRecovered = rs3.wrappedKeyRecovery ? await open(recKey3, rs3.wrappedKeyRecovery) : null;
ok(reRecovered && eqBytes(reRecovered, dataKey), "M-4: recovery code still works after a password reset");

console.log("QR LOGIN handoff");
const qs = (await post("/v1/qr/start", { devicePublicKey: "dummyPubKey" })).json;
ok(qs?.code && qs?.pairingID, "qr/start -> code + pairingID");
let st = await fetch(API + `/v1/qr/status?id=${qs.pairingID}`).then(x => x.json());
ok(st?.pending === true, "qr/status before authorize -> pending");
r = await post("/v1/qr/authorize", { code: qs.code, wrappedPayload: "wrappedDataKeyDummy" }, token);
ok(r.status === 200, `qr/authorize (logged in) -> 200 (${r.status})`);
st = await fetch(API + `/v1/qr/status?id=${qs.pairingID}`).then(x => x.json());
ok(st?.token && st?.payload === "wrappedDataKeyDummy", "qr/status after authorize -> session token + payload");

console.log(`\nRESULT: ${pass} passed, ${fail} failed`);
console.log("CLEANUP_EMAIL " + email);
