// The synthetic test board (board-spec.mjs) written out as the files
// readBriefLine reads, with task notes and meaning vectors. Shared by run.mjs
// (does an agent remember?) and references.mjs (does a pointing-back brief file?).
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { DEIKO_HOME } from "../lib/meaning.mjs";
import { writeTaskNotes } from "../lib/tasks.mjs";
import { overrides, projects, tasks } from "./board-spec.mjs";

const SCRIPTS = fileURLToPath(new URL("..", import.meta.url));

/** Builds the board in `board` (created); returns task ids by spec key. */
export function buildBoard(board) {
  mkdirSync(join(board, "tasks"), { recursive: true });
  const models = join(DEIKO_HOME.replace(/^~/, homedir()), "models");
  if (existsSync(models)) symlinkSync(models, join(board, "models")); // meaning search, if downloaded
  writeFileSync(join(board, "collections.json"), JSON.stringify(projects));
  const ids = {};
  for (const t of tasks) {
    const id = ids[t.key] = `t-${t.briefs[0].at}`;
    for (const [n, b] of t.briefs.entries()) {
      const dir = join(board, b.at);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "brief.json"), JSON.stringify({ summary: { narration: b.said, apps: b.apps, windows: b.windows, repoHints: [b.repo], screenTerms: [], keys: { repo: [b.repo] } }, referents: [] }));
      // The founder, then v3 joins with a confidence: every brief is firm.
      writeFileSync(join(dir, "context.json"), JSON.stringify({ collection: t.project, task: id, decidedBy: n ? "jev" : "new", classifier: "v3.0", confidence: { task: n ? 0.9 : null } }));
      writeFileSync(join(dir, "review-summary.txt"), b.summary + "\n");
      if (b.outcome) writeFileSync(join(dir, "outcome.md"), b.outcome + "\n");
    }
  }
  writeFileSync(join(board, "tasks.json"), JSON.stringify(tasks.map((t) => ({ id: ids[t.key], title: t.title, from: "summary" }))));
  for (const [key, o] of Object.entries(overrides)) writeFileSync(join(board, "tasks", `${ids[key]}.overrides.json`), JSON.stringify(o));
  writeTaskNotes(board);
  if (existsSync(models)) execFileSync(process.execPath, [join(SCRIPTS, "meaning.mjs"), "backfill", board], { stdio: "ignore" });
  return ids;
}
