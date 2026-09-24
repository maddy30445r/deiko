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
import { COULD_NOT_TELL, STAMP, briefDate, readBriefLine } from "./context.mjs";

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

/// The four headings, as agents actually title them.
const HEADS = {
  decided: /^decisions?\b|^decided\b/i,
  open: /^(open|next( steps)?|todo|to do|remaining)\b/i,
  did: /^(did|done|changes?|what i did)\b/i,
  files: /^files?( touched| changed)?\b/i,
};
const section = (heading) => {
  const name = heading.replace(/[*_`]/g, "").trim();
  return Object.keys(HEADS).find((k) => HEADS[k].test(name)) ?? null;
};

/**
 * An agent's `outcome.md`, by its four headings; text before any heading is
 * what it did. A markdown heading that is none of the four starts a section
 * that is dropped — a "## Summary" is not what is still open — except a
 * top-level one ("# Outcome"), which is the file's own title and changes
 * nothing. A "#" needs a space after it: "#2 still flaky" is text. A label alone
 * on its line ("**Did:**", "Files changed:") is a heading only when it names
 * one of the four; otherwise it is text. Code fences are skipped whole,
 * headings inside them included.
 */
export function parseOutcome(text) {
  const out = { did: [], decided: [], open: [], files: [] };
  let into = "did";
  let fence = null;
  for (const raw of String(text ?? "").split("\n")) {
    const marker = raw.match(/^\s*(`{3,}|~{3,})/)?.[1];
    if (fence) {
      if (marker?.[0] === fence[0] && marker.length >= fence.length) fence = null;
      continue;
    }
    if (marker) {
      fence = marker;
      continue;
    }
    const heading = raw.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      const named = section(heading[2]);
      if (named || heading[1].length > 1) into = named;
      continue;
    }
    const label = raw.trim().replace(/[*_]/g, "");
    if (/^[a-z][a-z ]*:?$/i.test(label) && (label.endsWith(":") || /^\s*(\*\*|__)/.test(raw)) && section(label)) {
      into = section(label);
      continue;
    }
    const line = raw.replace(/^\s*[-*]\s*/, "").trim();
    if (line && into) out[into].push(line);
  }
  return out;
}

const TITLE_CAP = 80;

/// A title Groq or the user wrote, not one Deiko composed: strips the
/// trailing full stop a sentence naturally ends on (so quoting it in a
/// prompt never doubles up, e.g. `…stays old."."`) and caps it at a word
/// boundary rather than mid-word.
function trimTitle(text) {
  const stripped = text.trim().replace(/[.!?\s]+$/, "");
  if (stripped.length <= TITLE_CAP) return stripped;
  const cut = stripped.slice(0, TITLE_CAP);
  const boundary = cut.lastIndexOf(" ");
  return `${boundary > 0 ? cut.slice(0, boundary) : cut}…`;
}

