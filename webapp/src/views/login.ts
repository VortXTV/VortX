import { escapeHtml, actionOf } from "../lib/dom";
import { navigate } from "../lib/router";
import { adoptSession, hydrateFromAccount, signOut, currentSession } from "../lib/account";
import {
  register,
  login,
  recover,
  resetStart,
  resetComplete,
  checkUsername,
  TotpRequiredError,
  createAuthSurface, retireAuthSurface, beginAuthAttempt, authAttemptCurrent, authEffectCurrent,
  completeMemoryOnly, pendingAuthOperation, resumeAuthOperation, recoveryCodeFor, acknowledgeRecoveryCode,
  onSessionAuthority, sessionOwner, authTransitionFrom, pendingAuthPersistence, resolveAuthPersistence, type AuthSurface, type AuthAttempt, type AuthEffect, type AuthResult,
} from "../lib/vault";

// The VortX account screen for the webapp, ported from the website's login controller (the same state
// machine, reimplemented in the webapp's plain-DOM idiom). It is a hash route ("#/login") rendered into
// the main content host, wired through the existing global data-action click delegation (see addons.ts /
// detail.ts for the same pattern). Everything stays accessible: real <form>s, real <label>s,
// type=email/password inputs, and an aria-live error line per step.
//
// Steps (mirrors login.astro):
//   in       Sign in (email/username + password; reveals a TOTP field on TotpRequiredError)
//   up       Create account (username with a debounced availability hint, email, password)
//   created  One-time recovery code "save this" gate, shown after register / lost-both reset
//   recover  Forgot password (recover with the recovery code, data-preserving)
//   reset    Lost password AND recovery code (email a 6-digit code, mints a fresh empty vault)
//   dash     Signed-in summary + Sign out
// Crypto + persistence live entirely in vault.ts; this file is UI + flow only. vault.* throws
// human-readable strings, which we surface inline (never window.alert).

type Step = "in" | "up" | "created" | "recover" | "reset" | "dash";

// Module-scoped UI state. Reset on each renderLogin() so re-entering the route is a clean slate.
let step: Step = "in";
let needTotp = false; // sign-in revealed the 2FA field after a TotpRequiredError
let pendingRecoveryCode = ""; // the just-minted code shown on the "created" step
let usernameTimer = 0; // debounce handle for the availability check
let hostEl: HTMLElement | null = null;
let surface: AuthSurface | undefined, attempt: AuthAttempt | undefined, effect: AuthEffect | undefined;
let viewGeneration = 0, unsubscribeOwner: (() => void) | undefined;
let statusText = "", allowMemory = false;
function scrub(): void {
  hostEl?.querySelectorAll<HTMLInputElement>("input").forEach((node) => { node.value = ""; node.removeAttribute("value"); });
  const code = field("reccode"); if (code) code.textContent = "";
  pendingRecoveryCode = "";
}
export function disposeLogin(): void {
  if (surface) retireAuthSurface(surface);
  window.clearTimeout(usernameTimer); unsubscribeOwner?.(); unsubscribeOwner = undefined;
  window.removeEventListener("pagehide", disposeLogin);
  scrub(); allowMemory = false; hostEl = null; surface = undefined; attempt = undefined; effect = undefined; viewGeneration++;
}
function currentView(generation: number, lease: AuthSurface | undefined): boolean {
  return !!hostEl && generation === viewGeneration && lease === surface;
}
function actionError(x: unknown): string {
  const pending = pendingAuthOperation();
  if (pending?.outcome === "unknown") return "The server outcome is unknown. Keep this tab open; do not repeat this account operation.";
  if (pending?.outcome === "accepted") return "The server accepted the operation. Its setup material remains in this tab; use Resume setup, not another request.";
  return message(x);
}

