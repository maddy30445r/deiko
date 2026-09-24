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

import { TASK_ID, parseOutcome } from "./tasks.mjs";

/// Where a probability becomes a decision.
///
/// The app has one more of these — the confidence below which a collection is
/// shown as a guess rather than a fact — and it lives in `Context.swift`,
/// because nothing here ever reads it.
export const FLOORS = {
  collection: 0.6,
  task: 0.7,
  // Worth naming to the agent as "it might be this one" when no task was
  // joined. Low on purpose: this is a question, not a decision.
  candidate: 0.15,
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
/// is a question with no answer.
export const MIN_NARRATION = 12;

/**
 * The classifier's answers, turned into a `context.json`.
 *
 * Returns `{ collection, task, newTask, tier, confidence, newCollection }`,
 * plus `candidates` when there are any. `newCollection` is `{ id, name }`
 * when the brief matched no collection but carries a repo hint that is not
 * one yet — the caller creates it. `newTask` is `{ id, title }` when no
 * shortlisted task was confidently chosen — the caller creates it. Never
 * throws on a partial answer: a missing question reads as "no".
 *
 * `shortlist` is the task ids Deiko sent, best local score first; `scores` is
 * those local scores, index for index (`scoreTasks`' `score`). `candidates`
 * is up to three of those ids, likeliest first, when the brief joined none
 * and Jev did not confidently call it new — the tasks it MIGHT carry on, for
 * somebody to be asked about. Absent, not empty, when there are none.
 */
export function decide({ answers = {}, collections = [], repoHints = [], shortlist = [], scores = [], sessionId = null, title = null } = {}) {
  const out = {
    collection: null,
    task: null,
    newTask: null,
    tier: null,
    confidence: {},
    newCollection: null,
  };

  const known = new Set(collections.map((c) => c.id));
  const chosen = answers.collection;
  if (chosen && known.has(chosen.choice) && (chosen.confidence ?? 0) >= FLOORS.collection) {
    out.collection = chosen.choice;
    out.confidence.collection = chosen.confidence;
  } else {
    const hint = repoHints.find((h) => typeof h === "string" && h.trim());
    if (hint) {
      const existing = collections.find((c) => c.name.toLowerCase() === hint.trim().toLowerCase());
      if (existing) {
        out.collection = existing.id;
      } else {
        out.newCollection = { id: slug(hint), name: hint.trim() };
        out.collection = out.newCollection.id;
      }
      // A repo name on the window is not a guess, and it does not need one.
      out.confidence.collection = 1;
    }
  }

  // ONE TASK OR A NEW ONE. Only ids Deiko put on the shortlist can be
  // chosen, so a model that invents an id starts a task rather than joining
  // one that does not exist.
  const pick = answers.task;
  const sure = (pick?.confidence ?? 0) >= FLOORS.task;
  if (sure && shortlist.includes(pick.choice)) {
    out.task = pick.choice;
    out.confidence.task = pick.confidence;
  } else if (sessionId) {
    out.task = `t-${sessionId}`;
    out.newTask = { id: out.task, title: title ?? "A brief" };
  }

  // WHICH ONES IT MIGHT BE, unless it joined one or is confidently new work.
  // Jev's own spread when it sent one — a map keyed by option id; the local
  // score when it did not, behind Jev's pick, and only what scored at least
  // half the best (a best of 0 matched nothing, so it names nothing).
  if (!sure || (pick.choice !== "new" && !shortlist.includes(pick.choice))) {
    const probs = pick?.probabilities;
    let ids;
    if (probs && typeof probs === "object" && !Array.isArray(probs)) {
      ids = shortlist
        .filter((id) => Number(probs[id]) >= FLOORS.candidate)
        .sort((a, b) => probs[b] - probs[a]);
    } else {
      const top = Math.max(0, ...scores);
      const near = shortlist.filter((id, i) => top > 0 && (scores[i] ?? 0) >= top / 2);
      ids = shortlist.includes(pick?.choice) ? [pick.choice, ...near.filter((id) => id !== pick.choice)] : near;
    }
    if (ids.length) out.candidates = ids.slice(0, MAX_CANDIDATES);
  }

  const tier = answers.tier;
  if (tier) {
    let level = null;
    // TWO SHAPES FOR ONE FIELD. TypeSafe's docs show `probabilities` as an
    // array indexed by level; Vercel's gateway returns it as an object keyed
    // "0", "1", … — measured on a live call. Without this branch the object
    // was quietly ignored and the tier fell back to rounding the score, which
    // is not the same answer when the mass is split.
    const probs = Array.isArray(tier.probabilities)
      ? tier.probabilities
      : tier.probabilities && typeof tier.probabilities === "object"
        ? Object.keys(tier.probabilities).sort((a, b) => Number(a) - Number(b))
            .map((k) => Number(tier.probabilities[k]))
        : [];
    if (probs.length) {
      level = probs.indexOf(Math.max(...probs));
    } else if (typeof tier.score === "number") {
      level = Math.round(tier.score);
    }
    if (level != null && TIERS[level]) {
      out.tier = TIERS[level];
      out.confidence.tier = tier.confidence ?? null;
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

const COULD_NOT_TELL = /too (short|garbled)/i;

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
    apps: Array.isArray(summary.apps) ? summary.apps : [],
    windows: Array.isArray(summary.windows) ? summary.windows : [],
    screenTerms: Array.isArray(summary.screenTerms) ? summary.screenTerms : [],
    repoHints: Array.isArray(summary.repoHints) ? summary.repoHints : [],
    outcome,
  };
}
