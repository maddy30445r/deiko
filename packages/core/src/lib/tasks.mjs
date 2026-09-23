/**
 * TASKS — the unit Deiko remembers. Project (collection) → task → briefs.
 *
 * A brief's task is `context.json.task`; one with none is its own task,
 * `t-<its stamp>`, so a board from before tasks reads correctly untouched.
 * `tasks.json` beside the sessions holds only titles, because a title can be
 * renamed. The note in `tasks/<id>.md` is compiled from the briefs and their
 * outcomes, never edited in place — see `render-brief.mjs`, its only writer.
 *
 * Pure, except `readTasks` and `writeTaskNotes`.
 */

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { redact } from "./redact.mjs";
import { STAMP, briefDate, readBriefLine } from "./context.mjs";

export const TASK_ID = /^t-\d{8}-\d{6}$/;
/// How many tasks Jev chooses among.
export const SHORTLIST = 8;
const CAP = { now: 12, decided: 20, briefs: 50 };

export const taskIdFor = (stamp) => `t-${stamp}`;

export function stampTime(stamp) {
  const [d, t] = String(stamp).split("-");
  return new Date(+d.slice(0, 4), +d.slice(4, 6) - 1, +d.slice(6, 8),
    +t.slice(0, 2), +t.slice(2, 4), +t.slice(4, 6)).getTime();
}

export const tokens = (text) => String(text ?? "").toLowerCase().match(/[a-z0-9$]{2,}/g) ?? [];

const HEADS = { did: /^did\b/i, decided: /^decided\b/i, open: /^open\b/i, files: /^files\b/i };

/** An agent's `outcome.md`, by its four headings. Unknown headings are
 *  skipped; text before any heading is what it did. */
export function parseOutcome(text) {
  const out = { did: [], decided: [], open: [], files: [] };
  let into = "did";
  for (const raw of String(text ?? "").split("\n")) {
    const heading = raw.match(/^#{1,6}\s*(.+)$/);
    if (heading) {
      into = Object.keys(HEADS).find((k) => HEADS[k].test(heading[1].trim())) ?? into;
      continue;
    }
    const line = raw.replace(/^\s*[-*]\s*/, "").trim();
    if (line) out[into].push(line);
  }
  return out;
}

/// What `summarize.mjs` tells Groq to say when it cannot tell.
const COULD_NOT_TELL = /too (short|garbled)/i;

export function titleFor({ summaryLine, narration, apps } = {}) {
  if (summaryLine && !COULD_NOT_TELL.test(summaryLine)) return summaryLine.trim();
  const said = String(narration ?? "").replace(/\s+/g, " ").trim();
  if (said.length > 12) return said.slice(0, 60);
  if (apps?.[0]) return `Something in ${apps[0]}`;
  return "A brief";
}

export function groupTasks(briefs) {
  const groups = new Map();
  for (const b of [...briefs].sort((x, y) => (x.id < y.id ? 1 : -1))) {
    const id = b.task ?? taskIdFor(b.id);
    if (!groups.has(id)) groups.set(id, []);
    groups.get(id).push(b);
  }
  return groups;
}

/** Newest-first briefs → where the task stands and what was done last. */
export function taskState(briefs) {
  const last = briefs.find((b) => b.outcome);
  const now = last?.outcome.open.length
    ? last.outcome.open
    : briefs[0] ? [`Asked: ${briefs[0].line}`] : [];
  return {
    now: now.slice(0, CAP.now).map(redact),
    lastDid: (last?.outcome.did ?? []).slice(0, CAP.now).map(redact),
  };
}

/** Everything the local score may read, screen terms included. Never sent. */
export function taskText(title, briefs) {
  return [
    title,
    ...briefs.flatMap((b) => [
      b.line, ...b.windows, ...b.apps, ...b.screenTerms,
      ...(b.outcome ? [...b.outcome.did, ...b.outcome.decided, ...b.outcome.open, ...b.outcome.files] : []),
    ]),
  ].join(" ");
}

/**
 * The shortlist: BM25 over each task's text, plus a nudge for the same repo
 * and for recent work. A nudge, not a gate — a topic switch ten minutes after
 * the last brief must still be able to lose.
 *
 * ponytail: lexical, so blind to paraphrase ("the drag thing" vs "moving
 * cards"). The weights are eyeballed. Upgrade: on-device sentence embeddings
 * (NaturalLanguage) as a second score, when a wrong shortlist shows up.
 */
export function scoreTasks({ query, tasks, repoHints = [], now = Date.now(), limit = SHORTLIST }) {
  if (!tasks.length) return [];
  const docs = tasks.map((t) => tokens(t.text));
  const avg = docs.reduce((s, d) => s + d.length, 0) / docs.length || 1;
  const df = new Map();
  for (const d of docs) for (const w of new Set(d)) df.set(w, (df.get(w) ?? 0) + 1);
  const q = [...new Set(tokens(query))];
  const hints = repoHints.filter(Boolean).map((h) => h.toLowerCase());
  const k1 = 1.2, b = 0.75, N = docs.length;
  return tasks.map((t, i) => {
    const tf = new Map();
    for (const w of docs[i]) tf.set(w, (tf.get(w) ?? 0) + 1);
    let score = 0;
    for (const w of q) {
      const f = tf.get(w);
      if (!f) continue;
      const idf = Math.log(1 + (N - df.get(w) + 0.5) / (df.get(w) + 0.5));
      score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + (b * docs[i].length) / avg));
    }
    const sameRepo = hints.some((h) => t.text.toLowerCase().includes(h));
    if (sameRepo) score += 2;
    const age = now - t.lastActive;
    if (age < 2 * 3600e3) score += 2;
    else if (age < 24 * 3600e3) score += 1;
    return { id: t.id, score, sameRepo };
  }).sort((x, y) => y.score - x.score).slice(0, limit);
}

/** The compiled note. `briefs` newest first. Every line from another
 *  session is redacted here, where it is written. */
export function renderTaskNote({ id, title, collection = null, briefs }) {
  const first = briefDate(briefs.at(-1).id);
  const last = briefDate(briefs[0].id);
  const n = briefs.length;
  const out = [
    `# ${redact(title)}`,
    `${collection ?? "Unsorted"} · ${n} brief${n === 1 ? "" : "s"} · ${first}${last !== first ? `–${last}` : ""} · updated from ${briefs[0].id}`,
    "", "## Now", ...taskState(briefs).now,
  ];
  const decided = briefs
    .flatMap((b) => (b.outcome?.decided ?? []).map((d) => `- ${briefDate(b.id)}: ${redact(d)}`))
    .slice(0, CAP.decided);
  if (decided.length) out.push("", "## Decided", ...decided);
  out.push("", "## Briefs");
  for (const b of briefs.slice(0, CAP.briefs)) {
    const apps = b.apps.length ? ` · ${b.apps.join(", ")}` : "";
    const windows = b.windows.length ? ` · ${b.windows.slice(0, 3).map(redact).join(" · ")}` : "";
    out.push(`- ${briefDate(b.id)}, "${redact(b.line)}"${apps}${windows}`);
    // TWO FILES BY NAME, NEVER THE FOLDER — see `prompt.mjs`.
    out.push(`  ${b.dir}/prompt.txt${b.outcome ? ` · ${b.dir}/outcome.md` : ""}`);
  }
  if (n > CAP.briefs) out.push(`- … and ${n - CAP.briefs} earlier`);
  return out.join("\n") + "\n";
}