/** Paint the account screen into `host`. The signed-in state shows the dash step; otherwise sign-in. */
export function renderLogin(host: HTMLElement): void {
  disposeLogin();
  hostEl = host; surface = createAuthSurface();
  statusText = sessionOwner().mode === "blocked" ? "This account is retained, but storage ownership is blocked. No guest fallback was used." : "";
  const unsubscribe = onSessionAuthority((origin) => {
    if (unsubscribeOwner !== unsubscribe || hostEl !== host) return; // a retired batch listener cannot affect its replacement
    if (origin && surface && authTransitionFrom(origin, surface)) return; // exact self-transition, never suppress a rival
    const target = hostEl;
    if (target) renderLogin(target);
  });
  unsubscribeOwner = unsubscribe;
  window.addEventListener("pagehide", disposeLogin);
  needTotp = false;
  pendingRecoveryCode = "";
  step = currentSession() ? "dash" : "in";
  render();
}

/** Re-render the current step into the host (idempotent; called after every state change). */
function render(): void {
  if (!hostEl) return;
  viewGeneration++;
  hostEl.innerHTML = `
    <div class="auth-screen">
      <p class="t-eyebrow">VortX account</p>
      <h1 class="t-screen auth-title">Your sync, end to end encrypted.</h1>
      <p class="t-body auth-lead">Your profiles, settings, library, and history on every device. Your password is the key, so no VortX server can ever read your data.</p>
      <p class="auth-error" id="auth-status" role="status">${escapeHtml(statusText)}</p>
      <div id="auth-pending" role="status" aria-live="polite">${pendingMarkup()}</div>
      ${stepMarkup()}
      <p class="t-label auth-footnote muted">End to end encrypted. Your password and keys never leave this tab.</p>
    </div>`;
  wireForms();
}

function pendingMarkup(): string {
  const pending = pendingAuthOperation(), unresolved = pendingAuthPersistence();
  const warning = pending ? '<p class="auth-hint">An account operation is retained in this tab. Keep this tab open until setup is resolved; closing it can lose its private recovery material.</p>' : "";
  const unknown = pending?.outcome === "unknown" ? '<p class="auth-hint">The server outcome is unknown. Do not repeat this operation.</p>' : "";
  const resume = pending?.resumable && !unresolved ? '<button class="chip" data-action="resume-setup">Resume accepted setup</button>' : "";
  const resolve = unresolved ? '<button class="chip" data-action="resolve-save">Check unresolved local save</button>' : "";
  const memory = allowMemory && !unresolved ? '<button class="chip" data-action="auth-memory">Continue in this tab only</button>' : "";
  return warning + unknown + resume + resolve + memory;
}
function updatePending(): void {
  const node = field("auth-pending");
  if (node) node.innerHTML = pendingMarkup(); // preserve the current form/attempt and its entered intent
}

/** The markup for the active step. */
function stepMarkup(): string {
  switch (step) {
    case "in":
    case "up":
      return authMarkup();
    case "created":
      return createdMarkup();
    case "recover":
      return recoverMarkup();
    case "reset":
      return resetMarkup();
    case "dash":
      return dashMarkup();
  }
}

// --- Step markup --------------------------------------------------------------------------------

function authMarkup(): string {
  const inOn = step === "in";
  return `
    <div class="auth-tabs" role="tablist" aria-label="Sign in or create account">
      <button class="chip${inOn ? " selected" : ""}" role="tab" aria-selected="${inOn}" data-action="auth-tab-in" type="button">Sign in</button>
      <button class="chip${inOn ? "" : " selected"}" role="tab" aria-selected="${!inOn}" data-action="auth-tab-up" type="button">Create account</button>
    </div>
    ${inOn ? signInForm() : createForm()}`;
}

