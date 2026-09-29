import { ReferentStack } from "./stack.js";
import type { Referent, ReferentPage } from "./types.js";

/**
 * Build a stack from a recorded session's `events.jsonl`.
 *
 * A pointing act arrives as two events: a `candidate` carrying the noise
 * features (dwell, approach speed, time since an app switch) and a `probe`
 * carrying what was grounded (accessibility elements, crop, OCR). Grounding
 * resolves asynchronously, so the probe lands slightly after its candidate;
 * re-pairing them is this loader's main job.
 *
 * Regions have no candidate: a drag is explicit. A flick too small to enclose
 * anything is demoted to a point by the recorder and also arrives as a bare
 * probe.
 */

interface RawEvent {
  type: string;
  t: number;
  [key: string]: unknown;
}

const PAIRING_WINDOW_MS = 1000;

/** A probe must also land where its candidate settled; time alone can pair a
 *  settle with a nearby degenerate-lasso probe that committed a millisecond
 *  closer. */
const PAIRING_RADIUS_PX = 12;

export function loadSession(events: RawEvent[]): ReferentStack {
  const stack = new ReferentStack();
  const probes = events.filter((e) => e.type === "probe") as any[];
  const candidates = events.filter((e) => e.type === "candidate") as any[];
  const cursors = events.filter((e) => e.type === "cursor") as any[];

  // Holds come from `holdStart` events; a referent's hold is the range its `t`
  // falls in. Candidates and probes carry no hold field themselves.
  const holdStarts = new Map<number, number>();
  for (const e of events as any[]) {
    if (e.hold == null) continue;
    if (e.type === "holdStart") holdStarts.set(e.hold, e.t);
  }
  const holdAt = (t: number): number => {
    for (const [hold, start] of holdStarts) {
      // A probe resolves asynchronously and can land after its hold's end, so a
      // hold is closed by the next hold's start.
      const nextStart = holdStarts.get(hold + 1) ?? Infinity;
      if (t >= start && t < nextStart) return hold;
    }
    return 1;
  };

  const usedProbes = new Set<number>();
  const drafts: Array<Omit<Referent, "id">> = [];

  // Points: candidate + its probe.
  for (const candidate of candidates) {
    let bestIndex = -1;
    let bestGap = Infinity;
    probes.forEach((p, i) => {
      if (usedProbes.has(i) || p.shape.kind !== "point") return;
      const gap = Math.abs(p.t - candidate.t);
      if (gap >= bestGap || gap >= PAIRING_WINDOW_MS) return;
      const origin = p.shape.origin;
      if (
        origin &&
        Math.hypot(origin.x - candidate.position.x, origin.y - candidate.position.y) >
          PAIRING_RADIUS_PX
      ) return;
      bestGap = gap;
      bestIndex = i;
    });
    const probe = bestIndex >= 0 ? (usedProbes.add(bestIndex), probes[bestIndex]) : undefined;

    drafts.push({
      hold: holdAt(candidate.t),
      t: candidate.t,
      kind: "point",
      app: {
        name: candidate.app?.name ?? probe?.app?.name,
        bundleId: candidate.app?.bundleId ?? probe?.app?.bundleId,
      },
      window: probe?.windowTitle,
      text: extractText(probe),
      cropPath: probe?.crop?.path,
      mark: probe?.mark,
      ...extractPage(probe),
      // Carried through verbatim: the recorder's notes on how suspicious the
      // settle was. The aligner decides.
      capture: candidate.features,
    });
  }

  // Probes with no candidate: regions and demoted-lasso points.
  for (let i = 0; i < probes.length; i++) {
    const probe = probes[i];

    if (probe.shape.kind !== "region") {
      if (usedProbes.has(i)) continue;
      // A flick demoted to a point: it grounded something and has a crop, just
      // no candidate and no settle features. Where the recorder measured a
      // `span`, use its midpoint, which is where the narration sits; `probe.t`
      // is the async probe's own emission time, 50-300ms after the tap.
      // Probes with no span fall back to `probe.t`.
      const span: { start: number; end: number } | undefined = probe.span;
      drafts.push({
        hold: holdAt(span ? span.start : probe.t),
        t: span ? span.start + (span.end - span.start) / 2 : probe.t,
        ...(span ? { span } : {}),
        kind: "point",
        app: { name: probe.app?.name, bundleId: probe.app?.bundleId },
        window: probe.windowTitle,
        text: extractText(probe),
        cropPath: probe.crop?.path,
        mark: probe?.mark,
        ...extractPage(probe),
      });
      continue;
    }

    // The drag interval: measured (`span`) in newer recordings. Older ones
    // reconstruct it, since swallowing the drag freezes the OS cursor at the
    // drag origin and the run of samples on path[0] approximates the gesture
    // (a cursor parked there before pressing looks identical).
    const span: { start: number; end: number } =
      probe.span ?? { start: recoverDragStart(probe, cursors), end: probe.t };

    drafts.push({
      hold: holdAt(span.start),
      // Midpoint of the gesture, not its end: the narration sits there.
      t: span.start + (span.end - span.start) / 2,
      span,
      kind: "region",
      app: { name: probe.app?.name, bundleId: probe.app?.bundleId },
      window: probe.windowTitle,
      text: extractText(probe),
      cropPath: probe.crop?.path,
      mark: probe?.mark,
      ...extractPage(probe),
    });
  }

  // Chronological insertion.
  for (const draft of drafts.sort((a, b) => a.t - b.t)) stack.add(draft);
  return stack;
}

