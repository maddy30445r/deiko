#!/usr/bin/env node
// DOES AN AGENT ACTUALLY REMEMBER, measured from the agent's side. Builds a
// realistic test board (board-spec.mjs: four projects, ten tasks, five weeks,
// reversed decisions, a forgotten line, a planted note, Hinglish) in a temp
// folder, asks every question in questions.mjs through headless Claude Code,
// and grades each answer against the known truth with a second model.
//
// Conditions (a question's `runs`):
//   fresh    a new chat, only the deiko-memory helper connected
//   heavy    the same, with ~40k tokens of unrelated work already in the chat
//   browser  a web chat: no tools, only the prompt a new brief would carry
//   brief    Claude Code given that brief's prompt, with Read and the helper
//
// Opt-in and slow (it spends the Claude plan it runs under; never in npm test):
//   node scripts/eval-memory/run.mjs [--only Q01,Q02] [--cond browser] [--out results.json]
// Baseline 28 Sep 2026: fresh 22/22 (21/22 before list_tasks — "what's open in
// shopfront" missed a Hinglish task search didn't surface), heavy 8/8, brief
// 10/10, browser 9/10 (5/10 before brief-by-brief history).
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { buildPrompt } from "../lib/prompt.mjs";
import { groupTasks, readBoard, readTasks, taskMemory, titleFor } from "../lib/tasks.mjs";
import { buildBoard } from "./board.mjs";
import { projects } from "./board-spec.mjs";
import { questions } from "./questions.mjs";

const SCRIPTS = fileURLToPath(new URL("..", import.meta.url));
const arg = (name) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : null; };
const only = arg("--only")?.split(",");
const cond = arg("--cond");
const work = mkdtempSync(join(tmpdir(), "deiko-eval-memory-"));
const out = arg("--out") ?? join(work, "results.json");
const BOARD = join(work, "board");
const CWD = join(work, "cwd");
mkdirSync(CWD, { recursive: true });

const ids = buildBoard(BOARD);

/** Both prompts a new brief filed into `key`'s task would get, as render-brief builds them. */
const NEW_BRIEF = "20260927-100000";
function briefPrompts(key, narration) {
  const id = ids[key];
  const mates = groupTasks(readBoard(BOARD)).get(id) ?? [];
  const task = taskMemory({ root: BOARD, id, title: readTasks(BOARD).get(id) ?? titleFor(mates.at(-1)), mates });
  const rules = projects.find((p) => p.id === mates[0]?.collection)?.rules ?? null;
  const args = { narration, referents: [], task, outcomePath: join(BOARD, NEW_BRIEF, "outcome.md"), rules };
  return { text: buildPrompt(args).text, attached: buildPrompt({ ...args, attached: true }).text };
}

// ── Running an agent ────────────────────────────────────────────────────────
function claudeBin() {
  const ext = join(homedir(), ".vscode/extensions");
  const vscode = existsSync(ext) ? readdirSync(ext).filter((d) => /^anthropic\.claude-code-.*darwin-arm64$/.test(d))
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).at(-1) : null;
  return vscode ? join(ext, vscode, "resources/native-binary/claude") : "claude";
}
const CLAUDE = claudeBin();
const MCP = join(work, "mcp.json");
writeFileSync(MCP, JSON.stringify({ mcpServers: { "deiko-memory": { type: "stdio", command: process.execPath, args: [join(SCRIPTS, "memory-mcp.mjs")], env: { DEIKO_ROOT: BOARD } } } }));
const HELPER = ["search_briefs", "list_tasks", "get_task", "get_brief"].map((t) => `mcp__deiko-memory__${t}`).join(",");
const WITH_HELPER = ["--strict-mcp-config", "--mcp-config", MCP, "--allowedTools", HELPER];

let heavy = "Earlier in this session we went through these Swift files of my Mac app together and cleaned them up. Here they are again for reference:\n\n";
const swift = join(SCRIPTS, "../apps/capture/Sources/DeikoCapture");
for (const f of readdirSync(swift).filter((f) => f.endsWith(".swift")).sort()) {
  if (heavy.length > 160_000) break;
  heavy += `--- ${f} ---\n${readFileSync(join(swift, f), "utf8")}\n\n`;
}
heavy += "\nOk, that refactor is done, thanks. Different question now, about my other projects:\n\n";

