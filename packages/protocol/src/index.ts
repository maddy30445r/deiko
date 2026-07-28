/**
 * The Swift↔TypeScript wire contract.
 *
 * Mirrors `apps/capture/Sources/FoveaCapture/Events.swift` field for field.
 * The capture binary emits one JSON object per line on stdout; everything here
 * describes those lines. If you change a type here, change it there.
 *
 * Invariants worth knowing before you use these:
 *   • `t` is milliseconds on a MONOTONIC clock, shared by every stream in a
 *     session (cursor, audio, crops). Never relate two streams by wall time.
 *   • All coordinates are TOP-LEFT-ORIGIN global screen space (AX's space).
 *   • A referent is a SHAPE, not a position: pointing and circling are the same
 *     act at different granularity.
 */

export type EventType =
  | "hello"
  | "probe"
  | "error"
  | "sessionStart"
  | "sessionEnd"
  | "holdStart"
  | "holdEnd"
  | "cursor"
  | "candidate";

export interface Point {
  x: number;
  y: number;
}

export interface Frame {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type ShapeKind = "point" | "region";

/**
 * What the user indicated. For a region, `path` is the raw freehand polygon and
 * `bounds` is its bounding box — the crop rectangle. The path is kept so the
 * crop can be masked to the drawn area rather than the rectangle around it.
 */
export interface Shape {
  kind: ShapeKind;
  origin: Point;
  bounds: Frame;
  path?: Point[];
}

export interface AppIdentity {
  pid: number;
  bundleId?: string;
  name?: string;
}

export interface Ancestor {
  role?: string;
  subrole?: string;
  title?: string;
}

/** One resolved UI element. All values are copies — AX handles go stale. */
export interface AXElement {
  role?: string;
  subrole?: string;
  title?: string;
  value?: string;
  elementDescription?: string;
  selectedText?: string;
  frame?: Frame;
  /** Up to 3 levels of parent, nearest first. */
  ancestors: Ancestor[];
  /** Every attribute the element advertises — how per-app quirks get found. */
  attributeNames: string[];
}

export interface AXSnapshot {
  resolved: boolean;
  /** One element for a point probe; every element inside the path, in reading
   *  order, for a region probe. */
  elements: AXElement[];
  /** Region only. `samplesTested / uniqueElements` is the granularity ratio:
   *  60 samples collapsing to 1 element means the tree is too coarse to ground
   *  a circled region, even though AX nominally "works" in that app. */
  samplesTested?: number;
  uniqueElements?: number;
  /** True when elements only appeared after AXManualAccessibility was set on
   *  the owning app — i.e. the Electron bridge had to be poked. */
  manualAccessibilityApplied: boolean;
  /** Time inside AX calls. Every attribute read is a Mach IPC round-trip, so
   *  this is what tells us whether region capture fits the latency budget. */
  elapsedMs: number;
  error?: string;
}

/**
 * One line of recognised text, positioned in global screen coordinates so it
 * can be related to the shape and to AX element frames — not a bag of words.
 */
export interface OCRLine {
  text: string;
  confidence: number;
  frame: Frame;
}

/**
 * The Tier 1 base. Captured for EVERY referent, never as a fallback: the review
 * UI needs a thumbnail per plan step, and the highest-frequency use case (the
 * frontend visual loop) is about how something looks, which no accessibility
 * tree can express.
 *
 * `ocr` is the conditional half — populated only when AX returned no usable
 * text, because Vision costs a few hundred ms and AX strings are exact.
 */
export interface CropResult {
  /** Where the PNG was written; absent when captured in memory only. */
  path?: string;
  /** The region actually captured, in global screen coordinates. */
  rect: Frame;
  /** True when clipped to the freehand path rather than left rectangular. */
  masked: boolean;
  /** True when `rect` came from an AX element frame rather than a default box.
   *  This is where a "failed" AX hit still pays: an app can give no text but
   *  still give the row's rectangle, which crops far better than a fixed box. */
  rectFromAX: boolean;
  ocr: OCRLine[];
  captureElapsedMs: number;
  ocrElapsedMs?: number;
  error?: string;
}

export interface ProbeEvent {
  type: "probe";
  /** The moment the user POINTED — not when the screenshot finished. */
  t: number;
  shape: Shape;
  /** Regions only: when the drag began and ended, measured by the recorder. */
  span?: { start: number; end: number };
  app?: AppIdentity;
  windowTitle?: string;
  snapshot: AXSnapshot;
  crop?: CropResult;
}

export interface HelloEvent {
  type: "hello";
  t: number;
  binary: string;
  version: string;
  pid: number;
  /** ISO8601. The one place wall time appears — for dating a session, never
   *  for relating streams within one. */
  epochWall: string;
  axTrusted: boolean;
}

export interface ErrorEvent {
  type: "error";
  t: number;
  message: string;
  hint?: string;
}

/**
 * Why a cursor settle was logged, and what surrounded it.
 *
 * Every settle is recorded as a CANDIDATE and nothing is filtered at capture
 * time. Cursor data alone cannot separate a pointing act from a resting hand —
 * cursor data plus narration can. A candidate that never binds to speech simply
 * never becomes a referent, and costs nothing.
 */
export interface CandidateFeatures {
  /** How long the cursor stayed put. Longer reads as more deliberate. */
  dwellMs: number;
  /** Peak speed (px/s) in the 200ms before the stop. Deceleration INTO a stop
   *  is a deliberate point; a pause mid-sweep is transit. */
  approachSpeed: number;
  /** The first settle after an app switch is usually the cursor arriving. */
  msSinceAppSwitch?: number;
  /** A settle while the page scrolls underneath is not a new pointing act. */
  msSinceScroll?: number;
  /** Time since speech was last heard; absent when there is no audio at all.
   *  The only feature that speaks to INTENT rather than mechanics — and the one
   *  that gates capture, since a settle far from any narration is never
   *  recorded now that sessions run continuously. */
  msSinceVoice?: number;
}

export interface CandidateEvent {
  type: "candidate";
  t: number;
  position: Point;
  features: CandidateFeatures;
  app?: AppIdentity;
}

/** Raw cursor sample, kept at full rate so settle thresholds can be re-derived
 *  from a recording without re-recording it. */
export interface CursorEvent {
  type: "cursor";
  t: number;
  x: number;
  y: number;
}

/** One press-and-release of the hotkey: one utterance, one WAV, its own t0.
 *
 *  These were emitted as `sessionStart`/`sessionEnd` back when a session WAS a
 *  hold. A session now spans many holds and is closed explicitly by the user,
 *  so that name described the wrong boundary. Readers should accept the old
 *  names too — sessions recorded before the split are still valid data. */
export interface HoldEvent {
  type: "holdStart" | "holdEnd" | "sessionStart" | "sessionEnd";
  t: number;
  id: string;
  /** Which hold of the hotkey this is, 1-based. The natural grouping for the
   *  referent stack, and part of every crop filename. */
  hold: number;
  referentCount?: number;
  audioPath?: string;
  /** Monotonic reading at the FIRST captured audio buffer. Every word timestamp
   *  the ASR returns is an offset from this — not from `t`, because the mic
   *  takes a few ms to start delivering and that gap would become a constant
   *  skew in every binding. */
  audioT0?: number;
}

/** The recording as a whole — first and last line of `events.jsonl`. Told apart
 *  from a legacy per-hold event by the ABSENCE of `hold`. */
export interface SessionEvent {
  type: "sessionStart" | "sessionEnd";
  t: number;
  id: string;
  hold?: undefined;
  /** ISO8601, `sessionStart` only — the session's one wall-clock reading. */
  epochWall?: string;
  /** Totals across every hold. `sessionEnd` only. */
  holdCount?: number;
  referentCount?: number;
}

export type CaptureEvent =
  | HelloEvent
  | ProbeEvent
  | ErrorEvent
  | CandidateEvent
  | CursorEvent
  | HoldEvent
  | SessionEvent;

/** Parse one JSON Lines chunk from the capture binary's stdout. */
export function parseEventLine(line: string): CaptureEvent | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  const parsed: unknown = JSON.parse(trimmed);
  if (typeof parsed !== "object" || parsed === null || !("type" in parsed)) return null;
  return parsed as CaptureEvent;
}

/**
 * The best available text for an element, in the order that actually carries
 * meaning: its own value, then its label, then its accessibility description.
 */
export function elementText(el: AXElement): string | undefined {
  return el.value ?? el.title ?? el.elementDescription ?? el.selectedText;
}

/**
 * All the text a referent grounded, best source first.
 *
 * AX text is authoritative where it exists: it is the literal string the app is
 * rendering. OCR has to *decide* between `l`, `1` and `I`, and it reads editor
 * chrome — whitespace dots, gutter line numbers — as characters. In a plan that
 * Claude Code will execute, one wrong character is a wrong edit, so OCR is a
 * fallback for where AX is silent, never a substitute for it.
 */
export function referentText(event: ProbeEvent): { text: string; source: "ax" | "ocr" }[] {
  const ax = event.snapshot.elements
    .map(elementText)
    .filter((t): t is string => !!t && t.trim().length > 0)
    .map((text) => ({ text, source: "ax" as const }));

  if (ax.length > 0) return ax;

  return (event.crop?.ocr ?? []).map((line) => ({ text: line.text, source: "ocr" as const }));
}
