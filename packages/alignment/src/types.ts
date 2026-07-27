/**
 * Inputs and outputs of the alignment engine.
 *
 * Timing convention, which everything here depends on: all times are
 * milliseconds on the capture session's MONOTONIC clock. Transcript words
 * arrive from the ASR as offsets into an audio file, so the loader adds that
 * hold's `audioT0` before they get here. Skip that step and every word sits
 * ~255ms early — the measured mic spin-up — which is enough to bind referents
 * to the wrong utterance without anything looking broken.
 */

export interface Word {
  text: string;
  /** Session-clock milliseconds, NOT an offset into the audio file. */
  start: number;
  end: number;
  /**
   * Which hotkey hold this word was spoken in. A hold boundary is a HARD
   * utterance boundary — the user released the key and stopped talking — so
   * words from different holds must never be joined into one utterance, no
   * matter how close their timestamps are.
   */
  hold?: number;
}

/** A cursor settle the recorder logged. Not yet a referent. */
export interface Candidate {
  id: string;
  t: number;
  /** Which hotkey hold produced this candidate. Same hard-boundary rule as
   *  `Word.hold`: a word and a candidate from different holds must never
   *  bind, however close their timestamps sit across the release. */
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
  /** Why this binding was made, for the review UI and for debugging the gate. */
  reason: "deictic" | "overlap" | "unbound";
}

export interface AlignmentResult {
  bindings: Binding[];
  /** Candidates that never bound to speech. Expected and healthy: the recorder
   *  over-captures on purpose so the narration can be the filter. */
  unbound: string[];
}

export interface AlignmentOptions {
  /** How far BEFORE a deictic word a pointing act may sit — the user points
   *  first and speaks as they arrive. */
  lookBackMs: number;
  /** How far AFTER a deictic word a pointing act may sit — the user speaks
   *  first, then moves to the thing. Intuition said this should be the smaller
   *  side; real session data disagreed ("usko" spoken 1.4s before the settle
   *  on the CBSE cell it named), so it is now the larger one. */
  lookAheadMs: number;
}

export const DEFAULT_OPTIONS: AlignmentOptions = {
  lookBackMs: 1500,
  lookAheadMs: 2000,
};
