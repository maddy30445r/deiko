#!/usr/bin/env node
/**
 * DEIKO MEMORY, FOR A CODING AGENT — a stdio MCP server that runs only on
 * this Mac. Claude Code or Cursor spawns it (Settings → "Give Claude Code /
 * Cursor your Deiko memory") and can then search past briefs, open a task's
 * history, or open one brief.
 *
 * SEARCH SEES EVERYTHING HERE, EXCEPT A REMOVED SCREENSHOT; ANSWERS CARRY
 * LITTLE. The index covers the screen text and the event log, because
 * searching happens on this Mac — but a screenshot the developer removed
 * (`crops.excluded.json`) is invisible to the index too, not only to answers:
 * a match alone would tell the agent something about a screenshot the person
 * chose to hide, so its probe (OCR and all) is skipped whole when building
 * the search text, the same skip `screenText` already makes for answers.
 *
 * Every tool answer goes to the agent's cloud model, so answers carry only
 * what a brief already shares: the prompt, the agent's outcome note, task
 * notes, the brief's summary, screen text through `redact` and
 * `assertNoSecrets` (a block that still looks secret is dropped whole), and
 * the paths of screenshots the developer kept. Never a screenshot they
 * removed, never the raw event log, never audio.
 *
 * Read-only. The board is DEIKO_ROOT (default ~/Documents/Deiko).
 */
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { createInterface } from "node:readline";

import { STAMP, briefDate, readBriefLine } from "./lib/context.mjs";
import { assertNoSecrets, redact, redactBlock } from "./lib/redact.mjs";
import { loadEvents } from "./lib/session-io.mjs";
import { TASK_ID, bm25, cosine, groupTasks, readTasks, renderTaskNote, rrf, terms, titleFor } from "./lib/tasks.mjs";
import { loadModel, readVector } from "./lib/meaning.mjs";

const ROOT = (process.env.DEIKO_ROOT ?? join(homedir(), "Documents", "Deiko")).replace(/^~/, homedir());
const MAX_SCREEN_LINES = 200;
/// Labels that may leave (see scripts/lib/labels.mjs): all but `components`.
const SENT_KEYS = ["pages", "sites", "urls", "files", "repo", "docs", "errors", "tickets"];

const readJSON = (p) => { try { return JSON.parse(readFileSync(p, "utf8")); } catch { return null; } };
const readText = (p) => { try { return readFileSync(p, "utf8"); } catch { return null; } };
const stamps = () => { try { return readdirSync(ROOT).filter((n) => STAMP.test(n)).sort(); } catch { return []; } };
const removed = (dir) => new Set(readJSON(join(dir, "crops.excluded.json")) ?? []);
const events = (dir) => { try { return loadEvents(dir).filter((e) => e.type === "probe"); } catch { return []; } };
const said = (text) => redact(String(text ?? "")).replace(/\s+/g, " ").trim().slice(0, 200);

/** Every word this Mac has about a brief, EXCEPT a removed crop's probe.
 *  FOR SEARCH ONLY — never returned. */
function everything(dir, me) {
  const skip = removed(dir);
  const words = [me.summaryLine, me.narration, ...me.windows, ...me.screenTerms, ...Object.values(me.keys ?? {}).flat()];
  if (me.outcome) words.push(...Object.values(me.outcome).flat());
  for (const e of events(dir)) {
    // A removed screenshot is invisible to search too — see the file header.
    if (e.crop?.path && skip.has(basename(e.crop.path))) continue;
    words.push(e.windowTitle, ...(e.snapshot?.elements ?? []).flatMap((el) => [el.value, el.title, el.elementDescription]),
      ...(e.crop?.ocr ?? []).map((o) => o.text));
  }
  return words.filter((w) => typeof w === "string").join(" ");
}

/** Screen text that may leave: kept captures only, each scrubbed as one block
 *  (the unit the redactor judges), dropped whole if anything survives it. */
function screenText(dir) {
  const skip = removed(dir);
  const out = [];
  for (const e of events(dir)) {
    if (e.crop?.path && skip.has(basename(e.crop.path))) continue;
    const lines = [
      ...(e.snapshot?.elements ?? []).map((el) => el.value || el.title || el.elementDescription),
      ...(e.crop?.ocr ?? []).map((o) => o.text),
    ].filter((l) => typeof l === "string" && l.trim()).map((l) => l.trim().slice(0, 200));
    if (!lines.length) continue;
    const clean = redactBlock(lines);
    try {
      assertNoSecrets(["```", ...clean, "```"].join("\n"));
    } catch {
      continue;
    }
    for (const l of clean) if (!out.includes(l)) out.push(l);
    if (out.length >= MAX_SCREEN_LINES) break;
  }
  return out.slice(0, MAX_SCREEN_LINES);
}

/** Screenshots the developer kept: released by the render (`cropPath` set),
 *  not removed since, and still on disk. */
function screenshots(dir) {
  const skip = removed(dir);
  return (readJSON(join(dir, "brief.json"))?.referents ?? [])
    .map((r) => r?.cropPath)
    .filter((p) => typeof p === "string" && !skip.has(basename(p)) && existsSync(p));
}

