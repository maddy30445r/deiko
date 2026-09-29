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
  /**
   * Connector/trace only: accessibility strings read at the STROKE'S START,
   * from the probe's `startSnapshot`. A connector has two ends and `ax` alone
   * only ever named the one under the cursor at commit — this is the other one.
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
   * Stable within a session: "r1", "r2", … Cited by the brief, and assigned in
   * insertion order — which, since the loader sorts chronologically before
   * adding, is what makes this a STACK rather than a bag. "The one before
   * that" and "earlier" read off the order of `all()`.
   */
  id: string;
  /** Which hotkey hold. Releasing the key is a hard boundary for utterances. */
  hold: number;
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
  /** Present when a modifier stroke minted this referent: the badge number on
   *  its crop and the classified gesture kind (point/lasso/connector/trace/
   *  emphasis — or newer values this build has never heard of). */
  mark?: { kind: string; number: number };

  /**
   * What the page or document itself is called, where the app said so: the
   * browser's web-area title ("Signups — build"), its address (host and path
   * only — the recorder never keeps a query), the window's open document, and
   * headings and element ids under the pointer. Labels for filing, read by
   * `packages/core/src/lib/labels.mjs`. Absent when none of it was captured.
   */
  page?: ReferentPage;

  /**
   * How the pointing act itself happened — recorded at capture, never judged
   * there. The alignment engine uses these to discount settles that were
   * probably not deliberate: a cursor arriving after an app switch, a pause
   * while the page scrolled underneath, a drift-to-a-halt rather than a
   * decelerate-to-a-stop.
   *
   * Absent for regions, which need no such defence — nobody draws a loop by
   * accident.
   */
  capture?: {
    dwellMs: number;
    approachSpeed: number;
    msSinceAppSwitch?: number;
    msSinceScroll?: number;
  };

  // ── filled by alignment, absent at capture time ──
  utterance?: string;
  confidence?: number;
  reason?: "deictic" | "overlap" | "unbound";
}

