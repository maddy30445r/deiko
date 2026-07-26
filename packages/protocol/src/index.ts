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

export type EventType = "hello" | "probe" | "error";

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

export interface ProbeEvent {
  type: "probe";
  t: number;
  shape: Shape;
  app?: AppIdentity;
  windowTitle?: string;
  snapshot: AXSnapshot;
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

export type CaptureEvent = HelloEvent | ProbeEvent | ErrorEvent;

export function isProbeEvent(e: CaptureEvent): e is ProbeEvent {
  return e.type === "probe";
}

export function isHelloEvent(e: CaptureEvent): e is HelloEvent {
  return e.type === "hello";
}

export function isErrorEvent(e: CaptureEvent): e is ErrorEvent {
  return e.type === "error";
}

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
