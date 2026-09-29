import { isDeictic, joinWords, normalizeWord } from "./deictic.js";
import {
  type AlignmentOptions,
  type AlignmentResult,
  type Binding,
  type Candidate,
  type Word,
  DEFAULT_OPTIONS,
  LOW_CONFIDENCE,
} from "./types.js";

/**
 * Binds spoken utterances to pointing events.
 *
 * The recorder over-captures: every cursor settle becomes a candidate,
 * including hands resting mid-transit, landings after an app switch and pauses
 * while the page scrolls. Cursor data alone cannot separate those from real
 * pointing acts, so the narration is the filter, in two passes:
 *   1. Deictic words claim their nearest plausible candidate (strong signal).
 *   2. Candidates with no deictic nearby fall back to whatever was being said
 *      while they were dwelt on (weaker, but still a pointing act).
 */
export function align(
  candidates: Candidate[],
  words: Word[],
  options: Partial<AlignmentOptions> = {},
): AlignmentResult {
  const opts = { ...DEFAULT_OPTIONS, ...options };
  const bindings: Binding[] = [];
  const claimed = new Set<string>();

  // Pass 1: deictic words claim candidates.
  for (let i = 0; i < words.length; i++) {
    const word = words[i]!;
    if (!isDeictic(word.text)) continue;

    const scored = candidates
      .filter((c) => !claimed.has(c.id))
      .map((c) => ({ candidate: c, score: scoreCandidate(c, word, opts) }))
      .filter((s) => s.score > 0)
      .sort((a, b) => b.score - a.score);

    const best = scored[0];
    if (!best) continue;

    // The margin over the runner-up, not the raw score, is the confidence
    // signal: two candidates close in time both score well against "this", and
    // that ambiguity is what the review UI needs to flag.
    const runnerUp = scored[1]?.score ?? 0;
    const margin = (best.score - runnerUp) / best.score;
    const confidence = clamp01(best.score * (0.6 + 0.4 * margin));

    const around = utteranceAround(words, i);
    claimed.add(best.candidate.id);
    bindings.push({
      candidateId: best.candidate.id,
      deicticWord: word.text,
      deicticAt: word.start,
      utterance: around.utterance,
      utteranceStart: around.utteranceStart,
      confidence,
      reason: "deictic",
      // Still unsure: two candidates nearly tied, or the pick sat far from the word.
      needsReview: confidence < LOW_CONFIDENCE,
      // Spread rather than assigned: `exactOptionalPropertyTypes` forbids an
      // explicit `undefined`, and a transcript predating `anchored` must leave
      // this absent rather than claim the timing was interpolated.
      ...(word.anchored !== undefined && { anchoredTiming: word.anchored }),
    });
  }

  // Pass 2: overlap fallback.
  for (const candidate of candidates) {
    if (claimed.has(candidate.id)) continue;

    // What was being said while the cursor rested here. The hold check keeps a
    // candidate just after a release from absorbing the previous hold's
    // trailing words, the merge pass 1 forbids.
    const dwellStart = candidate.t - candidate.features.dwellMs;
    const spoken = words.filter(
      (w) => w.end >= dwellStart && w.start <= candidate.t && sameHold(w, candidate),
    );
    if (spoken.length === 0) continue;

    claimed.add(candidate.id);
    bindings.push({
      candidateId: candidate.id,
      utterance: joinWords(spoken.map((w) => w.text)),
      utteranceStart: spoken[0]!.start,
      // Capped below the deictic path: overlapping speech is weaker evidence
      // than a word that explicitly points.
      confidence: clamp01(0.45 * noiseMultiplier(candidate)),
      reason: "overlap",
      // Never flagged individually: 0.45 with at most a ×1.1 and a ×1.05 lift
      // cannot reach 0.5, so a raw threshold would flag every overlap binding.
      // The class is weaker; the brief says so once.
      needsReview: false,
    });
  }

  return {
    bindings: bindings.sort((a, b) => a.utteranceStart - b.utteranceStart),
    unbound: candidates.filter((c) => !claimed.has(c.id)).map((c) => c.id),
  };
}