function signInForm(): string {
  return `
    <form class="surface-card auth-card auth-form" id="form-in" novalidate>
      <label class="auth-label" for="in-login">Email or username
        <input class="field" id="in-login" name="login" type="text" autocomplete="username" autocapitalize="none" spellcheck="false" required />
      </label>
      <label class="auth-label" for="in-pw">Password
        <input class="field" id="in-pw" name="password" type="password" autocomplete="current-password" required />
      </label>
      <label class="auth-label" id="in-totp-wrap" for="in-totp"${needTotp ? "" : " hidden"}>Authenticator code
        <input class="field" id="in-totp" name="totp" type="text" inputmode="numeric" pattern="[0-9]*" maxlength="6" autocomplete="one-time-code" placeholder="000000" />
        <span class="auth-hint">Enter the current 6-digit code from your authenticator app.</span>
      </label>
      <p class="auth-error" id="in-err" role="alert" aria-live="polite" hidden></p>
      <button class="btn-primary" type="submit">${needTotp ? "Verify and sign in" : "Sign in"}</button>
      <div class="auth-links">
        <button class="auth-linkbtn" type="button" data-action="to-recover">Forgot password?</button>
      </div>
    </form>`;
}

function createForm(): string {
  return `
    <form class="surface-card auth-card auth-form" id="form-up" novalidate>
      <label class="auth-label" for="up-email">Email
        <input class="field" id="up-email" name="email" type="email" autocomplete="email" autocapitalize="none" spellcheck="false" required />
      </label>
      <label class="auth-label" for="up-username">Username
        <input class="field" id="up-username" name="username" type="text" autocomplete="off" autocapitalize="none" spellcheck="false" minlength="3" maxlength="20" required />
        <span class="auth-hint" id="up-uhint" aria-live="polite"></span>
      </label>
      <label class="auth-label" for="up-pw">Password
        <input class="field" id="up-pw" name="password" type="password" autocomplete="new-password" minlength="8" required />
      </label>
      <p class="auth-error" id="up-err" role="alert" aria-live="polite" hidden></p>
      <button class="btn-primary" type="submit">Create account</button>
      <p class="t-label muted auth-note">Username is unique and changeable once every 3 months.</p>
    </form>`;
}

function createdMarkup(): string {
  return `
    <div class="surface-card auth-card">
      <h2 class="t-section">Save your recovery code</h2>
      <p class="t-body muted">If you ever forget your password and have no device signed in, this code is the only way back into your encrypted data. We cannot reset it. Store it somewhere safe and offline.</p>
      <p class="auth-reccode" id="reccode" translate="no">${escapeHtml(pendingRecoveryCode)}</p>
      <div class="auth-actions">
        <button class="chip" type="button" data-action="copy-reccode">Copy code</button>
        <button class="btn-primary" type="button" data-action="reccode-done">I saved it, continue</button>
      </div>
    </div>`;
}

function recoverMarkup(): string {
  return `
    <form class="surface-card auth-card auth-form" id="form-rec" novalidate>
      <h2 class="t-section">Reset your password</h2>
      <p class="t-body muted">Enter your email, your recovery code, and a new password.</p>
      <label class="auth-label" for="rec-email">Email
        <input class="field" id="rec-email" name="email" type="email" autocomplete="email" autocapitalize="none" spellcheck="false" required />
      </label>
      <label class="auth-label" for="rec-code">Recovery code
        <input class="field" id="rec-code" name="code" type="text" autocomplete="off" autocapitalize="characters" spellcheck="false" placeholder="VX-XXXX-XXXX-…" required />
      </label>
      <label class="auth-label" for="rec-pw">New password
        <input class="field" id="rec-pw" name="password" type="password" autocomplete="new-password" minlength="8" required />
      </label>
      <p class="auth-error" id="rec-err" role="alert" aria-live="polite" hidden></p>
      <button class="btn-primary" type="submit">Reset password</button>
      <div class="auth-links">
        <button class="auth-linkbtn" type="button" data-action="to-reset">Lost your recovery code too?</button>
        <button class="auth-linkbtn" type="button" data-action="to-signin">Back to sign in</button>
      </div>
    </form>`;
}

