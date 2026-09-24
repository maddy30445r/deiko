/**
 * THE MEMORY — which collection a brief belongs to, which task it joins or
 * starts, and how much work it looks like.
 *
 * Everything here is arithmetic over what the classifier answered. The
 * classifier is Jev (TypeSafe AI's "System One" model), reached through the
 * relay by `scripts/classify.mjs`; it returns calibrated probabilities, and
 * these floors are the only place they become decisions. The thresholds are
 * tuned against `jev-1.13.0`, which the relay pins — see `JEV_MODEL` there.
 *
 * Pure, except `readBriefLine`, which is the one way a sibling session is
 * read so that `classify.mjs` (building the shortlist) and `render-brief.mjs`
 * (resolving the task that was chosen) cannot disagree about what a session
 * says.
 */

import { readFileSync } from "node:fs";
import { basename, join } from "node:path";

import { KINDS, normaliseLabel } from "./labels.mjs";
import { TASK_ID, parseOutcome } from "./tasks.mjs";

/// Where a probability becomes a decision.
///
/// The app has one more of these — the confidence below which a collection is
/// shown as a guess rather than a fact — and it lives in `Context.swift`,
/// because nothing here ever reads it.
export const FLOORS = {
  collection: 0.6,
  quickHint: 0.8,
};

/// At most this many are named; past three it is a list, not a question.
const MAX_CANDIDATES = 3;

/// The Score levels, in order. Index = level. MIRRORS the rubric in
/// `services/relay/relay.mjs` (`TIER_RUBRIC`): the relay names the levels to
/// the model, this names them to the app. Change both.
export const TIERS = ["quick", "medium", "complex", "reasoning"];

/// A stamp Deiko minted: `yyyyMMdd-HHmmss`. The same gate `Sessions.swift`
/// uses, because being shaped like a session is what makes a folder one.
export const STAMP = /^\d{8}-\d{6}$/;

/** A collection id from its name: `acme-portal` → `acme-portal`, `Deiko` →
 *  `deiko`, `My Site (v2)` → `my-site-v2`. Mirrors `Collections.slug` in
 *  `Context.swift`. */
