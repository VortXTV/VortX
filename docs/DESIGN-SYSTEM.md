# VortX Design System (single source of truth)

One design, every platform. This is the canonical spec every VortX surface builds to: Apple
(tvOS/iOS/iPad/Mac, the reference implementation), Web (`web.vortx.tv`), Desktop (Tauri), and Android.
Different stacks, identical result. Derived from `app/SourcesShared/Theme.swift` + `ThemeManager.swift`
(the code is the source of truth, not the old `DESIGN.md`, which lagged on the ember->gold switch).

**Rule:** a screen is "done" only when it matches this spec on every platform. The only allowed
cross-platform difference is capability, never look: the web client has **no built-in streaming server**
(the tvOS-Lite model), so torrents are surfaced-but-not-playable there unless a server is connected.

---

## 1. Principles (from PRODUCT.md)
1. **Content is the light.** Poster/backdrop art is the only saturated color on screen; the chrome is
   warm monochrome and recedes. If a UI element competes with the artwork, the UI is wrong.
2. **One primary action.** Every screen has exactly one dominant CTA (the gold Watch/Play/Details
   button). Everything else is a neutral chip. No screen has scattered equal-weight buttons.
3. **Curated, not a firehose.** Generous, intentional rhythm; a few things feel important.
4. **Cinematic + honest.** Restraint over flash. No fake premium sheen, no borrowed trade dress.
5. **Consistent everywhere.** One spacing scale, one type scale, one accent meaning, one focus
   treatment, on every platform.

---

## 2. Foundations (tokens)

