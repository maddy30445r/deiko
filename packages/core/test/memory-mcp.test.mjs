import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  chmodSync, linkSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

import { DEFAULT_MODEL, isReady } from "../src/lib/meaning.mjs";

const script = fileURLToPath(new URL("../src/memory-mcp.mjs", import.meta.url));
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
  writeFileSync(join(b, "context.json"), JSON.stringify({ task: "t-20260918-100000", decidedBy: "you", collection: "shop" }));
  writeFileSync(join(root, "collections.json"), JSON.stringify([{ id: "shop", name: "Shop", hint: "" }]));
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

async function session(root, { model = false } = {}) {
  const env = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("DEIKO_"))), DEIKO_ROOT: root };
  if (!model) env.DEIKO_MEANING_MODEL = "off";
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
  return { call, tool, raw, child, close: () => child.kill() };
}

test("the memory helper speaks MCP and hands back only what a brief already shares", async () => {
  const root = board();
  const before = snapshot(root);
  const s = await session(root);
  try {
    const init = await s.call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
    assert.equal(init.result.serverInfo.name, "deiko-memory");
    const tools = await s.call("tools/list", {});
    assert.deepEqual(tools.result.tools.map((t) => t.name).sort(), ["get_brief", "get_task", "list_tasks", "save_outcome", "search_briefs"]);
    assert.equal((await s.call("no/such", {})).error.code, -32601);

    const found = await s.tool("search_briefs", { query: "price listing" });
    assert.ok(found.value.some((r) => r.brief === "20260918-100000"));
    assert.ok(found.value.every((r) => r.prompt.endsWith("/prompt.txt")));
    assert.equal(found.value.find((r) => r.brief === "20260918-110000")?.project, "Shop", "each result names its project");
    assert.equal(found.value.find((r) => r.brief === "20260918-100000")?.project, "Unsorted");

    // A REMOVED SCREENSHOT IS INVISIBLE TO SEARCH TOO — not only to answers.
    // A match alone would tell the agent something about a screenshot the
    // developer chose to hide, so its words must not surface the brief at all.
    const hidden = await s.tool("search_briefs", { query: REMOVED_WORDS });
    assert.equal(hidden.value.some((r) => r.brief === "20260918-100000"), false, "a removed screenshot's words must not surface its brief");

    const brief = await s.tool("get_brief", { id: "20260918-100000" });
    assert.equal(brief.value.prompt, "the price still shows 99 after I save\n");
    assert.match(brief.value.outcome, /Synced the price/);
    assert.deepEqual(brief.value.screenshots, [join(root, "20260918-100000", "crops", "kept.png")]);
    assert.equal("screenText" in brief.value, false, "the prompt already carries whatever screen text the brief kept — no separate field");
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

test("get_task always compiles its note from the live board, never a stale tasks/<id>.md", async () => {
  const root = board();
  mkdirSync(join(root, "tasks"), { recursive: true });
  // A note left over from before a brief was deleted from the board — it must
  // never be read, let alone quoted back to the agent.
  writeFileSync(join(root, "tasks", "t-20260918-100000.md"), "# STALE TITLE FROM A DELETED BRIEF\nSTALE-SECRET-LINE\n");
  const s = await session(root);
  try {
    const task = await s.tool("get_task", { id: "t-20260918-100000" });
    assert.equal(task.value.note.includes("STALE-SECRET-LINE"), false, "a stale tasks/<id>.md on disk must never be read");
    assert.match(task.value.note, /^# Fix the price display after saving/, "the note is compiled fresh from the live briefs instead");
  } finally {
    s.close();
  }
});

test("get_brief never follows a symlink or hands back a path outside the board", async () => {
  const root = board();
  const dir = join(root, "20260918-100000");
  const outsideDir = mkdtempSync(join(tmpdir(), "deiko-outside-"));
  const secretFile = join(outsideDir, "secret.txt");
  writeFileSync(secretFile, "TOP-SECRET-OUTSIDE-THE-BOARD\n");

  rmSync(join(dir, "prompt.txt"));
  symlinkSync(secretFile, join(dir, "prompt.txt"));
  rmSync(join(dir, "outcome.md"));
  symlinkSync(secretFile, join(dir, "outcome.md"));

  const manifest = JSON.parse(readFileSync(join(dir, "brief.json"), "utf8"));
  manifest.referents.push({ cropPath: secretFile });
  writeFileSync(join(dir, "brief.json"), JSON.stringify(manifest));

  const s = await session(root);
  try {
    const brief = await s.tool("get_brief", { id: "20260918-100000" });
    assert.equal(brief.value.prompt, null, "a symlinked prompt.txt must not be followed");
    assert.equal(brief.value.outcome, null, "a symlinked outcome.md must not be followed");
    assert.equal(brief.value.screenshots.includes(secretFile), false, "a cropPath outside the board must be dropped");
    assert.equal(s.raw.join("\n").includes("TOP-SECRET-OUTSIDE-THE-BOARD"), false, "the outside file's contents must never reach the agent");
  } finally {
    s.close();
  }
});

test("get_brief never reads a hard link to a file outside the board", async () => {
  const root = board();
  const dir = join(root, "20260918-100000");
  const secretFile = join(mkdtempSync(join(tmpdir(), "deiko-outside-")), "secret.txt");
  writeFileSync(secretFile, "TOP-SECRET-HARD-LINKED\n");
  rmSync(join(dir, "prompt.txt"));
  linkSync(secretFile, join(dir, "prompt.txt"));

  const s = await session(root);
  try {
    const brief = await s.tool("get_brief", { id: "20260918-100000" });
    assert.equal(brief.value.prompt, null, "a hard-linked prompt.txt must not be read");
    assert.equal(s.raw.join("\n").includes("TOP-SECRET-HARD-LINKED"), false);
  } finally {
    s.close();
  }
});

test("outcome is redacted as a block, catching a secret on the line after its label, while file paths stay readable", async () => {
  const root = board();
  const dir = join(root, "20260918-100000");
  writeFileSync(join(dir, "outcome.md"), [
    "## Did",
    "Rotated the credentials.",
    "New DB password:",
    "Xk9mQ2vLp8Rt4Zq",
    "",
    "## Files",
    "- src/components/PricingTable.tsx",
    "- apps/macos/Sources/DeikoCapture/MemoryHelper.swift",
  ].join("\n"));
  const s = await session(root);
  try {
    const brief = await s.tool("get_brief", { id: "20260918-100000" });
    assert.equal(brief.value.outcome.includes("Xk9mQ2vLp8Rt4Zq"), false, "a secret on the line after its label must still be caught");
    assert.match(brief.value.outcome, /- src\/components\/PricingTable\.tsx/, "a plain file path must stay readable");
    assert.match(brief.value.outcome, /- apps\/macos\/Sources\/DeikoCapture\/MemoryHelper\.swift/);
  } finally {
    s.close();
  }
});

test("search cannot be used to confirm a guessed secret", async () => {
  const root = board();
  const s = await session(root);
  try {
    const guess = await s.tool("search_briefs", { query: FAKE_KEY.slice(0, 13) });
    assert.equal(guess.value.some((r) => r.brief === "20260918-100000"), false, "a fragment of a secret on screen must not surface its brief");
  } finally {
    s.close();
  }
});

test("the search index is cached per session and refreshed when its files change", async () => {
  const root = board();
  const dir = join(root, "20260918-110000");
  const s = await session(root);
  try {
    const before = await s.tool("search_briefs", { query: "GIZMO-FRESH-TERM" });
    assert.equal(before.value.some((r) => r.brief === "20260918-110000"), false);

    mkdirSync(join(dir, "crops"), { recursive: true });
    writeFileSync(join(dir, "events.jsonl"), `${JSON.stringify({ type: "probe", t: 1, windowTitle: "GIZMO-FRESH-TERM window" })}\n`);
    const future = new Date(Date.now() + 60_000);
    utimesSync(join(dir, "events.jsonl"), future, future);

    const after = await s.tool("search_briefs", { query: "GIZMO-FRESH-TERM" });
    assert.ok(after.value.some((r) => r.brief === "20260918-110000"), "a session's new words must be searchable without restarting the helper");
  } finally {
    s.close();
  }
});

test("a board this Mac can't read returns a clear tool error, not an empty list", async () => {
  const blocked = mkdtempSync(join(tmpdir(), "deiko-blocked-"));
  chmodSync(blocked, 0o000);
  try {
    const s = await session(blocked);
    try {
      const r = await s.tool("search_briefs", { query: "anything" });
      assert.equal(r.isError, true);
      assert.match(r.value, /can.t read .*EACCES/);
    } finally {
      s.close();
    }
  } finally {
    chmodSync(blocked, 0o700);
  }
});

test("a null or non-object JSON-RPC line gets an error reply, never a crash", async () => {
  const root = board();
  const s = await session(root);
  try {
    for (const bad of ["null", "[]", '"str"', "42"]) s.child.stdin.write(`${bad}\n`);
    // The process must still be alive and answering afterwards.
    const ping = await s.call("ping", {});
    assert.deepEqual(ping.result, {});
    const errs = s.raw.map((l) => JSON.parse(l)).filter((r) => r.id === null && r.error?.code === -32600);
    assert.equal(errs.length, 4, "each malformed line gets an Invalid Request error, not silence or a crash");
  } finally {
    s.close();
  }
});

test("tools/call rejects a prototype method name instead of treating it as a tool", async () => {
  const root = board();
  const s = await session(root);
  try {
    const r = await s.call("tools/call", { name: "constructor", arguments: {} });
    assert.equal(r.result.isError, true);
    assert.match(r.result.content[0].text, /unknown tool/);
  } finally {
    s.close();
  }
});

test("initialize answers with the server's own protocol version, never an echo", async () => {
  const root = board();
  const s = await session(root);
  try {
    const r = await s.call("initialize", { protocolVersion: "2099-99-99", capabilities: {}, clientInfo: { name: "t", version: "0" } });
    assert.notEqual(r.result.protocolVersion, "2099-99-99");
    assert.equal(r.result.protocolVersion, "2025-06-18");
  } finally {
    s.close();
  }
});

test(
  "the meaning model loads once per process, not once per search",
  { skip: !isReady(DEFAULT_MODEL) && "model not downloaded on this Mac" },
  async () => {
    const root = board();
    const s = await session(root, { model: true });
    try {
      const t0 = Date.now();
      await s.tool("search_briefs", { query: "price" });
      const first = Date.now() - t0;
      const t1 = Date.now();
      await s.tool("search_briefs", { query: "listing" });
      const second = Date.now() - t1;
      assert.ok(second * 3 < first, `expected the cached load to make the second search much faster: first ${first}ms, second ${second}ms`);
    } finally {
      s.close();
    }
  },
);

test("a line forgotten in the app is gone from get_task, get_brief and search", async () => {
  const root = board();
  mkdirSync(join(root, "tasks"));
  writeFileSync(join(root, "tasks", "t-20260918-100000.overrides.json"), JSON.stringify({ forget: ["Synced the price after save."] }));
  const s = await session(root);
  try {
    await s.call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } });
    const task = await s.tool("get_task", { id: "t-20260918-100000" });
    assert.doesNotMatch(task.value.note, /Synced the price/);
    const brief = await s.tool("get_brief", { id: "20260918-100000" });
    assert.doesNotMatch(brief.value.outcome ?? "", /Synced the price/);
    const found = await s.tool("search_briefs", { query: "Synced" });
    assert.equal(found.value.length, 0);
  } finally {
    s.close();
  }
});

test("the board's search ranks like the helper, prints one line, and exits (it never starts the helper's server)", async () => {
  const root = board();
  const search = fileURLToPath(new URL("../src/search-briefs.mjs", import.meta.url));
  const env = { ...Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("DEIKO_"))), DEIKO_MEANING_MODEL: "off" };
  const out = await new Promise((resolve, reject) => {
    // stdin left open, as the app's Process leaves it: a server would never exit.
    const child = spawn(process.execPath, [search, root, "price", "listing"], { env, stdio: ["pipe", "pipe", "ignore"] });
    let text = "";
    child.stdout.on("data", (d) => { text += d; });
    const timer = setTimeout(() => { child.kill(); reject(new Error("search-briefs did not exit")); }, 10_000);
    child.on("exit", () => { clearTimeout(timer); resolve(text); });
  });
  const line = out.split("\n").find((l) => l.startsWith("BRIEFS "));
  assert.ok(JSON.parse(line.slice(7)).includes("20260918-110000"));
});

