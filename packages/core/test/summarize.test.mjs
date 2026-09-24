// What `summarize.mjs` sends to Deiko's relay: the narration and which prompt,
// never a prompt. The relay pins its own (services/relay/relay.mjs), because a
// relay that took one from its caller was a free chat endpoint on Deiko's key.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const script = fileURLToPath(new URL("../summarize.mjs", import.meta.url));
const NARRATION = "isko humko class one se class two mein convert karna hai, drag wala bug";

/// Summarise one session against a fake relay, and return what it received.
async function summarizeVia(env = {}) {
  const dir = mkdtempSync(join(tmpdir(), "deiko-summarize-"));
  writeFileSync(join(dir, "brief.json"), JSON.stringify({ summary: { narration: NARRATION } }));
  const seen = [];
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => { raw += c; });
    req.on("end", () => {
      seen.push({ path: req.url, auth: req.headers.authorization, body: JSON.parse(raw) });
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ choices: [{ message: { content: "Convert class one to class two." } }] }));
    });
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  try {
    // Built from nothing, so a developer's own GROQ_API_KEY can never send
    // this test to the real provider.
    await run(process.execPath, [script, dir], {
      env: {
        PATH: process.env.PATH,
        HOME: dir,
        DEIKO_RELAY_URL: `http://127.0.0.1:${server.address().port}/`,
        DEIKO_RELAY_TOKEN: "dev_test",
        ...env,
      },
    });
    return { seen, summary: readFileSync(join(dir, "review-summary.txt"), "utf8") };
  } finally {
    server.close();
    rmSync(dir, { recursive: true, force: true });
  }
}

test("the relay is sent the narration and a mode, and nothing it could bill as a prompt", async () => {
  const { seen, summary } = await summarizeVia();
  assert.equal(seen.length, 1);
  assert.equal(seen[0].path, "/v1/summarize");
  assert.equal(seen[0].auth, "Bearer dev_test");
  assert.deepEqual(seen[0].body, { narration: NARRATION, mode: "hinglish" });
  assert.equal(summary, "Convert class one to class two.\n", "and the answer is still written for the review window");
});

test("'Same as I speak' asks the relay for its native prompt", async () => {
  const { seen } = await summarizeVia({ DEIKO_NARRATION: "native" });
  assert.deepEqual(seen[0].body, { narration: NARRATION, mode: "native" });
});

test("the relay's two prompts are word for word the ones this script sends with a key", () => {
  // Two deployables, one prompt: a BYO-key summary and a relay summary must
  // read the same narration the same way. Compared as the string literals
  // each array is built from.
  const literals = (path, from) => {
    const src = readFileSync(fileURLToPath(new URL(path, import.meta.url)), "utf8");
    const block = src.slice(src.indexOf(from), src.indexOf('].join("\\n")', src.indexOf(from)));
    return [...block.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) => m[1]).filter((s) => s !== "native");
  };
  const mine = literals("../summarize.mjs", "const SYSTEM = [");
  assert.ok(mine.length > 10, "found the prompt");
  assert.deepEqual(literals("../../services/relay/relay.mjs", "const summarySystem = "), mine);
});
