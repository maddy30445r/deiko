import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { decide, latestBrief } from "../src/claude-stop-hook.mjs";

const script = fileURLToPath(new URL("../src/claude-stop-hook.mjs", import.meta.url));

const brief = (id, outcome) =>
  `Fix the price.\n\nWhen you are done — and again if we keep going — save what you did, decided and left open: with the deiko-memory save_outcome tool if it is connected (brief ${id}), or else by rewriting ${outcome} under four headings — ## Did, ## Decided, ## Open, ## Files — a few lines each.`;

function transcript(dir, entries) {
  const path = join(dir, "t.jsonl");
  writeFileSync(path, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  return path;
}

test("the brief this turn answers is found, in string or block content", () => {
  const t = [
    { type: "user", timestamp: "2026-09-29T10:00:00Z", message: { role: "user", content: brief("20260929-100000", "/b/20260929-100000/outcome.md") } },
    { type: "assistant", message: { content: [{ type: "text", text: "done" }] } },
    { type: "user", timestamp: "2026-09-29T11:00:00Z", message: { role: "user", content: [{ type: "text", text: brief("20260929-110000", "/b/20260929-110000/outcome.md") }] } },
  ].map((e) => JSON.stringify(e)).join("\n");
  assert.deepEqual(latestBrief(t), { id: "20260929-110000", outcome: "/b/20260929-110000/outcome.md", at: Date.parse("2026-09-29T11:00:00Z") });
  assert.equal(latestBrief('{"type":"user","message":{"content":"hello"}}'), null);
});

test("a brief with no outcome since it arrived blocks the stop once", () => {
  const dir = mkdtempSync(join(tmpdir(), "deiko-hook-"));
  const outcome = join(dir, "20260929-100000", "outcome.md");
  const path = transcript(dir, [{ type: "user", timestamp: new Date().toISOString(), message: { content: brief("20260929-100000", outcome) } }]);
  const answer = decide({ transcript_path: path, stop_hook_active: false });
  assert.equal(answer.decision, "block");
  assert.match(answer.reason, /save_outcome/);
  assert.match(answer.reason, /20260929-100000/);
  assert.equal(decide({ transcript_path: path, stop_hook_active: true }), null, "never twice in a row");
});

test("an outcome written after the brief lets the agent stop; an older one does not", () => {
  const dir = mkdtempSync(join(tmpdir(), "deiko-hook-"));
  const outcome = join(dir, "outcome.md");
  writeFileSync(outcome, "## Did\n- fixed it\n");
  const sent = Date.now() - 60_000;
  const path = transcript(dir, [{ type: "user", timestamp: new Date(sent).toISOString(), message: { content: brief("20260929-100000", outcome) } }]);
  assert.equal(decide({ transcript_path: path }), null);
  utimesSync(outcome, new Date(sent - 120_000), new Date(sent - 120_000));
  assert.equal(decide({ transcript_path: path }).decision, "block");
});

test("a chat that never carried a Deiko brief is left alone", () => {
  const dir = mkdtempSync(join(tmpdir(), "deiko-hook-"));
  const path = transcript(dir, [{ type: "user", timestamp: new Date().toISOString(), message: { content: "rename this variable" } }]);
  assert.equal(decide({ transcript_path: path }), null);
  assert.equal(decide({ transcript_path: join(dir, "missing.jsonl") }) ?? null, null);
});

test("run as a hook, it prints the block JSON and always exits 0", () => {
  const dir = mkdtempSync(join(tmpdir(), "deiko-hook-"));
  const path = transcript(dir, [{ type: "user", timestamp: new Date().toISOString(), message: { content: brief("20260929-100000", join(dir, "outcome.md")) } }]);
  const run = spawnSync(process.execPath, [script], { input: JSON.stringify({ transcript_path: path, stop_hook_active: false }), encoding: "utf8" });
  assert.equal(run.status, 0);
  assert.equal(JSON.parse(run.stdout).decision, "block");
  const bad = spawnSync(process.execPath, [script], { input: "not json", encoding: "utf8" });
  assert.equal(bad.status, 0);
  assert.equal(bad.stdout, "");
});

test("a brief pasted earlier and then talked about does not nag later turns", () => {
  const brief1 = { type: "user", timestamp: "2026-09-29T10:00:00Z", message: { content: brief("20260929-100000", "/b/20260929-100000/outcome.md") } };
  const later = { type: "user", timestamp: "2026-09-29T12:00:00Z", message: { content: [{ type: "text", text: "why did that not join the pricing task?" }] } };
  const toolResult = { type: "user", message: { content: [{ type: "tool_result", content: "ok" }] } };
  const meta = { type: "user", isMeta: true, message: { content: "<system-reminder>…</system-reminder>" } };
  const feedback = { type: "user", message: { content: "Stop hook feedback: Before you finish…" } };
  const t = (...entries) => entries.map((e) => JSON.stringify(e)).join("\n");
  assert.equal(latestBrief(t(brief1, later)), null, "a later prompt means this turn is not the brief");
  assert.equal(latestBrief(t(brief1, toolResult, meta, feedback)).id, "20260929-100000", "tool results, meta and hook feedback are not prompts");
});