function resetMarkup(): string {
  return `
    <form class="surface-card auth-card auth-form" id="form-reset" novalidate>
      <h2 class="t-section">Reset with an email code</h2>
      <p class="t-body muted">Lost your recovery code too? We can email a 6-digit code to reset your password. This starts a fresh, empty vault: your synced library, add-ons, and settings cannot be recovered without your old password or recovery code.</p>
      <label class="auth-label" for="rs-email">Email
        <input class="field" id="rs-email" name="email" type="email" autocomplete="email" autocapitalize="none" spellcheck="false" required />
      </label>
      <div class="auth-actions">
        <button class="chip" type="button" data-action="reset-send">Email me a code</button>
        <span class="auth-hint" id="rs-sent" aria-live="polite" hidden>Code sent. Check your email.</span>
      </div>
      <label class="auth-label" for="rs-code">Reset code
        <input class="field" id="rs-code" name="code" type="text" autocomplete="off" inputmode="numeric" spellcheck="false" placeholder="6 digits" required />
      </label>
      <label class="auth-label" for="rs-pw">New password
        <input class="field" id="rs-pw" name="password" type="password" autocomplete="new-password" minlength="8" required />
      </label>
      <p class="auth-error" id="rs-err" role="alert" aria-live="polite" hidden></p>
      <button class="btn-primary" type="submit">Reset and start fresh</button>
      <div class="auth-links">
        <button class="auth-linkbtn" type="button" data-action="to-signin">Back to sign in</button>
      </div>
    </form>`;
}

function dashMarkup(): string {
  const s = currentSession();
  const username = s?.account.username ?? "";
  const email = s?.account.email ?? "";
  return `
    <div class="surface-card auth-card auth-dash">
      <div>
        <p class="t-label muted">Signed in as</p>
        <p class="auth-handle" translate="no">${escapeHtml(username || "—")}</p>
        <p class="t-label muted">${escapeHtml(email)}</p>
      </div>
      <button class="chip" type="button" data-action="sign-out">Sign out</button>
    </div>`;
}

// --- Wiring -------------------------------------------------------------------------------------
// Submits are wired directly on the freshly rendered <form>s (forms own their own submit semantics,
// which the global click handler should not intercept). Button affordances flow through the global
// data-action delegation via handleLoginClick (called from main.ts's body click handler), matching the
// addons.ts / detail.ts convention.

function wireForms(): void {
  if (!hostEl) return;
  hostEl.querySelector<HTMLFormElement>("#form-in")?.addEventListener("submit", onSignIn);
  hostEl.querySelector<HTMLFormElement>("#form-up")?.addEventListener("submit", onCreate);
  hostEl.querySelector<HTMLFormElement>("#form-rec")?.addEventListener("submit", onRecover);
  hostEl.querySelector<HTMLFormElement>("#form-reset")?.addEventListener("submit", onResetComplete);
  // Live username availability hint (debounced), only present on the create step.
  hostEl.querySelector<HTMLInputElement>("#up-username")?.addEventListener("input", onUsernameInput);
}

/** Public hook for main.ts's global click delegation. Returns true if it consumed the click. Mirrors
 *  detail.ts's handleDetailClick shape so main.ts wires it the same way. */
export function handleLoginClick(target: EventTarget | null): boolean {
  const hit = actionOf(target);
  if (!hit || !hostEl?.contains(hit.node)) return false;
  switch (hit.action) {
    case "auth-tab-in":
      needTotp = false;
      goto("in");
      return true;
    case "auth-tab-up":
      goto("up");
      return true;
    case "to-recover":
      goto("recover");
      return true;
    case "to-reset":
      goto("reset");
      return true;
    case "to-signin":
      needTotp = false;
      goto("in");
      return true;
    case "reccode-done":
      if (effect && acknowledgeRecoveryCode(effect)) { pendingRecoveryCode = ""; goto("dash"); }
      return true;
    case "resolve-save":
      void resolveSave();
      return true;
    case "resume-setup":
      void resumeSetup();
      return true;
    case "auth-memory":
      if (attempt) { try { const result = completeMemoryOnly(attempt); void finishLocal(result); } catch (x) { status(actionError(x)); } }
      return true;
    case "copy-reccode":
      void copyRecoveryCode(hit.node);
      return true;
    case "reset-send":
      void onResetSend(hit.node);
      return true;
    case "sign-out":
      void signOutHere();
      return true;
    default:
      return false;
  }
}

