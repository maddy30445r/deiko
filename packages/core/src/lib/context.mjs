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

import { existsSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";

import { redact } from "./redact.mjs";

/// How many earlier briefs one classification call looks at. Newest first.
///
/// ponytail: 120 keeps a request near 10k tokens. Older briefs stay on disk
/// and are simply not searched; when a board outgrows this, the upgrade is
/// two calls — collection first, then relatedness over everything in it.
export const CANDIDATE_LIMIT = 120;

/// Where a probability becomes a decision.
///
/// `guessed` is not a floor: between `collection` and `guessed` the answer is
/// taken but shown as a guess, so a correction reads as invited rather than as
/// fixing a mistake.
export const FLOORS = {
  collection: 0.6,
  continues: 0.7,
  related: 0.7,
  guessed: 0.85,
  quickHint: 0.8,
};

/// The Score levels, in order. Index = level. MIRRORS the rubric in
/// `services/relay/relay.mjs` (`TIER_RUBRIC`): the relay names the levels to
/// the model, this names them to the app. Change both.
export const TIERS = ["quick", "medium", "complex", "reasoning"];

/// How many related briefs ride along at most. Five paths is a reading list;
/// twenty is a dump.
export const RELATED_LIMIT = 5;

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
 * The earlier briefs one call is allowed to consider.
 *
 * `sessions` is `[{ id, narration, collection, outcome }]` in any order.
 * Returns newest first (the stamp sorts lexically), the current session
 * excluded, anything without a usable narration excluded, capped at `limit`.
 * Each entry is what the relay forwards: a date, the collection NAME the
 * model can read, one redacted line of narration, and the first line of the
 * outcome if an agent wrote one.
 */
export function pickCandidates(sessions, { exclude = null, limit = CANDIDATE_LIMIT, collections = [] } = {}) {
  const names = new Map(collections.map((c) => [c.id, c.name]));
  return [...sessions]
    .filter((s) => STAMP.test(s.id) && s.id !== exclude)
    .filter((s) => (s.narration ?? "").trim().length >= MIN_NARRATION)
    .sort((a, b) => (a.id < b.id ? 1 : a.id > b.id ? -1 : 0))
    .slice(0, limit)
    .map((s) => ({
      id: s.id,
      date: briefDate(s.id),
      collection: names.get(s.collection) ?? null,
      line: redact(s.narration).replace(/\s+/g, " ").trim().slice(0, 200),
      outcome: s.outcome ? redact(s.outcome).replace(/\s+/g, " ").trim().slice(0, 120) : null,
    }));
}

/**
 * The classifier's answers, turned into a `context.json`.
 *
 * Returns `{ collection, continues, related, tier, confidence, newCollection }`.
 * `newCollection` is `{ id, name }` when the brief matched no collection but
 * carries a repo hint that is not one yet — the caller creates it. Never
 * throws on a partial answer: a missing question reads as "no".
 */
export function decide({ answers = {}, collections = [], repoHints = [] } = {}) {
  const out = {
    collection: null,
    continues: null,
    related: [],
    tier: null,
    confidence: {},
    newCollection: null,
  };

  const known = new Set(collections.map((c) => c.id));
  const pick = answers.collection;
  if (pick && known.has(pick.choice) && (pick.confidence ?? 0) >= FLOORS.collection) {
    out.collection = pick.choice;
    out.confidence.collection = pick.confidence;
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

  const cont = answers.continues;
  if (cont && cont.choice !== "none" && STAMP.test(cont.choice ?? "")
      && (cont.confidence ?? 0) >= FLOORS.continues) {
    out.continues = cont.choice;
    out.confidence.continues = cont.confidence;
  }

  out.related = Object.entries(answers)
    .filter(([key]) => key.startsWith("rel_"))
    .map(([key, a]) => ({ id: key.slice(4), p: Number(a?.noul ?? 0) }))
    .filter(({ id, p }) => STAMP.test(id) && id !== out.continues && p >= FLOORS.related)
    .sort((a, b) => b.p - a.p)
    .slice(0, RELATED_LIMIT)
    .map(({ id }) => id);

  const tier = answers.tier;
  if (tier) {
    let level = null;
    if (Array.isArray(tier.probabilities) && tier.probabilities.length) {
      level = tier.probabilities.indexOf(Math.max(...tier.probabilities));
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

/**
 * What a sibling session says, read the one way both scripts read it.
 *
 * `{ narration, collection, outcome }` — `outcome` is the first three lines
 * of `outcome.md` joined by a space, or null. Missing pieces are null, never
 * a throw: the board is full of sessions whose brief never rendered.
 */
export function readBriefLine(sessionDir) {
  let narration = null;
  try {
    narration = JSON.parse(readFileSync(join(sessionDir, "brief.json"), "utf8"))?.summary?.narration ?? null;
  } catch {
    narration = null;
  }
  let collection = null;
  try {
    collection = JSON.parse(readFileSync(join(sessionDir, "context.json"), "utf8"))?.collection ?? null;
  } catch {
    collection = null;
  }
  let outcome = null;
  const outcomePath = join(sessionDir, "outcome.md");
  if (existsSync(outcomePath)) {
    const lines = readFileSync(outcomePath, "utf8")
      .split("\n")
      .map((l) => l.replace(/^#+\s*/, "").trim())
      .filter(Boolean)
      .slice(0, 3);
    outcome = lines.length ? lines.join(" ") : null;
  }
  return { id: basename(sessionDir), narration, collection, outcome };
}
