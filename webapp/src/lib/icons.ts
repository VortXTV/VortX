// SF-Symbol-style inline icon set. One source for every glyph the UI draws, so the chrome never falls
// back to bare text characters (the design-system bans `▷ ⌄ ‹ ★ +` literals). Each icon is a 24x24
// viewBox path drawn in `currentColor` and sized to ~1em via the `.ico` class, so an icon inherits the
// colour + font-size of whatever label it sits in (nav link, primary button, chip). Mirrors the
// SF Symbols the Apple app uses (house, safari, chart.bar, magnifyingglass, plus.app, play.fill, …) so
// the web nav + actions read like the native apps rather than a different icon family.

const PATHS: Record<string, string> = {
  // Primary nav (matches the Apple top-nav order: Home · Discover · Library · Search · Add-ons)
  home: '<path fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" d="M4 11 12 4l8 7v8a1 1 0 0 1-1 1h-4v-6h-6v6H5a1 1 0 0 1-1-1z"/>',
  discover:
    '<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M15.6 8.4 13 13l-4.6 2.6L11 11z" fill="currentColor"/>',
  live:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M8.5 8.8a4.5 4.5 0 0 0 0 6.4M15.5 8.8a4.5 4.5 0 0 1 0 6.4M6 6.3a8 8 0 0 0 0 11.4M18 6.3a8 8 0 0 1 0 11.4"/></g><circle cx="12" cy="12" r="2" fill="currentColor"/>',
  library:
    '<g fill="currentColor"><rect x="4" y="10" width="3.6" height="9" rx="1"/><rect x="10.2" y="5" width="3.6" height="14" rx="1"/><rect x="16.4" y="13" width="3.6" height="6" rx="1"/></g>',
  search:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="11" cy="11" r="6"/><path d="m20 20-4.2-4.2"/></g>',
  addons:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="3.5" y="3.5" width="17" height="17" rx="4.5"/><path d="M12 8.5v7M8.5 12h7"/></g>',
  settings:
    '<path fill="currentColor" d="M19.4 13c.04-.33.06-.66.06-1s-.02-.67-.06-1l2.11-1.65a.5.5 0 0 0 .12-.64l-2-3.46a.5.5 0 0 0-.61-.22l-2.49 1a7.3 7.3 0 0 0-1.73-1l-.38-2.65A.5.5 0 0 0 14 2h-4a.5.5 0 0 0-.5.42l-.38 2.65c-.62.25-1.2.59-1.73 1l-2.49-1a.5.5 0 0 0-.61.22l-2 3.46a.5.5 0 0 0 .12.64L4.6 11c-.04.33-.06.66-.06 1s.02.67.06 1l-2.11 1.65a.5.5 0 0 0-.12.64l2 3.46c.14.24.42.32.61.22l2.49-1c.53.41 1.11.75 1.73 1l.38 2.65c.04.24.25.42.5.42h4c.25 0 .46-.18.5-.42l.38-2.65c.62-.25 1.2-.59 1.73-1l2.49 1c.19.1.47.02.61-.22l2-3.46a.5.5 0 0 0-.12-.64L19.4 13zM12 15.5a3.5 3.5 0 1 1 0-7 3.5 3.5 0 0 1 0 7z"/>',
  account:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="8" r="3.6"/><path d="M5 20c0-3.3 3.1-5.5 7-5.5s7 2.2 7 5.5"/></g>',

  // Actions
  play: '<path d="M8 5.4v13.2l11-6.6z" fill="currentColor"/>',
  trailer:
    '<rect x="3" y="5" width="18" height="14" rx="2.6" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M10 9.6v4.8l4-2.4z" fill="currentColor"/>',
  star: '<path d="M12 3.6l2.6 5.27 5.82.85-4.21 4.1.99 5.79L12 16.88 6.8 19.61l.99-5.79-4.21-4.1 5.82-.85z" fill="currentColor"/>',
  bookmark:
    '<path d="M6 4h12v17l-6-4-6 4z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>',
  bookmarkFill: '<path d="M6 4h12v17l-6-4-6 4z" fill="currentColor"/>',
  share:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 15V4.5M8.4 7.6 12 4l3.6 3.6"/><path d="M6 11v8a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-8"/></g>',
  quality:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m8 10 4-4 4 4M8 14l4 4 4-4"/></g>',
  sources:
    '<g fill="currentColor"><circle cx="4.5" cy="7" r="1.3"/><circle cx="4.5" cy="12" r="1.3"/><circle cx="4.5" cy="17" r="1.3"/></g><g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M9 7h11M9 12h11M9 17h11"/></g>',
  back: '<path d="M14.5 5 8 12l6.5 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
  check:
    '<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="m8 12.2 2.6 2.6L16 9.4"/></g>',

  // Player chrome
  pause: '<g fill="currentColor"><rect x="7" y="5" width="3.6" height="14" rx="1"/><rect x="13.4" y="5" width="3.6" height="14" rx="1"/></g>',
  "chevron-left": '<path d="M15 5 8 12l7 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
  rewind:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4 7 8l4 4"/><path d="M7 8h6a5 5 0 1 1-5 5"/></g>',
  "fast-forward":
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M13 4l4 4-4 4"/><path d="M17 8h-6a5 5 0 1 0 5 5"/></g>',
  subtitles:
    '<g><rect x="3" y="5" width="18" height="14" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.7"/><path d="M6.5 11.5h4M13.5 11.5h4M6.5 14.5h7M15.5 14.5h2" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></g>',
  cast:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7.5V6a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6"/><path d="M3 16a5 5 0 0 1 5 5M3 12a9 9 0 0 1 9 9"/></g><circle cx="3.6" cy="20.4" r="1.2" fill="currentColor"/>',
  pip:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2.5"/></g><rect x="12" y="11" width="7" height="6" rx="1.2" fill="currentColor"/>',
  fullscreen:
    '<g fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9V5a1 1 0 0 1 1-1h4M20 9V5a1 1 0 0 0-1-1h-4M4 15v4a1 1 0 0 0 1 1h4M20 15v4a1 1 0 0 1-1 1h-4"/></g>',
  "volume-x":
    '<g><path d="M4 9v6h3l5 4V5L7 9z" fill="currentColor"/><path d="m16.5 9.5 5 5M21.5 9.5l-5 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></g>',
  "volume-1":
    '<g><path d="M4 9v6h3l5 4V5L7 9z" fill="currentColor"/><path d="M15.5 9.5a4 4 0 0 1 0 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></g>',
  "volume-2":
    '<g><path d="M4 9v6h3l5 4V5L7 9z" fill="currentColor"/><path d="M15.5 9.5a4 4 0 0 1 0 5M18 7a8 8 0 0 1 0 10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></g>',
  camera:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M3 8.5A1.5 1.5 0 0 1 4.5 7H7l1.3-2h7.4L17 7h2.5A1.5 1.5 0 0 1 21 8.5v9A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5z"/><circle cx="12" cy="13" r="3.2"/></g>',
};

export type IconName = keyof typeof PATHS;

/** Inline SVG for `name`, sized to 1em in `currentColor`. `cls` adds extra classes (kept decorative:
 *  `aria-hidden`, so the surrounding label text carries the accessible name). */
export function icon(name: IconName, cls = ""): string {
  const klass = cls ? `ico ${cls}` : "ico";
  return `<svg class="${klass}" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" focusable="false">${PATHS[name]}</svg>`;
}
