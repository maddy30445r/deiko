/**
 * Inputs and outputs of the alignment engine.
 *
 * All times are milliseconds on the capture session's monotonic clock.
 * Transcript words arrive as offsets into an audio file, so the loader adds
 * that hold's `audioT0` first; skipping it puts every word early and binds
 * referents to the wrong utterance without anything looking broken.
 */

export interface Word {
  text: string;
  /** Session-clock milliseconds, not an offset into the audio file. */
  start: number;
  end: number;
  /**
   * Which hotkey hold this word was spoken in. A hold boundary is a hard
   * utterance boundary (the key was released), so words from different holds
   * are never joined into one utterance.
   */
  hold?: number;
  /**
   * Whether `start` is measured or interpolated. Word times merge the ASR text
   * with on-device timings: tokens both engines heard become anchors and the
   * words between them are spread evenly.
   *
   * Optional because older transcripts lack it, and absent must not read as
   * "interpolated".
   */
  anchored?: boolean;
}

/** A cursor settle the recorder logged. Not yet a referent. */
export interface Candidate {
  id: string;
  t: number;
  /** Which hotkey hold produced this candidate. Same hard-boundary rule as
   *  `Word.hold`. */
  hold?: number;
  features: {
    dwellMs: number;
    approachSpeed: number;
    msSinceAppSwitch?: number;
    msSinceScroll?: number;
  };
  app?: { name?: string; bundleId?: string };
  /** Whether AX or OCR actually resolved content here. */
  grounded: boolean;
  /** Best available text, for reporting and for the eventual prompt. */
  text?: string;
  kind: "point" | "region";
}

export interface Binding {
  candidateId: string;
  /** The word that pointed, when one did. */
  deicticWord?: string;
  deicticAt?: number;
  /** The utterance assigned to this referent. */
  utterance: string;
  utteranceStart: number;
  /** 0-1. Driven mostly by the margin over the runner-up — see `align.ts`. */
  confidence: number;
  /** Why this binding was made, for the review UI and for debugging. */
  reason: "deictic" | "overlap" | "unbound";
  /**
   * Whether a human should look at this one; not the same as low confidence.
   * Every overlap binding scores below 0.5 by construction, so a raw threshold
   * would flag them all. What deserves a per-row mark is the aligner having
   * been genuinely torn, such as a deictic word that could name two things.
   */
  needsReview: boolean;
  /**
   * Whether the deictic word that claimed this referent had a measured timing.
   * Pass 1's entire score is `word.start - candidate.t`, so an interpolated
   * word yields a guessed proximity. Reported but not scored. Undefined for
   * overlap bindings, which have no claiming word.
   */
  anchoredTiming?: boolean;
}

export interface AlignmentResult {
  bindings: Binding[];
  /** Candidates that never bound to speech. Expected: the recorder
   *  over-captures so the narration can be the filter. */
  unbound: string[];
}

/**
 * Below this, a binding from the strong (deictic) path is worth a second look.
 * Exported so the renderer shares the value with the confidence it judges.
 */
export const LOW_CONFIDENCE = 0.5;

export interface AlignmentOptions {
  /** How far before a deictic word a pointing act may sit: the user points
   *  first and speaks as they arrive. */
  lookBackMs: number;
  /** How far after a deictic word a pointing act may sit: the user speaks
   *  first, then moves to the thing. It is the larger side because real
   *  sessions showed speech leading the settle by more than a second. */
  lookAheadMs: number;
}

export const DEFAULT_OPTIONS: AlignmentOptions = {
  lookBackMs: 1500,
  lookAheadMs: 2000,
};
