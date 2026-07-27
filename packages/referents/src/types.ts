/**
 * THE REFERENT STACK — the session memory of everything the user pointed at.
 *
 * This is the moat. Screen-aware assistants capture the current screen; coding
 * agents see the repo. Neither keeps an ordered, cross-application record of
 * the specific things a person indicated over the last two minutes — which is
 * what makes "expose that key we showed earlier as `status`" resolvable at all.
 *
 * A referent is created the moment you point. What you SAID about it arrives
 * later, from the alignment engine, which is why every utterance field is
 * optional: a referent is a thing-you-indicated first and a plan-step ingredient
 * second.
 */

export type ReferentKind = "point" | "region";

/** Where a referent's text came from. Kept apart, deliberately — see below. */
export interface ReferentText {
  /**
   * Accessibility strings: the literal characters the app is rendering.
   * Exact. `getUserProficiency` is `getUserProficiency`.
   */
  ax: string[];
  /**
   * OCR strings: read off pixels. A guess. Vision has to decide between `l`,
   * `1` and `I`, and it reads editor chrome — whitespace dots, gutter line
   * numbers — as characters.
   *
   * Never merged into one list, because a consumer about to write code needs
   * to know which of the two it is trusting. An identifier that came from OCR
   * deserves a grep before it is edited; one from AX does not.
   */
  ocr: string[];
}

export interface Referent {
  /** Stable within a session: "r1", "r2", … Cited by plan steps. */
  id: string;
  /**
   * Insertion order. This is what makes it a STACK rather than a bag — "the
   * one before that", "earlier", and cross-app sequencing all read from here.
   */
  index: number;
  /** Which hotkey hold. Releasing the key is a hard boundary for utterances. */
  hold: number;
  /**
   * Which VISIT to an app this referent belongs to — a counter that increments
   * every time the frontmost app changes. Compass → VS Code → back to Compass
   * produces visits 1, 2, 3, so the two Compass runs are distinguishable even
   * though `app` is identical.
   *
   * `index` alone handles coming back to an app perfectly well — it is global
   * and chronological, so a later referent is simply later. Visits exist for
   * one specific job: BACK-REFERENCE. When you say "that key we showed
   * earlier" while in your third visit, "earlier" almost never means the
   * referent you captured eight seconds ago in this same visit — it means a
   * previous excursion. Without visits, recency scoring confidently returns
   * the wrong Compass field.
   */
  visit: number;
  /** Session-clock milliseconds — the same monotonic clock as audio and cursor. */
  t: number;
  /**
   * Regions only: the drag's real duration. A lasso is not an instant — one
   * measured 6 seconds, and the user narrated throughout it, so binding
   * against a single timestamp misses most of what was said.
   */
  span?: { start: number; end: number };
  kind: ReferentKind;

  app: { name?: string; bundleId?: string };
  /**
   * Window title. Free, and unexpectedly rich: "auth.saga.ts — acme-portal"
   * gives file AND repo; "[ENG-880] … - Jira" gives the ticket. Present in
   * 100% of probes even where the accessibility tree resolved nothing.
   */
  window?: string;

  text: ReferentText;
  cropPath?: string;

  // ── filled by alignment, absent at capture time ──
  utterance?: string;
  confidence?: number;
  reason?: "deictic" | "overlap" | "unbound";
}

/** A phrase that reaches back to something indicated earlier. */
export interface BackReference {
  /** The phrase as spoken: "that key we showed earlier". */
  phrase: string;
  /** When it was said, on the session clock. */
  t: number;
  /**
   * Ranked candidates from the past. Deliberately a SHORTLIST, not an answer:
   * scoring can rank by recency and word overlap, but it cannot know that "the
   * key" means the field named `identifier`. Code narrows, the model picks, and
   * the review UI can show what it chose between.
   */
  candidates: Array<{ referentId: string; score: number; why: string }>;
}
