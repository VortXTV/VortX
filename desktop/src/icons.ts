// SF-Symbol-style inline icon set (ported from the webapp lib/icons.ts) so the desktop chrome never
// falls back to bare text glyphs. Each icon is a 24x24 path in currentColor, sized to ~1em via `.ico`.

const PATHS: Record<string, string> = {
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
  play: '<path d="M8 5.4v13.2l11-6.6z" fill="currentColor"/>',
  trailer:
    '<rect x="3" y="5" width="18" height="14" rx="2.6" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M10 9.6v4.8l4-2.4z" fill="currentColor"/>',
  star: '<path d="M12 3.6l2.6 5.27 5.82.85-4.21 4.1.99 5.79L12 16.88 6.8 19.61l.99-5.79-4.21-4.1 5.82-.85z" fill="currentColor"/>',
  share:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 15V4.5M8.4 7.6 12 4l3.6 3.6"/><path d="M6 11v8a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-8"/></g>',
  quality:
    '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m8 10 4-4 4 4M8 14l4 4 4-4"/></g>',
  sources:
    '<g fill="currentColor"><circle cx="4.5" cy="7" r="1.3"/><circle cx="4.5" cy="12" r="1.3"/><circle cx="4.5" cy="17" r="1.3"/></g><g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M9 7h11M9 12h11M9 17h11"/></g>',
  back: '<path d="M14.5 5 8 12l6.5 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
};

export type IconName = keyof typeof PATHS;

/** Inline SVG for `name`, sized to 1em in currentColor. Decorative (aria-hidden). */
export function icon(name: IconName, cls = ""): string {
  const klass = cls ? `ico ${cls}` : "ico";
  return `<svg class="${klass}" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" focusable="false">${PATHS[name]}</svg>`;
}
