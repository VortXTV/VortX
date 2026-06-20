// A minimal hash router. Routes are shareable (the URL fully describes the surface) per the web rules'
// "URL as state" guidance: filters/search/active title all live in the hash, so a refresh or a shared
// link restores the same view. Hash routing keeps Cloudflare Pages config trivial (no SPA rewrite
// needed for navigation, only the index fallback for deep links - see public/_redirects).

export type Route =
  | { name: "home" }
  | { name: "discover"; type: string }
  | { name: "search"; query: string }
  | { name: "detail"; type: string; id: string }
  | { name: "addons" }
  | { name: "library" }
  | { name: "live" }
  | { name: "settings" }
  | { name: "login" };

/** Parse the current `location.hash` into a typed Route, defaulting to Home. */
export function parseRoute(): Route {
  const hash = location.hash.replace(/^#\/?/, "");
  const [path, ...rest] = hash.split("/");
  const tail = rest.join("/");

  switch (path) {
    case "discover":
      return { name: "discover", type: decodeURIComponent(rest[0] ?? "movie") };
    case "search":
      return { name: "search", query: decodeURIComponent(tail) };
    case "detail": {
      const type = decodeURIComponent(rest[0] ?? "");
      const id = decodeURIComponent(rest.slice(1).join("/"));
      if (type && id) return { name: "detail", type, id };
      return { name: "home" };
    }
    case "addons":
      return { name: "addons" };
    case "library":
      return { name: "library" };
    case "live":
      return { name: "live" };
    case "settings":
      return { name: "settings" };
    case "login":
      return { name: "login" };
    default:
      return { name: "home" };
  }
}

/** Build a hash for a route (used by anchors + programmatic navigation). */
export function hashFor(route: Route): string {
  switch (route.name) {
    case "home":
      return "#/";
    case "discover":
      return `#/discover/${encodeURIComponent(route.type)}`;
    case "search":
      return `#/search/${encodeURIComponent(route.query)}`;
    case "detail":
      return `#/detail/${encodeURIComponent(route.type)}/${encodeURIComponent(route.id)}`;
    case "addons":
      return "#/addons";
    case "library":
      return "#/library";
    case "live":
      return "#/live";
    case "settings":
      return "#/settings";
    case "login":
      return "#/login";
  }
}

/** Navigate to a route (updates the hash, which triggers the onRouteChange listener). */
export function navigate(route: Route): void {
  location.hash = hashFor(route);
}

/** Subscribe to route changes; fires once immediately with the current route. */
export function onRouteChange(handler: (route: Route) => void): void {
  window.addEventListener("hashchange", () => handler(parseRoute()));
  handler(parseRoute());
}