test("save_outcome writes the brief's outcome.md the way every reader parses it, and only there", async () => {
  const root = board();
  const s = await session(root);
  try {
    const saved = await s.tool("save_outcome", {
      brief: "20260918-110000",
      did: ["Refetched the listing after save", "  spread\nover lines  "],
      decided: ["Refetch after save, no cache"],
      open: [],
      files: ["src/listing.ts"],
      retired: ["Clear the cache on save"],
    });
    assert.equal(saved.isError, false);
    const text = readFileSync(join(root, "20260918-110000", "outcome.md"), "utf8");
    assert.equal(text, "## Did\n- Refetched the listing after save\n- spread over lines\n\n## Decided\n- Refetch after save, no cache\n\n## Open\n\n## Files\n- src/listing.ts\n\n## Retired\n- Clear the cache on save\n");
    const task = await s.tool("get_task", { id: "t-20260918-100000" });
    assert.match(task.value.note, /Refetch after save, no cache/, "the next reader sees it at once");

    // A second save replaces the first: the prompt says "rewrite".
    await s.tool("save_outcome", { brief: "20260918-110000", did: ["Second pass"], open: ["Check Safari"] });
    assert.equal(readFileSync(join(root, "20260918-110000", "outcome.md"), "utf8"), "## Did\n- Second pass\n\n## Decided\n\n## Open\n- Check Safari\n\n## Files\n");

    for (const brief of ["../etc", "20260918-999999", "t-20260918-100000", ""]) {
      assert.equal((await s.tool("save_outcome", { brief, did: [], open: [] })).isError, true, `refuses ${brief || "an empty id"}`);
    }
    // A brief folder that is a link planted to aim the write elsewhere.
    const outside = mkdtempSync(join(tmpdir(), "deiko-outside-"));
    symlinkSync(outside, join(root, "20260918-120000"));
    assert.equal((await s.tool("save_outcome", { brief: "20260918-120000", did: ["x"], open: [] })).isError, true);
    assert.deepEqual(readdirSync(outside), [], "nothing written through the link");
    // An outcome.md that is a link is replaced, never written through.
    const target = join(outside, "victim.txt");
    writeFileSync(target, "untouched");
    rmSync(join(root, "20260918-100000", "outcome.md"));
    symlinkSync(target, join(root, "20260918-100000", "outcome.md"));
    assert.equal((await s.tool("save_outcome", { brief: "20260918-100000", did: ["y"], open: [] })).isError, false);
    assert.equal(readFileSync(target, "utf8"), "untouched");
  } finally {
    s.close();
  }
});