/** Optional convenience for callers that prefer host-scoped wiring (parity with wireAddons). Attaches
 *  the same delegation locally; main.ts may instead route through handleLoginClick from its body
 *  handler. Safe to call once per render. */
export function wireLogin(host: HTMLElement): void {
  host.addEventListener("click", (ev) => {
    handleLoginClick(ev.target);
  });
}

function goto(next: Step): void {
  if (surface) retireAuthSurface(surface);
  scrub(); allowMemory = false; surface = createAuthSurface(); attempt = undefined; effect = undefined;
  window.clearTimeout(usernameTimer); step = next; render();
}
function status(text: string): void {
  statusText = text; const node = field("auth-status"); if (node) node.textContent = text;
}
async function signOutHere(): Promise<void> {
  const target = hostEl;
  const promise = signOut(); // retires immediately; observer may replace this surface
  if (!target) return;
  renderLogin(target);
  const generation = viewGeneration, lease = surface;
  status("Signing out of this tab; checking saved session…");
  const result = await promise;
  if (currentView(generation, lease)) status(result.status === "not-persisted" ? "Signed out; saved session cleared." : "Signed out in this tab, but the saved session could not be confirmed cleared.");
}
async function finishLocal(result: AuthResult): Promise<void> {
  if (!result.effect || !authEffectCurrent(result.effect)) {
    if (hostEl) { status("The session was not adopted here (" + result.status + "). Saved account material has been preserved."); updatePending(); }
    return;
  }
  allowMemory = false;
  const receipt = result.effect;
  effect = receipt;
  status(result.status === "memory-only" ? "This tab only — not saved for reload." : "Session saved.");
  const code = recoveryCodeFor(effect);
  if (code) { scrub(); pendingRecoveryCode = code; step = "created"; render(); return; }
  const session = currentSession();
  scrub();
  if (session) await hydrateFromAccount(session);
  if (effect === receipt && authEffectCurrent(receipt)) navigate({ name: "home" });
}
async function resolveSave(): Promise<void> {
  const lease = surface, generation = viewGeneration; if (!lease) return;
  const result = await resolveAuthPersistence(lease);
  if (currentView(generation, lease)) await finishLocal(result);
}
async function resumeSetup(): Promise<void> {
  const lease = surface, generation = viewGeneration;
  if (!lease) return;
  try {
    const result = await resumeAuthOperation(lease);
    if (currentView(generation, lease)) await finishLocal(result);
  } catch (x) { if (currentView(generation, lease)) { status(actionError(x)); updatePending(); } }
}

