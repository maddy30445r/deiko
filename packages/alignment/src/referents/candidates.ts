import type { Referent } from "./types.js";

/**
 * Adapt referents into the shape the alignment engine scores. Shared by every
 * consumer so the region-timing rule below has a single copy.
 */
export interface AlignerCandidate {
  id: string;
  hold?: number;
  t: number;
  features: {
    dwellMs: number;
    approachSpeed: number;
    msSinceAppSwitch?: number;
    msSinceScroll?: number;
  };
  app?: { name?: string; bundleId?: string };
  kind: "point" | "region";
  grounded: boolean;
  text?: string;
}

export function toCandidates(referents: readonly Referent[]): AlignerCandidate[] {
  return referents.map((r) => {
    const text = candidateText(r);
    return {
      id: r.id,
      hold: r.hold,
      // Regions anchor at the drag's end with a dwell equal to the full span, so
      // the overlap window is exactly [dragStart, dragEnd]. Anchoring at the
      // midpoint would shift the window early and miss the drag's second half,
      // where the narration is.
      t: r.span ? r.span.end : r.t,
      features: r.capture ?? {
        // A deliberate drag needs no defence against being mistaken for a
        // resting hand. Its dwell is the real gesture duration.
        dwellMs: r.span ? r.span.end - r.span.start : 600,
        approachSpeed: 0,
      },
      app: r.app,
      kind: r.kind,
      grounded: r.text.ax.length > 0 || r.text.ocr.length > 0,
      // Spread rather than assign: `exactOptionalPropertyTypes` forbids setting
      // an optional property to an explicit undefined.
      ...(text === undefined ? {} : { text }),
    };
  });
}

/** One-line description for reporting. AX first, since it is the exact string. */
export function candidateText(r: Referent): string | undefined {
  if (r.text.ax.length > 0) return r.text.ax.join(" · ").slice(0, 90);
  if (r.text.ocr.length > 0) return `[ocr] ${r.text.ocr.join(" ").slice(0, 90)}`;
  return undefined;
}
