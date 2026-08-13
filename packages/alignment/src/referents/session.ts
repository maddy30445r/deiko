import { ReferentStack } from "./stack.js";
import type { Referent } from "./types.js";

/**
 * Build a stack from a recorded session's `events.jsonl`.
 *
 * The recorder emits a pointing act as TWO events seen from different angles:
 * a `candidate` carrying the noise features (dwell, approach speed, how long
 * since you switched apps), and a `probe` carrying what was actually grounded
 * (accessibility elements, crop, OCR). They are separate because grounding is
 * resolved asynchronously — a probe takes a few hundred milliseconds and must
 * not block the 60Hz sampler — so the probe lands slightly after its candidate.
 * Re-pairing them is this loader's main job.
 *
 * Regions have no candidate at all: a drag is explicit, so the recorder skips
 * straight to a referent. Nor does a point that BEGAN as a drag — a flick too
 * small to enclose anything is demoted to a point by the recorder, and it too
 * arrives as a bare probe.
 */

interface RawEvent {
  type: string;
  t: number;
  [key: string]: unknown;
}

const PAIRING_WINDOW_MS = 1000;

/** A probe must also LAND where its candidate settled. Time alone once paired
 *  a settle with a degenerate-lasso probe 18px away that happened to commit a
 *  millisecond closer, and the settle's own probe fell off the stack. */
const PAIRING_RADIUS_PX = 12;

export function loadSession(events: RawEvent[]): ReferentStack {
  const stack = new ReferentStack();
  const probes = events.filter((e) => e.type === "probe") as any[];
  const candidates = events.filter((e) => e.type === "candidate") as any[];
  const cursors = events.filter((e) => e.type === "cursor") as any[];

  // Holds, from the wire. `holdStart`/`holdEnd` carry the hold number and its
  // time range; a referent's hold is the range its `t` falls in. Candidates and
  // probes deliberately do NOT carry a hold field themselves — the events that
  // define the boundary are already in the file.
  const holdStarts = new Map<number, number>();
  for (const e of events as any[]) {
    if (e.hold == null) continue;
    if (e.type === "holdStart") holdStarts.set(e.hold, e.t);
  }
  const holdAt = (t: number): number => {
    for (const [hold, start] of holdStarts) {
      // A probe resolves asynchronously, so it can land after its hold's end —
      // membership is "started within", closed by the NEXT hold's start.
      const nextStart = holdStarts.get(hold + 1) ?? Infinity;
      if (t >= start && t < nextStart) return hold;
    }
    return 1;
  };

  const usedProbes = new Set<number>();
  const drafts: Array<Omit<Referent, "id">> = [];

  // ── points: candidate + its probe ────────────────────────────────────────
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
      // Carried through verbatim: these are the recorder's honest notes on how
      // suspicious the settle was, and the aligner is what decides.
      capture: candidate.features,
    });
  }

  // ── probes with no candidate: regions, and demoted-lasso points ──────────
  for (let i = 0; i < probes.length; i++) {
    const probe = probes[i];

    if (probe.shape.kind !== "region") {
      if (usedProbes.has(i)) continue;
      // A flick demoted to a point: real referent — it grounded something and
      // has a crop — just no candidate and no settle features. It used to be
      // silently dropped, which lost h01-r005 of the reference session.
      drafts.push({
        hold: holdAt(probe.t),
        t: probe.t,
        kind: "point",
        app: { name: probe.app?.name, bundleId: probe.app?.bundleId },
        window: probe.windowTitle,
        text: extractText(probe),
        cropPath: probe.crop?.path,
        mark: probe?.mark,
      });
      continue;
    }

    // The drag interval. New recordings carry it measured (`span`), because
    // the recorder saw dragBegan. Older ones fall back to reconstruction:
    // swallowing the drag freezes the OS cursor at the drag origin, so the run
    // of samples sitting on path[0] approximates the gesture — approximates,
    // because a cursor parked there BEFORE pressing looks identical, which is
    // exactly why the recorder now just says so.
    const span: { start: number; end: number } =
      probe.span ?? { start: recoverDragStart(probe, cursors), end: probe.t };

    drafts.push({
      hold: holdAt(span.start),
      // Midpoint of the gesture, not its end — that is where the narration sits.
      t: span.start + (span.end - span.start) / 2,
      span,
      kind: "region",
      app: { name: probe.app?.name, bundleId: probe.app?.bundleId },
      window: probe.windowTitle,
      text: extractText(probe),
      cropPath: probe.crop?.path,
      mark: probe?.mark,
    });
  }

  // Chronological insertion, so `index` and `visit` mean what they claim.
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

function extractText(probe: any): { ax: string[]; ocr: string[]; axStart?: string[] } {
  const ax: string[] = (probe?.snapshot?.elements ?? [])
    .map((e: any) => e.value || e.title || e.elementDescription || e.selectedText)
    .filter((t: unknown): t is string => typeof t === "string" && t.trim().length > 0);
  const ocr: string[] = (probe?.crop?.ocr ?? [])
    .map((o: any) => o.text)
    .filter((t: unknown): t is string => typeof t === "string" && t.trim().length > 0);
  // Connector/trace only: the OTHER end of the stroke, read at gesture start.
  const axStart: string[] = (probe?.startSnapshot?.elements ?? [])
    .map((e: any) => e.value || e.title || e.elementDescription || e.selectedText)
    .filter((t: unknown): t is string => typeof t === "string" && t.trim().length > 0);
  return axStart.length ? { ax, ocr, axStart } : { ax, ocr };
}
