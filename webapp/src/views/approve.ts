import { escapeHtml, actionOf } from "../lib/dom";
import { currentSession } from "../lib/account";
import { qrApprove, createAuthSurface, retireAuthSurface, beginAuthAttempt, authAttemptCurrent, captureSessionOwnership, onSessionAuthority, pendingAuthOperation, type AuthSurface, type Session } from "../lib/vault";
let shown: { host: HTMLElement; surface: AuthSurface; session: Session; code: string; key: string; owns: () => boolean } | undefined;
let removeOwnerListener: (() => void) | undefined;
export function disposeApprove(): void {
  if (shown) { retireAuthSurface(shown.surface); shown.host.querySelectorAll(".approve-code").forEach((node) => { node.textContent = ""; }); }
  shown = undefined; removeOwnerListener?.(); removeOwnerListener = undefined;
  window.removeEventListener("pagehide", disposeApprove);
}

// The QR device-approval surface (#/approve?c=CODE&k=DEVICE_PUBKEY). A device that is ALREADY signed in
// opens this link (the URL encoded in the QR a signing-in device shows) and approves it: qrApprove wraps
// THIS device's data key to the joining device's ephemeral public key and authorizes the pairing, so the
// new device unlocks the account without the password, and the server only ever relays ciphertext. If
// this device is not signed in there is no data key to hand over, so it prompts to sign in first.

function approveParams(): { code: string; key: string } {
  const q = location.hash.split("?")[1] ?? "";
  const sp = new URLSearchParams(q);
  return { code: (sp.get("c") ?? "").trim(), key: (sp.get("k") ?? "").trim() };
}

export function renderApprove(host: HTMLElement): void {
  disposeApprove();
  const { code, key } = approveParams();
  const session = currentSession();
  if (!session) {
    host.innerHTML = `
      <div class="auth-screen">
        <p class="t-eyebrow">Approve a device</p>
        <h1 class="t-screen auth-title">Sign in to approve</h1>
        <div class="surface-card auth-card">
          <p class="t-body muted">To approve a new device, sign in on <strong>this</strong> device first, then open the QR link again.</p>
          <a class="btn-primary" href="#/login">Sign in</a>
        </div>
      </div>`;
    return;
  }
  if (!code || !key) {
    host.innerHTML = `
      <div class="auth-screen">
        <p class="t-eyebrow">Approve a device</p>
        <h1 class="t-screen auth-title">Invalid approval link</h1>
        <div class="surface-card auth-card">
          <p class="t-body muted">This approval link is missing its code. Generate a fresh QR on the device you are signing in.</p>
          <a class="chip" href="#/">Back to Home</a>
        </div>
      </div>`;
    return;
  }
  const surface = createAuthSurface();
  shown = { host, surface, session, code, key, owns: captureSessionOwnership(session) };
  removeOwnerListener = onSessionAuthority(() => {
    if (!shown) return;
    const target = shown.host; disposeApprove();
    target.innerHTML = '<p role="status">Account changed. Reopen the approval link to review its owner.</p>';
  });
  window.addEventListener("pagehide", disposeApprove);
  const who = session.account.username || session.account.email;
  host.innerHTML = `
    <div class="auth-screen">
      <p class="t-eyebrow">Approve a device</p>
      <h1 class="t-screen auth-title">Sign in a new device?</h1>
      <div class="surface-card auth-card">
        <p class="t-body muted">A device is asking to sign in to <strong translate="no">${escapeHtml(who)}</strong> with code <span class="approve-code" translate="no">${escapeHtml(code)}</span>. Approving hands it your account, end to end encrypted. Only approve a device you are signing in right now.</p>
        <p class="auth-error" id="approve-err" role="alert" aria-live="polite" hidden></p>
        <div class="auth-actions">
          <button class="btn-primary" type="button" data-action="approve-device">Approve</button>
          <a class="chip" href="#/">Cancel</a>
        </div>
      </div>
    </div>`;
}

/** Global click hook (parity with handleLoginClick); returns true if it consumed the click. */
export function handleApproveClick(target: EventTarget | null): boolean {
  const hit = actionOf(target);
  if (!hit || hit.action !== "approve-device" || !shown?.host.contains(hit.node)) return false;
  void doApprove(hit.node as HTMLButtonElement);
  return true;
}

async function doApprove(btn: HTMLButtonElement): Promise<void> {
  const captured = shown, params = approveParams();
  if (!captured || !captured.owns() || params.code !== captured.code || params.key !== captured.key) return;
  const err = captured.host.querySelector<HTMLElement>("#approve-err");
  let attempt;
  try { attempt = beginAuthAttempt("approve", captured.surface); }
  catch { if (err) { err.textContent = "An account action is unresolved. Keep this tab open."; err.hidden = false; } return; }
  const live = () => shown === captured && captured.owns() && authAttemptCurrent(attempt) &&
    approveParams().code === captured.code && approveParams().key === captured.key;
  btn.disabled = true; btn.textContent = "Approving…"; if (err) err.hidden = true;
  try {
    await qrApprove(captured.session, captured.code, captured.key, attempt);
    if (!live()) return;
    const card = btn.closest(".surface-card");
    if (card) card.innerHTML = '<h2 class="t-section">Device approved</h2><p class="t-body muted">The other device is signing in now.</p><a class="chip" href="#/">Done</a>';
  } catch {
    if (!live()) return;
    if (err) {
      err.textContent = pendingAuthOperation()?.outcome === "unknown" ? "Approval outcome is unknown. Keep this tab open; do not send it again." : "Approval was not completed.";
      err.hidden = false;
    }
    btn.disabled = pendingAuthOperation()?.outcome === "unknown"; btn.textContent = "Approve";
  }
}
