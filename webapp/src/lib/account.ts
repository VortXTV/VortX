// Session-state module for the webapp. A thin, DOM-free layer over vault.ts that the nav, the Login
// screen, and a future Settings > Account section all read from. It owns:
//   - the single in-memory session cache (so callers don't re-read localStorage on every render),
//   - the boot-time validation (loadSession then GET /v1/auth/me, clearing on a definite 401),
//   - sign-out, and
//   - a tiny subscribe/notify bus so UI reacts to sign-in / sign-out without polling.
// vault.ts is the source of truth for crypto + persistence; this module never touches localStorage
// directly, it goes through vault's saveSession/loadSession/clearSession.

import { loadSession, clearSession, validateSession, saveSession, type Session } from "./vault";

// The in-memory cache. `undefined` = not yet hydrated from storage; `null` = hydrated, signed out.
// We lazily hydrate from loadSession() on first read so a hard reload restores the signed-in state.
let cached: Session | null | undefined = undefined;

type Listener = (session: Session | null) => void;
const listeners = new Set<Listener>();

/** Set the cache and tell every subscriber. The single mutation point for the session. */
function setSession(next: Session | null): void {
  cached = next;
  notify();
}

/** The current session (cached). Hydrates from localStorage on first call. This is a SYNCHRONOUS
 *  best-effort read: it does not validate the token with the server (use ensureValidSession on boot
 *  for that), so a revoked token still reads as signed-in until the next validation. */
export function currentSession(): Session | null {
  if (cached === undefined) cached = loadSession();
  return cached;
}

/** Whether there is a stored session on this device (best-effort, not server-validated). */
export function isSignedIn(): boolean {
  return currentSession() !== null;
}

/** The label for the signed-in chip: the username if present, else the email, else null. */
export function accountDisplay(): string | null {
  const s = currentSession();
  if (!s) return null;
  return s.account.username || s.account.email || null;
}

/** Boot guard: hydrate the session, then validate it once with the server (GET /v1/auth/me). On a
 *  definite 401 (token revoked/expired) the session is cleared; a network blip keeps it (validateSession
 *  is lenient). On success it refreshes account fields and re-persists. Returns the live session or
 *  null. Safe to call once at startup, before painting the nav. */
export async function ensureValidSession(): Promise<Session | null> {
  const session = loadSession();
  if (!session) {
    setSession(null);
    return null;
  }
  const ok = await validateSession(session);
  if (!ok) {
    clearSession();
    setSession(null);
    return null;
  }
  // validateSession refreshes account fields (e.g. twoFactorEnabled) in place; re-persist them.
  saveSession(session);
  setSession(session);
  return session;
}

/** Adopt a freshly created session (called by the Login screen after register/login/recover/reset).
 *  vault already persisted it via saveSession; this updates the cache + notifies the UI. */
export function adoptSession(session: Session): void {
  setSession(session);
}

/** Sign out: clear storage, reset the cache, and notify subscribers so the nav drops back to signed-out. */
export function signOut(): void {
  clearSession();
  setSession(null);
}

/** Subscribe to sign-in / sign-out. Fires once immediately with the current session, then on every
 *  change. Returns an unsubscribe function. */
export function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  listener(currentSession());
  return () => {
    listeners.delete(listener);
  };
}

function notify(): void {
  const value = cached ?? null;
  for (const listener of listeners) listener(value);
}