function recoverDragStart(probe: any, cursors: any[]): number {
  const origin = probe.shape.path?.[0] ?? probe.shape.origin;
  let dragStart = probe.t;
  for (let i = cursors.length - 1; i >= 0; i--) {
    const c = cursors[i];
    if (c.t >= probe.t) continue;
    if (probe.t - c.t > 30_000) break;
    if (Math.hypot(c.x - origin.x, c.y - origin.y) < 4) dragStart = c.t;
    else if (dragStart !== probe.t) break;
  }
  return dragStart;
}

function extractPage(probe: any): { page?: ReferentPage } {
  const nonEmpty = (s: unknown): s is string => typeof s === "string" && s.trim().length > 0;
  const els: any[] = probe?.snapshot?.elements ?? [];
  const web = [...els, ...els.flatMap((e) => e?.ancestors ?? [])]
    .find((e) => e?.role === "AXWebArea" && nonEmpty(e.title));
  const headings = els.filter((e) => e?.role === "AXHeading").map((e) => e.title || e.value).filter(nonEmpty);
  const domIds = els.map((e) => e?.domIdentifier).filter(nonEmpty);
  const page: ReferentPage = {
    ...(web ? { title: web.title as string } : {}),
    ...(nonEmpty(probe?.pageURL) ? { url: probe.pageURL as string } : {}),
    ...(nonEmpty(probe?.document) ? { document: probe.document as string } : {}),
    ...(headings.length ? { headings } : {}),
    ...(domIds.length ? { domIds } : {}),
  };
  return Object.keys(page).length ? { page } : {};
}

function extractText(probe: any): { ax: string[]; ocr: string[]; axStart?: string[] } {
  const ax: string[] = (probe?.snapshot?.elements ?? [])
    .map((e: any) => e.value || e.title || e.elementDescription || e.selectedText)
    .filter((t: unknown): t is string => typeof t === "string" && t.trim().length > 0);
  const ocr: string[] = (probe?.crop?.ocr ?? [])
    .map((o: any) => o.text)
    .filter((t: unknown): t is string => typeof t === "string" && t.trim().length > 0);
  // Connector/trace only: the other end of the stroke, read at gesture start.
  const axStart: string[] = (probe?.startSnapshot?.elements ?? [])
    .map((e: any) => e.value || e.title || e.elementDescription || e.selectedText)
    .filter((t: unknown): t is string => typeof t === "string" && t.trim().length > 0);
  return axStart.length ? { ax, ocr, axStart } : { ax, ocr };
}