export function titleFor({ summaryLine, narration, apps } = {}) {
  if (summaryLine && !COULD_NOT_TELL.test(summaryLine)) return trimTitle(summaryLine);
  const said = String(narration ?? "").replace(/\s+/g, " ").trim();
  if (said.length > 12) return trimTitle(said);
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

/**
 * Newest-first briefs → where the task stands and what was done last.
 *
 * Only the NEWEST brief's outcome says where things stand: an older one
 * describes work a later ask has moved past, so it follows that ask, dated.
 * An outcome with nothing open is finished work and says what was done. A
 * "Last asked" line that only repeats `title` is dropped — the prompt and
 * the note both name the title already.
 */
export function taskState(briefs, title = null) {
  const [newest] = briefs;
  const last = briefs.find((b) => b.outcome);
  const same = (a, b) => trimTitle(a).toLowerCase() === trimTitle(b).toLowerCase();
  const asked = newest && !(title && same(newest.line, title)) ? [`Last asked: ${newest.line}`] : [];
  let now;
  if (newest?.outcome) {
    const { open, did } = newest.outcome;
    now = open.length ? open : did.length ? [`Last done: ${did[0]}`] : asked;
  } else {
    const open = last?.outcome.open ?? [];
    now = [...asked, ...open.map((o, i) => (i ? o : `Still open from ${briefDate(last.id)}: ${o}`))];
  }
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

/// Shortlist places kept for the most recently active tasks.
const RECENT = 2;

/**
 * The shortlist: BM25 over each task's text, plus a nudge for the same repo
 * and for recent work. A nudge, not a gate — a topic switch ten minutes after
 * the last brief must still be able to lose. Same repo is one of this brief's
 * repo hints equal to one of the task's own (`t.repoHints`), not a word
 * found anywhere in its text.
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
  const ranked = tasks.map((t, i) => {
    const tf = new Map();
    for (const w of docs[i]) tf.set(w, (tf.get(w) ?? 0) + 1);
    let score = 0;
    for (const w of q) {
      const f = tf.get(w);
      if (!f) continue;
      const idf = Math.log(1 + (N - df.get(w) + 0.5) / (df.get(w) + 0.5));
      score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + (b * docs[i].length) / avg));
    }
    const sameRepo = (t.repoHints ?? []).some((h) => hints.includes(String(h).toLowerCase()));
    if (sameRepo) score += 2;
    const age = now - t.lastActive;
    if (age < 2 * 3600e3) score += 2;
    else if (age < 24 * 3600e3) score += 1;
    return { id: t.id, score, sameRepo };
  }).sort((x, y) => y.score - x.score);
  // "Same bug as yesterday" shares few words with yesterday's task once the
  // board is full of the same page's words, and the recency nudge is noise
  // beside a BM25 score. So the two most recently active tasks always get a
  // place, taken from the lowest scores when they did not earn one.
  // ponytail: a fixed two, whatever they score; a third recent task still has
  // to win on words. Upgrade: weigh recency into the score itself once real
  // filing misses say how much.
  const top = ranked.slice(0, limit);
  const recent = new Set([...tasks].sort((x, y) => y.lastActive - x.lastActive).slice(0, RECENT).map((t) => t.id));
  const missing = ranked.filter((r) => recent.has(r.id) && !top.includes(r));
  return [...top.slice(0, limit - missing.length), ...missing];
}

/** The compiled note. `briefs` newest first. Every line from another
 *  session is redacted here, where it is written. */
export function renderTaskNote({ id, title, collection = null, briefs }) {
  const first = briefDate(briefs.at(-1).id);
  const last = briefDate(briefs[0].id);
  const n = briefs.length;
  const out = [
    `# ${redact(title)}`,
    `${redact(collection ?? "Unsorted")} · ${n} brief${n === 1 ? "" : "s"} · ${first}${last !== first ? `–${last}` : ""} · updated from ${briefs[0].id}`,
    // Rewritten whole on every render, so an edit here would not last.
    "Compiled by Deiko from each brief's outcome.md — edit those, not this file.",
  ];
  const now = taskState(briefs, title).now;
  if (now.length) out.push("", "## Now", ...now);
  const decided = briefs
    .flatMap((b) => (b.outcome?.decided ?? []).map((d) => `- ${briefDate(b.id)}: ${redact(d)}`))
    .slice(0, CAP.decided);
  if (decided.length) out.push("", "## Decided", ...decided);
  out.push("", "## Briefs");
  for (const b of briefs.slice(0, CAP.briefs)) {
    const apps = b.apps.length ? ` · ${b.apps.map(redact).join(", ")}` : "";
    const windows = b.windows.length ? ` · ${b.windows.slice(0, 3).map(redact).join(" · ")}` : "";
    out.push(`- ${briefDate(b.id)}, "${redact(b.line)}"${apps}${windows}`);
    // TWO FILES BY NAME, NEVER THE FOLDER — see `prompt.mjs`.
    out.push(`  ${b.dir}/prompt.txt${b.outcome ? ` · ${b.dir}/outcome.md` : ""}`);
  }
  if (n > CAP.briefs) out.push(`- … and ${n - CAP.briefs} earlier`);
  return out.join("\n") + "\n";
}

/** `tasks.json`: titles by id. Missing or unreadable is "no titles yet". */
export function readTasks(root) {
  try {
    const list = JSON.parse(readFileSync(join(root, "tasks.json"), "utf8"));
    return new Map((Array.isArray(list) ? list : [])
      .filter((t) => t && TASK_ID.test(t.id) && typeof t.title === "string")
      .map((t) => [t.id, t.title]));
  } catch {
    return new Map();
  }
}

/** Every sibling under `root` as a `readBriefLine`, briefs with nothing said
 *  skipped, and odds and ends too: never shortlisted, never in a note. */
export function readBoard(root) {
  return readdirSync(root)
    .filter((name) => STAMP.test(name))
    .map((name) => readBriefLine(join(root, name)))
    .filter((b) => b.line && !b.odds);
}

/**
 * THE ONLY WRITER OF TASK NOTES. Compiles every task with two or more briefs
 * and writes the ones whose text changed, so a note that lost a brief to a
 * board move but still has two or more left heals on the next render of
 * anything. A single brief has nothing to carry, and hundreds of one-line
 * notes would be clutter — but that also means a task a board move drops
 * back below two briefs keeps its last note exactly as it was, stale,
 * rather than losing or updating it.
 */
export function writeTaskNotes(root) {
  const titles = readTasks(root);
  let names = new Map();
  try {
    names = new Map(JSON.parse(readFileSync(join(root, "collections.json"), "utf8")).map((c) => [c.id, c.name]));
  } catch {
    // No collections: the note says Unsorted.
  }
  const dir = join(root, "tasks");
  let written = 0;
  for (const [id, briefs] of groupTasks(readBoard(root))) {
    if (briefs.length < 2) continue;
    const text = renderTaskNote({
      id,
      title: titles.get(id) ?? titleFor(briefs.at(-1)),
      collection: names.get(briefs[0].collection) ?? null,
      briefs,
    });
    const path = join(dir, `${id}.md`);
    if (existsSync(path) && readFileSync(path, "utf8") === text) continue;
    mkdirSync(dir, { recursive: true });
    writeFileSync(path, text);
    written += 1;
  }
  return written;
}