async function searchBriefs({ query, limit = 8 } = {}) {
  const q = String(query ?? "").trim();
  if (!q) throw new Error("query is required");
  const n = Math.min(Math.max(1, Number(limit) || 8), 20);
  const briefs = stamps().map((id) => ({ id, dir: join(ROOT, id), me: readBriefLine(join(ROOT, id)) }))
    .filter((b) => b.me.narration != null);
  const words = bm25(terms(q), briefs.map((b) => terms(everything(b.dir, b.me))));
  let meaning = briefs.map(() => null);
  const model = await loadModel();
  const qv = model ? await model.embed(q, "query") : null;
  if (qv) meaning = briefs.map((b) => { const v = readVector(b.dir, model.key); return v ? cosine(qv, v) : null; });
  const fused = rrf([{ scores: words.map((s) => (s > 0 ? s : null)), weight: 1 }, { scores: meaning, weight: 1 }]);
  const titles = readTasks(ROOT);
  return briefs.map((b, i) => ({ b, score: fused[i] }))
    .filter((r) => r.score > 0)
    .sort((x, y) => y.score - x.score)
    .slice(0, n)
    .map(({ b }) => {
      const task = b.me.task ?? `t-${b.id}`;
      return {
        brief: b.id, date: briefDate(b.id), task,
        taskTitle: redact(titles.get(task) ?? titleFor(b.me)),
        said: said(b.me.line),
        prompt: join(b.dir, "prompt.txt"),
      };
    });
}

function getTask({ id } = {}) {
  if (!TASK_ID.test(String(id ?? ""))) throw new Error("id must look like t-20260918-155836");
  const board = stamps().map((s) => readBriefLine(join(ROOT, s))).filter((b) => b.line && !b.odds);
  const briefs = groupTasks(board).get(id);
  if (!briefs) throw new Error(`no task ${id} on this Mac`);
  const title = readTasks(ROOT).get(id) ?? titleFor(briefs.at(-1));
  // The compiled note redacts every line it writes; a task of one has no file.
  const note = readText(join(ROOT, "tasks", `${id}.md`)) ?? renderTaskNote({ id, title, briefs });
  return { task: id, title: redact(title), note, briefs: briefs.map((b) => ({ brief: b.id, date: briefDate(b.id), said: said(b.line) })) };
}

function getBrief({ id } = {}) {
  if (!STAMP.test(String(id ?? ""))) throw new Error("id must look like 20260918-155836");
  const dir = join(ROOT, id);
  const manifest = readJSON(join(dir, "brief.json"));
  if (!manifest) throw new Error(`no brief ${id} on this Mac`);
  const me = readBriefLine(dir);
  const s = manifest.summary ?? {};
  const outcome = readText(join(dir, "outcome.md"));
  return {
    brief: id, date: briefDate(id), task: me.task ?? `t-${id}`,
    prompt: readText(join(dir, "prompt.txt")),
    outcome: outcome == null ? null : outcome.split("\n").map(redact).join("\n"),
    summary: {
      narration: redact(String(s.narration ?? "")),
      said: said(me.line),
      apps: (s.apps ?? []).map(redact),
      windows: (s.windows ?? []).map(redact),
      keys: Object.fromEntries(SENT_KEYS.map((k) => [k, (s.keys?.[k] ?? []).map(redact)])),
    },
    screenText: screenText(dir),
    screenshots: screenshots(dir),
  };
}

const TOOLS = [
  {
    name: "search_briefs",
    description: "Search the developer's past Deiko briefs on this Mac: what they said, the screens they pointed at and what agents wrote back. Returns brief ids, dates, their task and one line each. Open one with get_brief, or its task with get_task.",
    inputSchema: { type: "object", properties: { query: { type: "string", description: "What to look for, in plain words" }, limit: { type: "integer", minimum: 1, maximum: 20 } }, required: ["query"] },
  },
  {
    name: "get_task",
    description: "One task's history: its compiled note (where it stands, what was decided, every brief) and its briefs.",
    inputSchema: { type: "object", properties: { id: { type: "string", description: "A task id like t-20260918-155836" } }, required: ["id"] },
  },
  {
    name: "get_brief",
    description: "One brief: the prompt it produced, the agent's outcome note, its summary, scrubbed screen text, and paths of the screenshots the developer kept (open them to look).",
    inputSchema: { type: "object", properties: { id: { type: "string", description: "A brief id like 20260918-155836" } }, required: ["id"] },
  },
];
const HANDLERS = { search_briefs: searchBriefs, get_task: getTask, get_brief: getBrief };

async function answer(msg) {
  switch (msg.method) {
    case "initialize":
      return { protocolVersion: msg.params?.protocolVersion ?? "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "deiko-memory", version: "1" } };
    case "ping":
      return {};
    case "tools/list":
      return { tools: TOOLS };
    case "tools/call": {
      const run = HANDLERS[msg.params?.name];
      if (!run) return { content: [{ type: "text", text: `unknown tool ${msg.params?.name}` }], isError: true };
      try {
        return { content: [{ type: "text", text: JSON.stringify(await run(msg.params.arguments ?? {}), null, 2) }] };
      } catch (err) {
        return { content: [{ type: "text", text: String(err?.message ?? err) }], isError: true };
      }
    }
    default:
      throw Object.assign(new Error(`method not found: ${msg.method}`), { code: -32601 });
  }
}

const send = (obj) => process.stdout.write(JSON.stringify(obj) + "\n");
createInterface({ input: process.stdin }).on("line", async (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
    return;
  }
  if (msg.id === undefined || msg.id === null) return; // a notification: no answer
  try {
    send({ jsonrpc: "2.0", id: msg.id, result: await answer(msg) });
  } catch (err) {
    send({ jsonrpc: "2.0", id: msg.id, error: { code: err.code ?? -32603, message: String(err?.message ?? err) } });
  }
});
