#!/usr/bin/env node

// Compatibility entry point. Release automation uses the shared feed implementation so local
// backfills and the protected release path cannot silently produce different schemas.
import { main } from "./release-feed.mjs";

main(["update-altstore", ...process.argv.slice(2)]);
