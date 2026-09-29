#!/usr/bin/env node
// The board's search box, by meaning as well as words: the same ranking the
// memory helper gives agents (search_briefs in memory-mcp.mjs), read only.
//
//   node packages/core/src/search-briefs.mjs <board root> <query>
//
// Prints one line, `BRIEFS ["20260918-155836", …]`, best first. The marker
// line is what the app reads; anything else on stdout or stderr is logging.
import { resolve } from "node:path";

const [root, ...words] = process.argv.slice(2);
const query = words.join(" ").trim();
if (!root || !query) {
  console.error("usage: search-briefs.mjs <board root> <query>");
  process.exit(2);
}
process.env.DEIKO_ROOT = resolve(root);
const { searchBriefs } = await import("./memory-mcp.mjs");
const found = await searchBriefs({ query, limit: 8 });
console.log(`BRIEFS ${JSON.stringify(found.map((r) => r.brief))}`);