test("list_tasks lists every task with where it stands, by project, whatever words it was said in", async () => {
  const root = board();
  const s = await session(root);
  try {
    const all = await s.tool("list_tasks", {});
    assert.equal(all.value.tasks.length, 1);
    const [t] = all.value.tasks;
    assert.deepEqual({ task: t.task, project: t.project, status: t.status, briefs: t.briefs, first: t.first, last: t.last },
      { task: "t-20260918-100000", project: "Shop", status: "no report", briefs: 2, first: "Sep 18", last: "Sep 18" });
    for (const project of ["shop", "Shop", " SHOP "]) assert.equal((await s.tool("list_tasks", { project })).value.tasks.length, 1, project);
    assert.equal((await s.tool("list_tasks", { project: "Unsorted" })).value.tasks.length, 0);
    const unknown = await s.tool("list_tasks", { project: "nope" });
    assert.equal(unknown.isError, true);
    assert.match(unknown.value, /projects: Shop, Unsorted/);
    assert.equal((await s.tool("list_tasks", { open_only: true })).value.tasks.length, 0);

    // Its status follows what the agents reported.
    await s.tool("save_outcome", { brief: "20260918-110000", did: ["Refetched"], open: ["Check Safari"] });
    const open = await s.tool("list_tasks", { open_only: true });
    assert.equal(open.value.tasks[0].status, "open");
    assert.deepEqual(open.value.tasks[0].now, ["Check Safari"]);
    await s.tool("save_outcome", { brief: "20260918-110000", did: ["Checked Safari"], open: [] });
    assert.equal((await s.tool("list_tasks", {})).value.tasks[0].status, "done");
  } finally {
    s.close();
  }
});
