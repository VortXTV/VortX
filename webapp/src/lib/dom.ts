// Tiny DOM helpers shared across the views. Kept dependency-free: the web client renders plain HTML
// strings (matching the desktop frontend's render-to-innerHTML style) and wires clicks via delegation.

/** Escape interpolated text so add-on-supplied strings (names, descriptions) can't inject markup. */
export function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string,
  );
}

/** Only return a value that is a real http(s) URL, so we never set src/href to a hostile scheme. */
export function httpUrl(value: string | undefined): string {
  return value && /^https?:\/\//i.test(value) ? value : "";
}

/** Look up an element by id (typed). */
export function el<T extends HTMLElement = HTMLElement>(id: string): T | null {
  return document.getElementById(id) as T | null;
}

/** The nearest ancestor (or self) carrying `data-action`, and its action value. */
export function actionOf(target: EventTarget | null): { node: HTMLElement; action: string } | null {
  if (!(target instanceof HTMLElement)) return null;
  const node = target.closest<HTMLElement>("[data-action]");
  const action = node?.dataset.action;
  return node && action ? { node, action } : null;
}
