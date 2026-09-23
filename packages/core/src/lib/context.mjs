/**
 * THE MEMORY — which collection a brief belongs to, which earlier briefs it
 * continues or draws on, and how much work it looks like.
 *
 * Everything here is arithmetic over what the classifier answered. The
 * classifier is Jev (TypeSafe AI's "System One" model), reached through the
 * relay by `scripts/classify.mjs`; it returns calibrated probabilities, and
 * these floors are the only place they become decisions. The thresholds are
 * tuned against `jev-1.13.0`, which the relay pins — see `JEV_MODEL` there.
 *
 * Pure, except `readBriefLine`, which is the one way a sibling session is
 * read so that `classify.mjs` (building candidates) and `render-brief.mjs`
 * (resolving the ones that were chosen) cannot disagree about what a session
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
  quickHint: 0.8,
};

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
 * Returns `{ collection, task, newTask, tier, confidence, newCollection }`.
 * `newCollection` is `{ id, name }` when the brief matched no collection but
 * carries a repo hint that is not one yet — the caller creates it. `newTask`
 * is `{ id, title }` when no shortlisted task was confidently chosen — the
 * caller creates it. Never throws on a partial answer: a missing question
 * reads as "no".
 */
export function decide({ answers = {}, collections = [], repoHints = [], shortlist = [], sessionId = null, title = null } = {}) {
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
  if (pick && shortlist.includes(pick.choice) && (pick.confidence ?? 0) >= FLOORS.task) {
    out.task = pick.choice;
    out.confidence.task = pick.confidence;
  } else if (sessionId) {
    out.task = `t-${sessionId}`;
    out.newTask = { id: out.task, title: title ?? "A brief" };
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
    outcome: outcomeText?.trim() ? parseOutcome(outcomeText.slice(0, 8000)) : null,
  };
}