// --- Form handlers: each callback owns the exact form generation and attempt ----------------------
function beginForm(ev: SubmitEvent, kind: "login" | "register" | "recover" | "reset"): AuthAttempt | null {
  ev.preventDefault();
  if (!hostEl || !surface || !hostEl.contains(ev.currentTarget as Node)) return null;
  try { attempt = beginAuthAttempt(kind, surface); allowMemory = false; updatePending(); return attempt; }
  catch (x) { status(actionError(x)); return null; }
}
async function settleForm(handle: AuthAttempt): Promise<void> {
  const result = await adoptSession(handle);
  // A historical persisted result may lack a current effect; never paint it into a newer surface.
  if (attempt !== handle || !hostEl) return;
  if (result.effect) { await finishLocal(result); return; }
  status("Local session save: " + result.status + ". No newer account was replaced.");
  const mode = sessionOwner().mode;
  allowMemory = result.status === "not-persisted" && (mode === "guest" || mode === "memory");
  updatePending();
}
async function onSignIn(ev: SubmitEvent): Promise<void> {
  const handle = beginForm(ev, "login"); if (!handle) return;
  const generation = viewGeneration, lease = surface;
  const loginId = inputValue("in-login").trim(), password = inputValue("in-pw");
  const totp = needTotp ? inputValue("in-totp").trim() : undefined, btn = submitButton(ev);
  clearError("in-err"); setBusy(btn, needTotp ? "Verifying…" : "Signing in…");
  try {
    await login(loginId, password, totp, handle);
    if (currentView(generation, lease) && authAttemptCurrent(handle)) await settleForm(handle);
  } catch (x) {
    if (!currentView(generation, lease) || !authAttemptCurrent(handle)) return;
    if (x instanceof TotpRequiredError) {
      needTotp = true; const wrap = field("in-totp-wrap"); if (wrap) wrap.hidden = false;
      restoreButton(btn, "Verify and sign in"); focusField("in-totp");
    } else { showError("in-err", actionError(x)); restoreButton(btn, "Sign in"); }
  } finally {
    if (currentView(generation, lease)) updatePending();
  }
}
async function onCreate(ev: SubmitEvent): Promise<void> {
  const handle = beginForm(ev, "register"); if (!handle) return;
  const generation = viewGeneration, lease = surface, btn = submitButton(ev);
  const email = inputValue("up-email").trim(), username = inputValue("up-username").trim(), password = inputValue("up-pw");
  clearError("up-err"); setBusy(btn, "Creating…");
  try {
    await register(email, username, password, handle);
    if (currentView(generation, lease) && authAttemptCurrent(handle)) await settleForm(handle);
  } catch (x) {
    if (currentView(generation, lease) && authAttemptCurrent(handle)) { showError("up-err", actionError(x)); restoreButton(btn, "Create account"); }
  } finally {
    if (currentView(generation, lease)) updatePending();
  }
}
async function onRecover(ev: SubmitEvent): Promise<void> {
  const handle = beginForm(ev, "recover"); if (!handle) return;
  const generation = viewGeneration, lease = surface, btn = submitButton(ev);
  const email = inputValue("rec-email").trim(), code = inputValue("rec-code").trim(), password = inputValue("rec-pw");
  clearError("rec-err"); setBusy(btn, "Resetting…");
  try {
    await recover(email, code, password, handle);
    if (currentView(generation, lease) && authAttemptCurrent(handle)) await settleForm(handle);
  } catch (x) {
    if (currentView(generation, lease) && authAttemptCurrent(handle)) { showError("rec-err", actionError(x)); restoreButton(btn, "Reset password"); }
  } finally {
    if (currentView(generation, lease)) updatePending();
  }
}
async function onResetSend(node: HTMLElement): Promise<void> {
  const generation = viewGeneration, lease = surface;
  if (!lease || !hostEl?.contains(node)) return;
  const email = inputValue("rs-email").trim();
  if (!email) { showError("rs-err", "Enter your email first."); return; }
  let handle: AuthAttempt;
  try { handle = attempt = beginAuthAttempt("reset-send", lease); updatePending(); } catch (x) { status(actionError(x)); return; }
  const btn = node as HTMLButtonElement; setBusy(btn, "Sending…");
  try {
    await resetStart(email, handle);
    if (currentView(generation, lease) && authAttemptCurrent(handle)) { const sent = field("rs-sent"); if (sent) sent.hidden = false; }
  } catch (x) {
    if (currentView(generation, lease) && authAttemptCurrent(handle)) showError("rs-err", actionError(x));
  } finally {
    if (currentView(generation, lease) && authAttemptCurrent(handle)) { restoreButton(btn, "Email me a code"); updatePending(); }
  }
}
async function onResetComplete(ev: SubmitEvent): Promise<void> {
  const handle = beginForm(ev, "reset"); if (!handle) return;
  const generation = viewGeneration, lease = surface, btn = submitButton(ev);
  const email = inputValue("rs-email").trim(), code = inputValue("rs-code").trim(), password = inputValue("rs-pw");
  clearError("rs-err"); setBusy(btn, "Resetting…");
  try {
    await resetComplete(email, code, password, handle);
    if (currentView(generation, lease) && authAttemptCurrent(handle)) await settleForm(handle);
  } catch (x) {
    if (currentView(generation, lease) && authAttemptCurrent(handle)) { showError("rs-err", actionError(x)); restoreButton(btn, "Reset and start fresh"); }
  } finally {
    if (currentView(generation, lease)) updatePending();
  }
}
function onUsernameInput(): void {
  window.clearTimeout(usernameTimer);
  const generation = viewGeneration, lease = surface, input = field<HTMLInputElement>("up-username"), hint = field("up-uhint");
  const value = input?.value.trim() ?? "";
  if (!hint) return;
  if (!/^[a-zA-Z0-9_]{3,20}$/.test(value)) { hint.textContent = value ? "3-20 letters, numbers, underscore" : ""; hint.className = "auth-hint"; return; }
  hint.textContent = "checking…";
  const valid = () => currentView(generation, lease) && field("up-username") === input && input?.value.trim() === value && field("up-uhint") === hint;
  usernameTimer = window.setTimeout(async () => {
    try {
      const ok = await checkUsername(value);
      if (valid()) { hint.textContent = ok ? "available" : "taken"; hint.className = ok ? "auth-hint ok" : "auth-hint bad"; }
    } catch { if (valid()) { hint.textContent = ""; hint.className = "auth-hint"; } }
  }, 350);
}
async function copyRecoveryCode(node: HTMLElement): Promise<void> {
  const receipt = effect, generation = viewGeneration, lease = surface;
  if (!receipt || !authEffectCurrent(receipt) || !hostEl?.contains(node)) return;
  const code = recoveryCodeFor(receipt); if (!code) return;
  try {
    await navigator.clipboard.writeText(code);
    if (currentView(generation, lease) && authEffectCurrent(receipt)) node.textContent = "Copied";
  } catch { /* requested clipboard write cannot be rolled back; do not paint a retired surface */ }
}

