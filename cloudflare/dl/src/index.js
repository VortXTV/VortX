// dl.vortx.tv: one short address for the newest VortX builds.
//   /            -> the Android APK (the TV sideload headline path)
//   /apk         -> the Android APK
//   /mac         -> the macOS dmg
//   /ios         -> the iPhone/iPad IPA
//   /tvos        -> the Apple TV IPA
//   /tvos-lite   -> the Apple TV Lite IPA
//   /latest      -> the release page itself
// Anything unmatched, and any upstream hiccup, falls back to the release page:
// this address must never dead-end, so every response is a hand-built 302 (no
// throwing constructors) and the whole handler is fenced.

const RELEASES_PAGE = "https://github.com/VortXTV/VortX/releases/latest";
const API_LATEST = "https://api.github.com/repos/VortXTV/VortX/releases/latest";

const PICKERS = {
  "": (n) => n.endsWith(".apk"),
  "apk": (n) => n.endsWith(".apk"),
  "mac": (n) => n.endsWith(".dmg"),
  "ios": (n) => n.includes("VortX-iOS") && n.endsWith(".ipa"),
  "tvos": (n) => n.includes("VortX-tvOS") && !n.includes("lite") && n.endsWith(".ipa"),
  "tvos-lite": (n) => n.includes("VortX-tvOS-lite") && n.endsWith(".ipa"),
};

const go = (url) => new Response(null, { status: 302, headers: { "Location": url, "Cache-Control": "no-store" } });

async function latestAssetURL(pick) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const res = await fetch(API_LATEST, {
        headers: { "User-Agent": "vortx-dl", "Accept": "application/vnd.github+json" },
        cf: { cacheEverything: true, cacheTtlByStatus: { "200-299": 300, "300-599": 0 } },
      });
      if (!res.ok) continue;
      const release = await res.json();
      const asset = (release.assets || []).find((a) => a && typeof a.name === "string" && pick(a.name));
      if (asset && typeof asset.browser_download_url === "string") return asset.browser_download_url;
      return null;
    } catch {
      // fall through to retry, then to the release page
    }
  }
  return null;
}

export default {
  async fetch(request) {
    try {
      const path = new URL(request.url).pathname.replace(/^\/+|\/+$/g, "").toLowerCase();
      if (path === "latest") return go(RELEASES_PAGE);
      const pick = PICKERS[path];
      if (!pick) return go(RELEASES_PAGE);
      const url = await latestAssetURL(pick);
      return go(url || RELEASES_PAGE);
    } catch {
      return go(RELEASES_PAGE);
    }
  },
};
