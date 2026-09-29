#!/usr/bin/env node
// A piece of work as one clean Markdown file for a person: a PR description,
// a teammate taking it over, a ticket. Where it stands, what was decided,
// and every brief — what was said, what its agent wrote back, the
// screenshots that were kept — oldest first. Redacted like everything else,
// with the task's own corrections ("Forget", "Edit") applied.
//
//   node packages/core/src/handoff.mjs <board root> <task id> <out dir> [--no-images]
//
// Writes <out dir>/handoff.md, and with images the kept screenshots beside it
// in <out dir>/screenshots/, linked relatively so the folder travels whole.
// `--no-images` is the "Copy hand-off" text: no files, no image links.
import { copyFileSync, lstatSync, mkdirSync, readFileSync, realpathSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { briefDate } from "./lib/context.mjs";
import { redact, redactNote } from "./lib/redact.mjs";
import { writeAtomic } from "./lib/session-io.mjs";
import { TASK_ID, currentDecisions, firm, groupTasks, readBoard, readTasks, taskState, titleFor } from "./lib/tasks.mjs";

/** A real file, no symlink and no hard link, resolving inside the board —
 *  the check memory-mcp.mjs makes: an agent can write inside the board, and
 *  a planted link would copy something else into a folder that gets shared. */
function plainFileInside(path, root) {
  try {
    const st = lstatSync(path);
    if (!st.isFile() || st.nlink > 1) return false;
    const real = realpathSync(path);
    const top = realpathSync(root);
    return real.startsWith(top + "/");
  } catch {
    return false;
  }
}

/** Screenshots the developer kept: released by the render, not removed
 *  since, inside the brief's own crops folder. With what was said over each. */
function keptShots(dir) {
  let manifest = null;
  let removed = [];
  try { manifest = JSON.parse(readFileSync(join(dir, "brief.json"), "utf8")); } catch { return []; }
  try { removed = JSON.parse(readFileSync(join(dir, "crops.excluded.json"), "utf8")); } catch { /* none removed */ }
  const skip = new Set(Array.isArray(removed) ? removed : []);
  return (manifest?.referents ?? [])
    .filter((r) => typeof r?.cropPath === "string" && dirname(r.cropPath) === join(dir, "crops") && !skip.has(basename(r.cropPath)))
    .map((r) => ({ path: r.cropPath, said: typeof r.said === "string" ? r.said : null }));
}

export function handoff({ root, task, outDir = null, images = true }) {
  const briefs = groupTasks(readBoard(root)).get(task);
  if (!briefs) throw new Error(`no task ${task} on this board`);
  const title = readTasks(root).get(task) ?? titleFor(briefs.at(-1));
  let project = null;
  try {
    project = JSON.parse(readFileSync(join(root, "collections.json"), "utf8")).find((c) => c?.id === briefs[0].collection)?.name ?? null;
  } catch { /* Unsorted */ }
  // Where it stands and what was decided: from confirmed briefs only, as the
  // task's note says it (see `renderTaskNote`).
  const sure = briefs.filter((b) => firm(b, task));
  const said = sure.length ? sure : [briefs.at(-1)];
  const state = taskState(said, title);
  const { decisions } = currentDecisions(said);

  const first = briefDate(briefs.at(-1).id);
  const last = briefDate(briefs[0].id);
  const out = [
    `# ${redact(title)}`,
    "",
    `${redact(project ?? "Unsorted")} · ${briefs.length} brief${briefs.length === 1 ? "" : "s"} · ${first}${last !== first ? `–${last}` : ""}`,
  ];
  if (state.now.length) out.push("", "## Where it stands", "", ...state.now.map((l) => `- ${l}`));
  if (decisions.length) out.push("", "## Decided", "", ...decisions.map((d) => `- ${d.text} (${briefDate(d.id)})`));
  out.push("", "## How it went");
  for (const b of [...briefs].reverse()) {
    // Headed by its summary when it has one; a brief without one is headed
    // by its day alone, so its words aren't said twice.
    const summary = b.summaryLine && b.line === b.summaryLine ? `: ${redact(b.summaryLine)}` : "";
    out.push("", `### ${briefDate(b.id)}${summary}`);
    const words = redact(b.narration ?? "").replace(/\s+/g, " ").trim();
    if (words) out.push("", `> ${words}`);
    const o = b.outcome;
    if (o) {
      for (const [head, lines] of [["Did", o.did], ["Decided", o.decided], ["Still open", o.open], ["Files", o.files]]) {
        if (lines?.length) out.push("", `**${head}**`, "", ...redactNote(lines).map((l) => `- ${l}`));
      }
    }
    if (images && outDir) {
      const shots = keptShots(b.dir).filter((s) => plainFileInside(s.path, root));
      if (shots.length) out.push("");
      shots.forEach((s, i) => {
        const name = `${b.id}-${i + 1}.png`;
        mkdirSync(join(outDir, "screenshots"), { recursive: true });
        copyFileSync(s.path, join(outDir, "screenshots", name));
        const caption = s.said ? redact(s.said).replace(/\s+/g, " ").trim().slice(0, 160) : `Screenshot ${i + 1}`;
        out.push(`![${caption.replace(/[[\]]/g, "")}](screenshots/${name})`);
      });
    }
  }
  out.push("", "---", "Put together by Deiko from the briefs and what the agents wrote back.");
  return out.join("\n") + "\n";
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [root, task, outDir] = process.argv.slice(2);
  if (!root || !TASK_ID.test(task ?? "") || !outDir) {
    console.error("usage: handoff.mjs <board root> <task id> <out dir> [--no-images]");
    process.exit(2);
  }
  mkdirSync(resolve(outDir), { recursive: true });
  const text = handoff({ root: resolve(root), task, outDir: resolve(outDir), images: !process.argv.includes("--no-images") });
  writeAtomic(join(resolve(outDir), "handoff.md"), text);
}