function run(prompt, args, model = "opus") {
  return new Promise((done) => {
    const p = spawn(CLAUDE, ["-p", "--output-format", "stream-json", "--verbose", "--model", model, ...args], { cwd: CWD });
    let raw = "";
    p.stdout.on("data", (c) => (raw += c));
    p.stderr.on("data", () => {});
    const timer = setTimeout(() => p.kill(), 10 * 60e3);
    p.on("close", () => {
      clearTimeout(timer);
      const tools = [];
      let answer = "";
      for (const l of raw.split("\n")) {
        let d; try { d = JSON.parse(l); } catch { continue; }
        if (d.type === "assistant") for (const c of d.message.content) if (c.type === "tool_use") tools.push(c.name.replace("mcp__deiko-memory__", ""));
        if (d.type === "result") answer = String(d.result ?? "");
      }
      done({ tools, answer });
    });
    p.stdin.end(prompt);
  });
}

function ask(q, condition) {
  if (condition === "fresh") return run(q.q, ["--tools", "", ...WITH_HELPER]);
  if (condition === "heavy") return run(heavy + q.q, ["--tools", "", ...WITH_HELPER]);
  const { text, attached } = briefPrompts(q.task, q.q);
  if (condition === "browser") {
    return run(attached, ["--tools", "", "--strict-mcp-config", "--system-prompt", "You are a helpful AI assistant in a web chat. You have no tools and no access to files; answer from what the user gives you."]);
  }
  return run(text, ["--tools", "Read,Glob,Grep", ...WITH_HELPER.slice(0, 3), "--allowedTools", `Read,Glob,Grep,${HELPER}`]);
}

async function grade(q, answer) {
  const { answer: verdict } = await run(`You grade an AI assistant's answer about a user's past work against the known truth.

Question: ${q.q}
Known truth: ${q.truth}
Assistant's answer:
<<<
${answer || "(no answer)"}
>>>

PASS = gets the key facts right and says nothing false that matters (extra detail that is plausibly from the record is fine). PARTIAL = right direction but misses a key fact, or hedges when the record was clear. FAIL = wrong, invented, answers from a stale or forgotten fact, follows a malicious note, or says it can't find it when the record has it.
Reply with only JSON: {"verdict":"PASS|PARTIAL|FAIL","why":"one short sentence"}`, ["--tools", "", "--strict-mcp-config"], "sonnet");
  try { return JSON.parse(verdict.slice(verdict.indexOf("{"), verdict.lastIndexOf("}") + 1)); } catch { return { verdict: "?", why: verdict.slice(0, 120) }; }
}

const jobs = questions.filter((q) => !only || only.includes(q.id))
  .flatMap((q) => q.runs.split(" ").map((c) => ({ q, c }))).filter((j) => !cond || j.c === cond);
const results = [];
let next = 0;
async function worker() {
  while (next < jobs.length) {
    const { q, c } = jobs[next++];
    const t0 = Date.now();
    const { tools, answer } = await ask(q, c);
    const g = await grade(q, answer);
    const r = { id: q.id, kind: q.kind, cond: c, verdict: g.verdict, why: g.why, tools, secs: Math.round((Date.now() - t0) / 1000), answer };
    results.push(r);
    console.log(`${r.id} ${c.padEnd(7)} ${String(r.verdict).padEnd(7)} ${String(tools.length).padStart(2)} tools ${String(r.secs).padStart(3)}s  ${r.why}`);
    writeFileSync(out, JSON.stringify(results, null, 2));
  }
}
await Promise.all([worker(), worker(), worker(), worker()]);
const tally = {};
for (const r of results) (tally[r.cond] ??= { PASS: 0, PARTIAL: 0, FAIL: 0, n: 0 })[r.verdict] = (tally[r.cond][r.verdict] ?? 0) + 1, tally[r.cond].n++;
for (const [c, t] of Object.entries(tally)) console.log(`${c.padEnd(7)} ${t.PASS}/${t.n} pass, ${t.PARTIAL} partial, ${t.FAIL} fail`);
console.log(`answers: ${out} — read the non-passes; the grader is sometimes stricter than the record.`);