### Palette (default "vortx" gold theme; the chrome is user-themeable, gold is the shipping default)
| Token | Hex | Use |
|---|---|---|
| `canvas` | `#15120E` | app background (warm near-black) |
| `surface1` | `#211C16` | rows, cards, panels |
| `surface2` | `#2D261D` | chips, controls, elevated |
| `surface3` | `#3A3127` | hover / selected fill |
| `hairline` | `#403629` | 1px dividers ONLY (never for elevation) |
| `textPrimary` | `#F6F1E9` | titles, primary text |
| `textSecondary` | `#BCB1A1` | secondary text, labels |
| `textTertiary` | `#9E9485` | captions, disabled (raised from #8C8273 for 4.5:1 on canvas) |
| `accent` | `#D97706` | focus / selection / primary action / progress (VortX gold) |
| `accentBright` | `#F59E0B` | focus glow, hover, rating star |
| `accentSoft` | `rgba(217,119,6,0.18)` | selected-chip fill, glow base |
| `onAccent` | `#0F0D0A` | text/icon ON the gold fill (obsidian ink) |
| `danger` | `#DE4856` | destructive (log out, remove) |

Themeable accents (chrome only; never change the layout): vortx gold (default), ember `#F27849` (the
previous default accent), ocean, forest, royal, crimson, gold `#E2B44A`, rose, mono. Plus OLED true-black
canvas option. Accent recolors the mark + all accent uses live.

### Typography
Two families: **serif = New York** (`Iowan Old Style`/Georgia fallback) for the wordmark + hero/screen
titles (the editorial-cinema signature); **UI = SF Pro** (`SF Pro Display`/`SF Pro Text`, system
fallback) for everything else. Web-scaled below (a touch smaller than the 10-foot tvOS sizes).

| Role | Web (clamp) | Weight / tracking | Family |
|---|---|---|---|
| hero | `clamp(40px,4vw+1rem,64px)` | 800, -1.5px | serif |
| screen title | `clamp(30px,3vw+1rem,48px)` | 700, -1px | serif |
| section title | `clamp(20px,1.4vw+1rem,28px)` | 600, -0.3px | sans |
| card title | `1.2rem` | 600 | sans |
| body | `clamp(16px,0.4vw+1rem,18px)` lh 1.5 | 400 | sans |
| label | `0.95rem` | 500 | sans |
| eyebrow | `0.74rem`, +1.5px, UPPERCASE, accent | 700 | sans |

### Spacing (8pt)
`xs 8 · sm 12 · md 20 · lg 32 · xl 48 · xxl 72`. `edge = clamp(20px,5vw,60px)` for screen insets.
**Rhythm rule:** section-to-section gaps = `xl`; readable-column block gaps = `lg`; in-card gaps =
`sm`. Never one value everywhere.

### Radius / elevation / motion
- Radius: `card 16 · chip 12 · control 14 · pill 999`.
- Elevation (NO borders for elevation): `rest 0 7px 12px rgba(0,0,0,.32)`, `focus 0 10px 16px
  rgba(0,0,0,.45)`, `glow-accent 0 0 18px rgba(217,119,6,.6)`.
- Motion: spring `cubic-bezier(.2,.8,.2,1)`, state change `180ms`, hero/focus `~320ms`. Animate
  transform/opacity/shadow ONLY. Press = `scale(.97)`. Respect reduced-motion (drop transforms).

### The mark + wordmark + splash
- **Mark:** two woven gradient ribbons forming an X + a cream center dot. Front ribbon bright gold
  gradient (`#FBBF24 -> #F59E0B -> #D97706`) crossing OVER the deeper back ribbon (`#B45309 ->
  #7C2D12`); cream dot `#FDF6E3`. Canonical geometry in `vortx-site/src/components/Mark.astro` +
  `SplashView.swift`. The in-app header mark may recolor to the live accent; the splash + app icon keep
  the fixed brand gold.
- **Wordmark:** "Vort" in the serif face + the mark as the "X".
- **Splash:** warm radial obsidian (`#18130c -> #0c0a07`); ember glow blooms, ribbons draw on
  (front delayed), cream dot pops, then "Everything. / VortXed." rises (VortX in gold). ~2.8s, lifts
  itself via CSS, once per session, reduced-motion shows static/none. Canonical:
  `vortx-site/src/components/Splash.astro` (port verbatim; web already does).

---

## 3. Components
- **Primary button** (the one gold CTA): accent fill, `onAccent` text, control radius, leading icon,
  `15px 32px` padding, 1.05-1.1rem 700. Hover: `accentBright` + lift + glow. Press: `scale(.97)`.
  Disabled/loading: surface2 fill, muted text, no shadow.
- **Chip** (every secondary control: Quality, Sources, Trailer, Save, Share, season, filters, type
  switch, nav links): surface2 fill, chip radius, label text, `~0.62rem 1rem`. Hover surface3. Selected
  = accentSoft fill + accentBright text + inset 1px accent ring. The single selected look everywhere.
- **Surface card** (rows + panels): surface1 fill, card radius, `rest` shadow. NEVER nest cards.
- **Poster card:** 2:3 art, card radius, `rest` shadow, title below in label. Hover/focus: lift +
  scale(~1.03) + glow + title brightens to textPrimary. Watched: dim + check badge. In-progress: a 3px
  accent progress track under the art.
- **Source row:** surface-card row, leading play/▷ icon, a prominent quality badge (4K/1080p) +
  add-on badge + TORRENT badge, then flavour tags + size, then the release title (2-line clamp).
- **Episode row:** thumb (16:9) + watched check + progress stripe; code + title; air date; overview
  (2-line). Dim watched.
- **States (one canonical set, compositor-only):** hover = lift + focus-shadow (+glow on poster/
  primary); focus-visible = 2px accentBright outline offset 2-3px; press = scale(.97); selected =
  accentSoft + accentBright + inset accent ring; disabled = surface2 + muted, no shadow/transform.
- **Empty/loading/error:** composed surface-card with a line of guidance + one chip action; skeleton
  shimmer for loading (never a bare spinner as the whole state). No `window.alert`.

---

## 4. Screen blueprints (the layout every platform builds)

### Home
Featured hero (top) -> Continue Watching rail -> catalog rails.
- **Featured hero:** full-bleed billboard (`height clamp(380px,52vh,560px)`, card radius) of a top
  item: backdrop (`background||poster`), dual scrim (vertical fade to canvas + leading fade), bottom-
  left content (logo or `t-hero` title, single-line meta, 3-line synopsis, a `btn-primary` "Details" +
  a "Trailer" chip). Auto-rotates ~5 top items every ~6s (cross-fade); pause on hover / `document.hidden`;
  reduced-motion = static item 0; dispose the interval on route leave.
- **Rails:** each rail = `t-eyebrow` (add-on/source kind) + `t-section` title, then a horizontal poster
  scroll. Board section gaps = `xl`.

### Detail
Fixed hero banner -> readable content column.
- **Hero banner** (`height clamp(320px,42vh,560px)`, NOT a full-page wash): backdrop + dual scrim;
  bottom-left title block (logo or `t-hero` title + single-line meta row: ★rating, year · runtime ·
  genres); contextual Back chip top-left (Home, or Episodes for an open episode).
- **Content column** (`max-width ~940px`, centered, `lg` gaps): the `.hero-actions` cluster (the one
  `btn-primary` Watch/Resume + Quality chip + Sources chip + Save + Share + Trailer, all wrapping on one
  row) -> synopsis (`t-body`) -> credits (Cast/Director/Writer) -> [series: season selector + episode
  list]. Quality picker + all-sources list open in ONE elevated surface-card panel below the cluster.
- Series open-episode: hero shows the episode context; body = the cluster (episode Watch) + overview.

### Discover / Search
Type switch / search form -> dense poster grid (`auto-fill minmax`) -> "Load more" (per-catalog skip).
Search results live in the URL (shareable). Recent searches as chips when empty.

### Library
Saved poster grid with the remove (x) control; same poster card.

### Add-ons
Title + the debrid explainer (direct HTTPS vs debrid as two distinct source types; the key-in-manifest
model; named debrid add-ons) -> install-by-URL form -> installed list (surface-card rows).

### Settings / Profiles
Profile card (name, appearance: theme swatches + OLED, text-size) + Playback & language (audio/subtitle
language, subtitles mode). Family-edit toggle. Per-profile, synced. **Min body 16px; never microscopic.**

### Player
Our chrome over the platform's player (web = HTML5 `<video>`/hls.js; Apple = AVPlayer/libmpv; desktop =
mpv; android = Media3). Thin top chrome (Back + title), the platform transport, error feedback on a
failed source. Keyboard: Space/seek/volume/mute/fullscreen/PiP.