// --- Small DOM helpers (scoped to the login host) -----------------------------------------------

function field<T extends HTMLElement = HTMLElement>(id: string): T | null {
  return (hostEl?.querySelector<T>("#" + id)) ?? null;
}
function inputValue(id: string): string {
  return field<HTMLInputElement>(id)?.value ?? "";
}
function focusField(id: string): void {
  field<HTMLInputElement>(id)?.focus();
}
function submitButton(ev: SubmitEvent): HTMLButtonElement | null {
  const form = ev.currentTarget as HTMLFormElement | null;
  return form?.querySelector<HTMLButtonElement>("button[type=submit]") ?? null;
}
function setBusy(btn: HTMLButtonElement | null, label: string): void {
  if (!btn) return;
  btn.disabled = true;
  btn.textContent = label;
}
function restoreButton(btn: HTMLButtonElement | null, label: string): void {
  if (!btn) return;
  btn.disabled = false;
  btn.textContent = label;
}
function showError(id: string, text: string): void {
  const el = field<HTMLElement>(id);
  if (!el) return;
  el.textContent = text;
  el.hidden = false;
}
function clearError(id: string): void {
  const el = field<HTMLElement>(id);
  if (el) el.hidden = true;
}

/** vault throws Error with a user-facing message; fall back to a generic line for anything else. */
function message(x: unknown): string {
  return x instanceof Error && x.message ? x.message : "Something went wrong. Please try again.";
}