/** The hold rule shared by both passes: known-and-different holds never bind,
 *  and an unknown hold binds freely. `hold` is optional on both sides because
 *  this package is tested in isolation, without holds, while the recorder
 *  always writes one. */
function sameHold(word: Word, candidate: Candidate): boolean {
  return (
    word.hold === undefined ||
    candidate.hold === undefined ||
    word.hold === candidate.hold
  );
}

/**
 * How well one candidate explains one deictic word. Zero means "outside the
 * window, not a possibility at all".
 */
function scoreCandidate(
  candidate: Candidate,
  word: Word,
  opts: AlignmentOptions,
): number {
  // Across a hold boundary, no score at all — the key came up in between.
  if (!sameHold(word, candidate)) return 0;

  const delta = word.start - candidate.t;

  // Asymmetric on purpose: people move the cursor first and speak as they
  // arrive, so a pointing act well before the word is normal, while one long
  // after it is not.
  if (delta > opts.lookBackMs) return 0;
  if (delta < -opts.lookAheadMs) return 0;

  const window = delta >= 0 ? opts.lookBackMs : opts.lookAheadMs;
  const proximity = 1 - Math.abs(delta) / window;

  // A region is an explicit, deliberate gesture — nobody accidentally draws a
  // loop — so it outranks a mere settle at equal distance.
  const deliberate = candidate.kind === "region" ? 1.15 : 1.0;

  // A candidate that resolved nothing is a poor referent even if it is closest:
  // binding "this" to an empty patch of desktop helps no one.
  const grounding = candidate.grounded ? 1.0 : 0.55;

  return clamp01(proximity * deliberate * grounding * noiseMultiplier(candidate));
}

/**
 * Penalties for noise the recorder measured but did not filter at capture time;
 * each describes a settle that is probably not a pointing act.
 */
function noiseMultiplier(candidate: Candidate): number {
  const { dwellMs, approachSpeed, msSinceAppSwitch, msSinceScroll } = candidate.features;
  let m = 1.0;

  // The cursor landing after an app switch is arriving, not pointing.
  if (msSinceAppSwitch !== undefined && msSinceAppSwitch < 400) m *= 0.6;

  // A settle while the page moves underneath is not a new pointing act — the
  // cursor never moved, the content did.
  if (msSinceScroll !== undefined && msSinceScroll < 300) m *= 0.7;

  // A long rest is deliberate; a brief one is often mid-transit hesitation.
  if (dwellMs > 600) m *= 1.1;

  // Stopping dead from speed reads as "I went there on purpose". Drifting to a
  // halt reads as a hand coming to rest.
  if (approachSpeed > 800) m *= 1.05;

  return m;
}

/**
 * The utterance a deictic word belongs to: the sentence around it, bounded by a
 * conversational pause.
 */
function utteranceAround(
  words: Word[],
  index: number,
  gapMs = 700,
): { utterance: string; utteranceStart: number } {
  const hold = words[index]!.hold;
  // A hold boundary stops the walk unconditionally: releasing the hotkey ends
  // the utterance, so two holds can never merge into one sentence however close
  // their timestamps happen to be.
  const sameHold = (w: Word) => w.hold === hold;

  let start = index;
  while (
    start > 0 &&
    sameHold(words[start - 1]!) &&
    words[start]!.start - words[start - 1]!.end < gapMs
  ) start--;

  let end = index;
  while (
    end < words.length - 1 &&
    sameHold(words[end + 1]!) &&
    words[end + 1]!.start - words[end]!.end < gapMs
  ) end++;

  const span = words.slice(start, end + 1);
  return {
    utterance: joinWords(span.map((w) => w.text)),
    utteranceStart: span[0]!.start,
  };
}

function clamp01(n: number): number {
  return Math.max(0, Math.min(1, n));
}

export { isDeictic, joinWords, normalizeWord };
export * from "./types.js";
