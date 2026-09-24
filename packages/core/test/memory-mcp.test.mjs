import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../memory-mcp.mjs", import.meta.url));
const FAKE_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
// Chosen with no word or 3-gram in common with anything else on this fixture
// board, so a match can only come from the removed crop's own text, never
// from an incidental trigram overlap with unrelated (kept) words elsewhere.
const REMOVED_WORDS = "PURGED-VANISHED-GONE";

function board() {
  const root = mkdtempSync(join(tmpdir(), "deiko-memory-"));
  const a = join(root, "20260918-100000");
  const b = join(root, "20260918-110000");
  for (const dir of [a, b]) mkdirSync(join(dir, "crops"), { recursive: true });
  const kept = join(a, "crops", "kept.png");
  const gone = join(a, "crops", "gone.png");
  writeFileSync(kept, "");
  writeFileSync(gone, "");
  writeFileSync(join(a, "brief.json"), JSON.stringify({
    summary: { narration: "the price still shows 99 after I save", apps: ["Google Chrome"], windows: ["Pricing — build"], keys: { pages: ["Pricing"], components: ["never handed back"] }, screenTerms: ["price"] },
    // A stale brief.json that still lists the removed crop: the helper must check the exclusion itself.
    referents: [{ cropPath: kept }, { cropPath: gone }],
  }));
  writeFileSync(join(a, "review-summary.txt"), "Fix the price display after saving.\n");
  writeFileSync(join(a, "prompt.txt"), "the price still shows 99 after I save\n");
  writeFileSync(join(a, "outcome.md"), "## Did\nSynced the price after save.\n");
  writeFileSync(join(a, "crops.excluded.json"), JSON.stringify(["gone.png"]));
  writeFileSync(join(a, "events.jsonl"), [
    { type: "probe", t: 1, windowTitle: "Pricing — build", snapshot: { elements: [{ value: "Price settings" }] }, crop: { path: kept, ocr: [{ text: `aws_secret_access_key = ${FAKE_KEY}` }] } },
    { type: "probe", t: 2, windowTitle: "Pricing — build", snapshot: { elements: [] }, crop: { path: gone, ocr: [{ text: `${REMOVED_WORDS} on the removed shot` }] } },
  ].map((e) => JSON.stringify(e)).join("\n") + "\n");
  writeFileSync(join(b, "brief.json"), JSON.stringify({ summary: { narration: "same price bug on the listing page", apps: [], windows: [] }, referents: [] }));
  writeFileSync(join(b, "context.json"), JSON.stringify({ task: "t-20260918-100000", decidedBy: "you" }));
  return root;
}

function snapshot(dir) {
  const out = [];
  const walk = (d) => {
    for (const n of readdirSync(d).sort()) {
      const p = join(d, n);
      const s = statSync(p);
      if (s.isDirectory()) walk(p); else out.push(`${p} ${s.size} ${s.mtimeMs}`);
    }
  };
  walk(dir);
  return out;
}

async function session(root) {
  const env = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("DEIKO_"))), DEIKO_ROOT: root, DEIKO_MEANING_MODEL: "off" };
  const child = spawn(process.execPath, [script], { env, stdio: ["pipe", "pipe", "ignore"] });
  const waiting = new Map();
  const raw = [];
  createInterface({ input: child.stdout }).on("line", (line) => {
    raw.push(line);
    const msg = JSON.parse(line);
    waiting.get(msg.id)?.(msg);
  });
  let next = 1;
  const call = (method, params) => new Promise((resolve) => {
    const id = next++;
    waiting.set(id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
  const tool = async (name, args) => {
    const r = await call("tools/call", { name, arguments: args });
    return { isError: r.result.isError === true, value: r.result.isError ? r.result.content[0].text : JSON.parse(r.result.content[0].text) };
  };
  return { call, tool, raw, close: () => child.kill() };
}

test("the memory helper speaks MCP and hands back only what a brief already shares", async () => {
  const root = board();
  const before = snapshot(root);
  const s = await session(root);
  try {
    const init = await s.call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
    assert.equal(init.result.serverInfo.name, "deiko-memory");
    const tools = await s.call("tools/list", {});
    assert.deepEqual(tools.result.tools.map((t) => t.name).sort(), ["get_brief", "get_task", "search_briefs"]);
    assert.equal((await s.call("no/such", {})).error.code, -32601);

    const found = await s.tool("search_briefs", { query: "price listing" });
    assert.ok(found.value.some((r) => r.brief === "20260918-100000"));
    assert.ok(found.value.every((r) => r.prompt.endsWith("/prompt.txt")));

    // A REMOVED SCREENSHOT IS INVISIBLE TO SEARCH TOO — not only to answers.
    // A match alone would tell the agent something about a screenshot the
    // developer chose to hide, so its words must not surface the brief at all.
    const hidden = await s.tool("search_briefs", { query: REMOVED_WORDS });
    assert.equal(hidden.value.some((r) => r.brief === "20260918-100000"), false, "a removed screenshot's words must not surface its brief");

    const brief = await s.tool("get_brief", { id: "20260918-100000" });
    assert.equal(brief.value.prompt, "the price still shows 99 after I save\n");
    assert.match(brief.value.outcome, /Synced the price/);
    assert.deepEqual(brief.value.screenshots, [join(root, "20260918-100000", "crops", "kept.png")]);
    assert.ok(brief.value.screenText.includes("Price settings"));
    assert.equal(brief.value.summary.keys.pages[0], "Pricing");
    assert.equal("components" in brief.value.summary.keys, false);

    const task = await s.tool("get_task", { id: "t-20260918-100000" });
    assert.equal(task.value.briefs.length, 2);
    assert.match(task.value.note, /^# Fix the price display after saving/);

    assert.equal((await s.tool("get_brief", { id: "../etc" })).isError, true);
    assert.equal((await s.tool("get_task", { id: "t-../../x" })).isError, true);

    const everything = s.raw.join("\n");
    assert.equal(everything.includes(FAKE_KEY), false, "a key on screen never leaves");
    assert.equal(everything.includes(REMOVED_WORDS), false, "nor a removed screenshot's words");
    assert.equal(everything.includes("gone.png"), false, "nor the removed screenshot");
    assert.equal(everything.includes("never handed back"), false, "nor components");
  } finally {
    s.close();
  }
  assert.deepEqual(snapshot(root), before, "the helper writes nothing");
});