export function slug(name) {
  const s = String(name ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return s || "collection";
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** `Sep 18` from `20260918-155717`; the year is added when it is not this one. */
export function briefDate(id, now = new Date()) {
  if (!STAMP.test(id ?? "")) return "";
  const year = Number(id.slice(0, 4));
  const month = Number(id.slice(4, 6));
  const day = Number(id.slice(6, 8));
  const text = `${MONTHS[month - 1] ?? "?"} ${day}`;
  return year === now.getFullYear() ? text : `${text}, ${year}`;
}

/// The shortest narration worth classifying. "Thank you." is a real
/// transcript, and a board is full of them; asking what project it belongs to
/// is a question with no answer. Shorter joins its task only on a clear local
/// match, else odds and ends — see `classify.mjs`.
export const MIN_NARRATION = 12;

/// What `summarize.mjs` tells Groq to say when it cannot tell ("too garbled
/// or too short to tell"), as Groq words it: "The transcript is too short to
/// determine a request." Narrow on purpose — it drops briefs from the board
/// and sends them to odds and ends, so a real summary saying a timeout is
/// "too short for large uploads" must not match.
export const COULD_NOT_TELL = /\btoo (short|garbled) to (tell|determine|understand)\b/i;

/** Why a brief has nothing to place — too little said, or a summary that
 *  could not tell what was asked — or null when it can be placed. One rule
 *  for the brief being classified and for the board it is scored against,
 *  so a mic test is neither filed nor a task to file into. */
export function unplaceable(b) {
  if ((b.narration ?? "").trim().length < MIN_NARRATION) return "narration too short to place";
  if (COULD_NOT_TELL.test(b.summaryLine ?? "")) return "the summary could not tell what was asked";
  return null;
}

/// Filing, v3. Stamped on every context.json this writes, so a re-sort after
/// the rules change shows exactly which briefs moved and why.
export const CLASSIFIER = "v3.0";
/// ponytail: starting values, tuned on the filing eval (scripts/eval-filing.mjs)
/// and later on real corrections. GATE and ASK are MIRRORED by `GATE` and
/// `SECOND_LOOK.min` in services/relay/relay.mjs — change both.
export const GATE = 0.5;
export const JOIN = { line: 0.9, gap: 0.2, recent: 0.75, recentMs: 30 * 60e3 };
export const ASK = 0.35;
/// The relation levels, in order. MIRRORS `RELATION_RUBRIC` in the relay.
export const RELATIONS = ["different", "related", "same"];

export function yes(answer) {
  const p = Number(answer?.noul);
  return Number.isFinite(p) ? Math.min(1, Math.max(0, p)) : 0;
}

/** A score answer's level. TWO SHAPES FOR `probabilities`: TypeSafe's docs
 *  show an array by level; Vercel's gateway returns an object keyed "0", "1",
 *  … (measured on a live call). Rounding the score is the fallback, which is
 *  not the same answer when the mass is split. */
export function level(answer) {
  if (!answer) return null;
  const p = answer.probabilities;
  const probs = Array.isArray(p) ? p
    : p && typeof p === "object" ? Object.keys(p).sort((a, b) => Number(a) - Number(b)).map((k) => Number(p[k])) : [];
  if (probs.length) return probs.indexOf(Math.max(...probs));
  return typeof answer.score === "number" ? Math.round(answer.score) : null;
}

const NOT_A_PROJECT_APP = /^(google chrome|chrome|safari|arc|firefox|microsoft edge|brave browser|chromium|opera|vivaldi|zen|code|visual studio code|cursor|windsurf|zed|xcode|terminal|iterm2?|warp|ghostty|finder|dock|deiko|deiko capture|screenshot|usernotificationcenter|system settings)$/i;

export function projectFromKeys({ keys = {}, apps = [] } = {}) {
  const first = (list) => (Array.isArray(list) ? list.find((s) => typeof s === "string" && s.trim()) : undefined);
  return first(keys.repo) ?? first(keys.sites) ?? first(keys.docs)
    ?? apps.find((a) => typeof a === "string" && a.trim() && !NOT_A_PROJECT_APP.test(a.trim())) ?? null;
}

const lowered = (list) => new Set((list ?? []).map((s) => String(s).toLowerCase()));
const meets = (a, b) => {
  const theirs = lowered(b);
  return [...lowered(a)].some((x) => theirs.has(x));
};
/// Both sides named one, and none is shared.
const differ = (a, b) => (a?.length ?? 0) > 0 && (b?.length ?? 0) > 0 && !meets(a, b);

/**
 * Jev's percentages → where the brief goes. The only place they become a
 * decision, and every rule is here:
 *
 *   gate < GATE                                   → odds and ends
 *   a second look ≥ JOIN.line and JOIN.gap ahead  → join
 *     (≥ JOIN.recent when the task's newest brief is under 30 min old AND a
 *      page or file label matches — never for old work)
 *     … but a different page                      → ask instead
 *   a different ticket                            → that task is never joined or offered
 *   anything ≥ ASK not joined, not "different",
 *     not "related"                               → ask "Which one?" (up to 3)
 *   the second look says related-but-separate     → new task, `related` link
 *   otherwise                                     → new task
 *
 * Round one alone never joins. Time words never reach here.
 */
export function decide({
  answers = {}, second = {}, collections = [], keys = {}, apps = [],
  shortlist = [], taskKeys = {}, newest = {}, now = 0,
  taskCollections = {}, sessionId = null, title = null,
} = {}) {
  const gate = answers.is_work_brief ? yes(answers.is_work_brief) : 1;
  const same = Object.fromEntries(shortlist.map((id) => [id, yes(answers[`same_${id}`])]));
  const looks = Object.fromEntries(Object.entries(second ?? {})
    .filter(([id]) => shortlist.includes(id))
    .map(([id, a]) => [id, { same: yes(a?.same_task), relation: RELATIONS[level(a?.relation)] ?? null }]));
  const chosen = answers.collection;
  const jev = {
    gate, same, second: looks,
    collection: chosen ? { choice: chosen.choice ?? null, confidence: chosen.confidence ?? null } : null,
    shortlist, rank: null, why: null,
  };
  const out = {
    pile: null, collection: null, newCollection: null, task: null, newTask: null,
    tier: null, confidence: { gate }, why: null, jev,
  };

  const tierLevel = level(answers.tier);
  if (tierLevel != null && TIERS[tierLevel]) {
    out.tier = TIERS[tierLevel];
    out.confidence.tier = answers.tier.confidence ?? null;
  }

  if (gate < GATE) {
    out.pile = "odds";
    out.why = jev.why = "odds";
    return out;
  }

  const open = shortlist.filter((id) => !differ(keys.tickets, taskKeys[id]?.tickets));
  const p = (id) => looks[id]?.same ?? same[id] ?? 0;
  const ranked = open.filter((id) => looks[id]).sort((a, b) => looks[b].same - looks[a].same);
  const best = ranked[0];
  let why = "new";
  let task = null;
  let related = null;
  let candidates = [];
  if (best) {
    const s = looks[best].same;
    const theirs = taskKeys[best] ?? {};
    const next = Math.max(0, ...open.filter((id) => id !== best).map(p));
    const recent = now - (newest[best] ?? -Infinity) < JOIN.recentMs
      && (meets(keys.pages, theirs.pages) || meets(keys.files, theirs.files));
    if (s >= (recent ? JOIN.recent : JOIN.line) && s - next >= JOIN.gap) {
      // A bug found on one page is often fixed on another: ask, don't block.
      if (differ(keys.pages, theirs.pages)) {
        why = "ask-page";
        candidates = [best];
      } else {
        why = s < JOIN.line ? "join-recent" : "join";
        task = best;
      }
    }
  }
  if (!task && why !== "ask-page") {
    related = ranked.find((id) => looks[id].relation === "related") ?? null;
    candidates = open
      .filter((id) => p(id) >= ASK && !["different", "related"].includes(looks[id]?.relation))
      .sort((a, b) => p(b) - p(a))
      .slice(0, MAX_CANDIDATES);
    why = candidates.length ? "ask" : related ? "related" : "new";
  }

  if (task) {
    out.task = task;
    out.confidence.task = looks[task].same;
    jev.rank = shortlist.indexOf(task) + 1;
  } else if (sessionId) {
    out.task = `t-${sessionId}`;
    out.newTask = { id: out.task, title: title ?? "A brief" };
  }
  if (candidates.length) out.candidates = candidates;
  if (related) out.related = related;
  out.why = jev.why = why;

  // THE PROJECT: Jev when sure; a joined task's own; else the strongest label.
  const known = new Set(collections.map((c) => c.id));
  if (chosen && known.has(chosen.choice) && (chosen.confidence ?? 0) >= FLOORS.collection) {
    out.collection = chosen.choice;
    out.confidence.collection = chosen.confidence;
  } else if (task && known.has(taskCollections[task])) {
    out.collection = taskCollections[task];
    out.confidence.collection = out.confidence.task;
  } else {
    const name = projectFromKeys({ keys, apps });
    if (name) {
      const existing = collections.find((c) => c.name.toLowerCase() === name.trim().toLowerCase() || c.id === slug(name));
      if (existing) {
        out.collection = existing.id;
      } else {
        out.newCollection = { id: slug(name), name: name.trim() };
        out.collection = out.newCollection.id;
      }
      // A label on the window is not a guess.
      out.confidence.collection = 1;
    }
  }
  return out;
}

/** Whether a rendered context should carry the cost hint. */
export function wantsQuickHint(context, optimizeCosts) {
  return Boolean(optimizeCosts)
    && context?.tier === "quick"
    && (context?.confidence?.tier ?? 0) >= FLOORS.quickHint;
}

/// Lines kept per outcome section. The file itself is parsed whole, so a
/// long Did cannot push Open out of reach.
const OUTCOME_LINES = 40;

/**
 * What a sibling session says, read the one way every script reads it.
 * Missing pieces are null or empty, never a throw.
 */
export function readBriefLine(sessionDir) {
  const json = (name) => {
    try { return JSON.parse(readFileSync(join(sessionDir, name), "utf8")); } catch { return null; }
  };
  const text = (name) => {
    try { return readFileSync(join(sessionDir, name), "utf8"); } catch { return null; }
  };
  const summary = json("brief.json")?.summary ?? {};
  const context = json("context.json") ?? {};
  const narration = typeof summary.narration === "string" ? summary.narration : null;
  const summaryLine = (text("review-summary.txt") ?? "").split("\n").map((l) => l.trim()).find(Boolean) ?? null;
  const said = (narration ?? "").replace(/\s+/g, " ").trim().slice(0, 200);
  const outcomeText = text("outcome.md");
  const outcome = outcomeText?.trim() ? parseOutcome(outcomeText) : null;
  if (outcome) for (const k in outcome) outcome[k] = outcome[k].slice(0, OUTCOME_LINES);
  return {
    id: basename(sessionDir),
    dir: sessionDir,
    narration,
    summaryLine,
    line: summaryLine && !COULD_NOT_TELL.test(summaryLine) ? summaryLine : said,
    collection: context.collection ?? null,
    task: TASK_ID.test(context.task ?? "") ? context.task : null,
    // In odds and ends: too little said, or nothing Groq could make sense
    // of, and no task — see `classify.mjs`.
    odds: context.pile === "odds",
    apps: Array.isArray(summary.apps) ? summary.apps : [],
    windows: Array.isArray(summary.windows) ? summary.windows : [],
    screenTerms: Array.isArray(summary.screenTerms) ? summary.screenTerms : [],
    repoHints: Array.isArray(summary.repoHints) ? summary.repoHints : [],
    // Labels (`labels.mjs`). A brief rendered before labels existed has only
    // its repo hints, which were the first label — through the same
    // `normaliseLabel` a current brief's repo names already went through, so
    // an old hint is redacted too, not just a fresh one.
    keys: Object.fromEntries(KINDS.map((k) => [k,
      Array.isArray(summary.keys?.[k]) ? summary.keys[k]
        : k === "repo" && Array.isArray(summary.repoHints)
          ? summary.repoHints.map((h) => normaliseLabel(h, "repo")).filter(Boolean)
          : []])),
    outcome,
  };
}