---

## 5. Per-platform implementation
- **Apple (reference):** SwiftUI, `Theme.swift`/`ThemeManager`. This spec is extracted from it.
- **Web (`webapp/`):** TS + Vite + CSS render-strings + hls.js. NO engine, NO server (tvOS-Lite): add-on
  protocol direct, direct/debrid/HLS only; torrents need a connected server. The design-system CSS layer
  in `app.css` (`.t-*`, `.btn-primary`, `.chip`, `.surface-card`, tokens) IS the web implementation of
  Section 2-3.
- **Desktop (`desktop/`):** Tauri 2, TS + CSS (same stack as web) + Rust (engine + mpv + node server).
  Builds the SAME design-system CSS + the SAME screen blueprints as web; differs only in the data layer
  (engine-driven) + mpv player + server. Should share the design-system + dumb view-render code with web
  rather than duplicate.
- **Android (`android/`):** Kotlin + Compose + Media3. Cannot share code; mirrors Sections 2-4 as a
  Compose theme + composables. iOS-parity on phone, tvOS-parity on Android TV.

---

## 6. Icons
One SF-Symbol-style inline SVG set (currentColor, ~1em), NEVER bare text glyphs (`▷ ⌄ ‹ ▶ ★ + ✓`).
Names: play-fill, play-circle, arrow-down-circle, chevron-updown, chevron-down, chevron-left,
list-bullet, play-rectangle, bookmark, bookmark-fill, share, star-fill, checkmark-circle. Consistent
weight.

## 7. Anti-patterns (the "looks like a prototype / not VortX" tells)
The old ember accent; bare text glyphs; scattered equal-weight buttons (no clear primary);
flat uniform spacing; nested cards; borders used for elevation; a full-page backdrop wash (the backdrop
is a banner); a generic poster scroller Home with no featured hero; microscopic text; gradient text;
side-stripe accents.
