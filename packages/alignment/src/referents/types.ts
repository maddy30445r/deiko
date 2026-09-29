/**
 * The referent stack: an ordered, cross-application record of the things a
 * person pointed at.
 *
 * A referent is created when you point. What you said about it arrives later
 * from the alignment engine, so every utterance field is optional.
 */

export type ReferentKind = "point" | "region";

/** Where a referent's text came from, kept apart on purpose. */
export interface ReferentText {
  /**
   * Accessibility strings: the literal characters the app is rendering.
   * Exact. `getUserProficiency` is `getUserProficiency`.
   */
  ax: string[];
  /**
   * OCR strings: read off pixels, so a guess (`l`, `1` and `I` are confusable,
   * and editor chrome such as gutter numbers reads as characters).
   *
   * Never merged with `ax`: an identifier that came from OCR deserves a grep
   * before it is edited; one from AX does not.
   */
  ocr: string[];
  /**
   * Connector/trace only: accessibility strings read at the stroke's start,
   * from the probe's `startSnapshot`. `ax` alone only names the element under
   * the cursor at commit.
   */
  axStart?: string[];
}

/** What a page or document calls itself — see `Referent.page`. */
export interface ReferentPage {
  title?: string;
  url?: string;
  document?: string;
  headings?: string[];
  domIds?: string[];
}

export interface Referent {
  /**
   * Stable within a session: "r1", "r2", … Cited by the brief. Assigned in
   * insertion order, which is chronological, so "the one before that" reads off
   * the order of `all()`.
   */
  id: string;
  /** Which hotkey hold. Releasing the key is a hard boundary for utterances. */
  hold: number;
  /** Session-clock milliseconds — the same monotonic clock as audio and cursor. */
  t: number;
  /**
   * Regions only: the drag's real duration. A lasso is not an instant and the
   * user narrates throughout it, so binding against a single timestamp misses
   * most of what was said.
   */
  span?: { start: number; end: number };
  kind: ReferentKind;

  app: { name?: string; bundleId?: string };
  /**
   * Window title. Free, and rich: "auth.saga.ts — acme-portal" gives file and
   * repo; "[ENG-880] … - Jira" gives the ticket. Present even where the
   * accessibility tree resolved nothing.
   */
  window?: string;

  text: ReferentText;
  cropPath?: string;
  /** Present when a modifier stroke minted this referent: the badge number on
   *  its crop and the gesture kind (point/lasso/connector/trace/emphasis, or
   *  newer values this build does not know). */
  mark?: { kind: string; number: number };

  /**
   * What the page or document calls itself, where the app said so: the
   * browser's web-area title, its address (host and path only; the recorder
   * never keeps a query), the window's open document, and headings and element
   * ids under the pointer. Labels for filing, read by
   * `packages/core/src/lib/labels.mjs`. Absent when none was captured.
   */
  page?: ReferentPage;

  /**
   * How the pointing act itself happened, recorded at capture and never judged
   * there. The alignment engine uses it to discount settles that were probably
   * not deliberate: arriving after an app switch, a pause while the page
   * scrolled, drifting to a halt. Absent for regions.
   */
  capture?: {
    dwellMs: number;
    approachSpeed: number;
    msSinceAppSwitch?: number;
    msSinceScroll?: number;
  };

  // Filled by alignment; absent at capture time.
  utterance?: string;
  confidence?: number;
  reason?: "deictic" | "overlap" | "unbound";
}

