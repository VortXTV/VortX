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
  type Session,
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

/** Paint the account screen into `host`. The signed-in state shows the dash step; otherwise sign-in. */
export function renderLogin(host: HTMLElement): void {
  hostEl = host;
  needTotp = false;
  pendingRecoveryCode = "";
  step = currentSession() ? "dash" : "in";
  render();
}

/** Re-render the current step into the host (idempotent; called after every state change). */
function render(): void {
  if (!hostEl) return;
  hostEl.innerHTML = `
    <div class="auth-screen">
      <p class="t-eyebrow">VortX account</p>
      <h1 class="t-screen auth-title">Your sync, end to end encrypted.</h1>
      <p class="t-body auth-lead">Your profiles, settings, library, and history on every device. Your password is the key, so no VortX server can ever read your data.</p>
      ${stepMarkup()}
      <p class="t-label auth-footnote muted">End to end encrypted. Your password and keys never leave this tab.</p>
    </div>`;
  wireForms();
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
  if (!hit) return false;
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
      goto("dash");
      return true;
    case "copy-reccode":
      void copyRecoveryCode(hit.node);
      return true;
    case "reset-send":
      void onResetSend(hit.node);
      return true;
    case "sign-out":
      signOut();
      goto("in");
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
  step = next;
  render();
}

// --- Form handlers ------------------------------------------------------------------------------

async function onSignIn(ev: SubmitEvent): Promise<void> {
  ev.preventDefault();
  clearError("in-err");
  const loginId = inputValue("in-login").trim();
  const password = inputValue("in-pw");
  const totp = needTotp ? inputValue("in-totp").trim() : undefined;
  const btn = submitButton(ev);
  setBusy(btn, needTotp ? "Verifying…" : "Signing in…");
  try {
    const session = await login(loginId, password, totp);
    await succeed(session);
  } catch (x: unknown) {
    if (x instanceof TotpRequiredError) {
      // 2FA account: reveal the code field IN PLACE and let the user resubmit with it. Do NOT re-render
      // the form (that rebuilds the inputs and wipes the email/password the user already typed); just
      // un-hide the existing TOTP row and relabel the button.
      needTotp = true;
      const wrap = field<HTMLElement>("in-totp-wrap");
      if (wrap) wrap.hidden = false;
      restoreButton(btn, "Verify and sign in");
      focusField("in-totp");
    } else {
      showError("in-err", message(x));
      restoreButton(btn, needTotp ? "Verify and sign in" : "Sign in");
    }
  }
}

async function onCreate(ev: SubmitEvent): Promise<void> {
  ev.preventDefault();
  clearError("up-err");
  const email = inputValue("up-email").trim();
  const username = inputValue("up-username").trim();
  const password = inputValue("up-pw");
  const btn = submitButton(ev);
  setBusy(btn, "Creating…");
  try {
    const { session, recoveryCode } = await register(email, username, password);
    // Persist the session now, but gate the user on saving the one-time recovery code first.
    adoptSession(session);
    pendingRecoveryCode = recoveryCode;
    goto("created");
  } catch (x: unknown) {
    showError("up-err", message(x));
    restoreButton(btn, "Create account");
  }
}

async function onRecover(ev: SubmitEvent): Promise<void> {
  ev.preventDefault();
  clearError("rec-err");
  const email = inputValue("rec-email").trim();
  const code = inputValue("rec-code").trim();
  const password = inputValue("rec-pw");
  const btn = submitButton(ev);
  setBusy(btn, "Resetting…");
  try {
    const session = await recover(email, code, password);
    await succeed(session);
  } catch (x: unknown) {
    showError("rec-err", message(x));
    restoreButton(btn, "Reset password");
  }
}

async function onResetSend(node: HTMLElement): Promise<void> {
  const email = inputValue("rs-email").trim();
  if (!email) {
    showError("rs-err", "Enter your email first.");
    return;
  }
  clearError("rs-err");
  const btn = node as HTMLButtonElement;
  setBusy(btn, "Sending…");
  try {
    await resetStart(email);
    const sent = field<HTMLElement>("rs-sent");
    if (sent) sent.hidden = false;
  } catch {
    showError("rs-err", "Could not send the code. Try again in a minute.");
  } finally {
    restoreButton(btn, "Email me a code");
  }
}

async function onResetComplete(ev: SubmitEvent): Promise<void> {
  ev.preventDefault();
  clearError("rs-err");
  const email = inputValue("rs-email").trim();
  const code = inputValue("rs-code").trim();
  const password = inputValue("rs-pw");
  const btn = submitButton(ev);
  setBusy(btn, "Resetting…");
  try {
    const { session, recoveryCode } = await resetComplete(email, code, password);
    adoptSession(session);
    pendingRecoveryCode = recoveryCode;
    goto("created");
  } catch (x: unknown) {
    showError("rs-err", message(x));
    restoreButton(btn, "Reset and start fresh");
  }
}

function onUsernameInput(): void {
  window.clearTimeout(usernameTimer);
  const value = inputValue("up-username").trim();
  const hint = field<HTMLElement>("up-uhint");
  if (!hint) return;
  if (!/^[a-zA-Z0-9_]{3,20}$/.test(value)) {
    hint.textContent = value ? "3-20 letters, numbers, underscore" : "";
    hint.className = "auth-hint";
    return;
  }
  hint.textContent = "checking…";
  hint.className = "auth-hint";
  usernameTimer = window.setTimeout(async () => {
    try {
      const ok = await checkUsername(value);
      // The user may have moved on (re-render); only write if the hint is still on screen.
      const live = field<HTMLElement>("up-uhint");
      if (!live) return;
      live.textContent = ok ? "available" : "taken";
      live.className = ok ? "auth-hint ok" : "auth-hint bad";
    } catch {
      const live = field<HTMLElement>("up-uhint");
      if (live) {
        live.textContent = "";
        live.className = "auth-hint";
      }
    }
  }, 350);
}

// --- On success ---------------------------------------------------------------------------------

/** vault already saved the session; cache + notify, then go home. (register/reset go via the
 *  recovery-code gate first, then "I saved it, continue" calls goto("dash"); they do not call this.) */
async function succeed(session: Session): Promise<void> {
  adoptSession(session);
  // Pull the account's add-ons / library / metadata keys before showing Home, so a returning user lands
  // on their populated app instead of a blank slate. Fail-soft (never blocks sign-in).
  await hydrateFromAccount(session);
  navigate({ name: "home" });
}

async function copyRecoveryCode(node: HTMLElement): Promise<void> {
  try {
    await navigator.clipboard.writeText(pendingRecoveryCode);
    node.textContent = "Copied";
  } catch {
    // Clipboard blocked (permissions / insecure context): the code is still visible to copy by hand.
  }
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
