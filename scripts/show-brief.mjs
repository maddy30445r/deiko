#!/usr/bin/env node
/**
 * Print exactly what the bridge would hand Claude Code, byte for byte.
 *
 *   make show-brief              → stdout
 *   make show-brief OUT=/tmp/b.md → a file
 *
 * `brief.md` in the session directory is NOT the payload. The server appends the
 * crop section at delivery time, and it re-runs the fail-closed guard on the way
 * out — so the file on disk is missing the part that tells the agent how to treat
 * screenshots, which is exactly the part worth reading when you are wondering why
 * it did or didn't open one.
 *
 * This exists because "what did we actually send" should never be a question
 * answered by reading the renderer and imagining the result.
 */

import { writeFileSync } from "node:fs";
import { connect } from "./lib/mcp-client.mjs";

const out = process.argv[2];

const { call, close } = await connect();
try {
  const res = await call("tools/call", { name: "get_brief", arguments: {} });
  const text = res.content?.[0]?.text ?? "";

  if (out) {
    writeFileSync(out, text);
    // To stderr, so `make show-brief > file` still yields a clean document.
    console.error(`✓ ${text.length} chars → ${out}`);
  } else {
    process.stdout.write(text.endsWith("\n") ? text : text + "\n");
  }
} finally {
  close();
}
