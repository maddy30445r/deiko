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
 * straight to a referent.
 */

interface RawEvent {
  type: string;
  t: number;
  [key: string]: unknown;
}

const PAIRING_WINDOW_MS = 1000;

export function loadSession(events: RawEvent[]): ReferentStack {
  const stack = new ReferentStack();
  const probes = events.filter((e) => e.type === "probe") as any[];
  const candidates = events.filter((e) => e.type === "candidate") as any[];
  const cursors = events.filter((e) => e.type === "cursor") as any[];

  const usedProbes = new Set<number>();
  const drafts: Array<Omit<Referent, "index" | "visit" | "id">> = [];

  // ── points: candidate + its probe ────────────────────────────────────────
  for (const candidate of candidates) {
    let bestIndex = -1;
    let bestGap = Infinity;
    probes.forEach((p, i) => {
      if (usedProbes.has(i) || p.shape.kind !== "point") return;
      const gap = Math.abs(p.t - candidate.t);
      if (gap < bestGap && gap < PAIRING_WINDOW_MS) {
        bestGap = gap;
        bestIndex = i;
      }
    });
    const probe = bestIndex >= 0 ? (usedProbes.add(bestIndex), probes[bestIndex]) : undefined;

    drafts.push({
      hold: candidate.hold ?? 1,
      t: candidate.t,
      kind: "point",
      app: {
        name: candidate.app?.name ?? probe?.app?.name,
        bundleId: candidate.app?.bundleId ?? probe?.app?.bundleId,
      },
      window: probe?.windowTitle,
      text: extractText(probe),
      cropPath: probe?.crop?.path,
      // Carried through verbatim: these are the recorder's honest notes on how
      // suspicious the settle was, and the aligner is what decides.
      capture: candidate.features,
    });
  }

  // ── regions: probe only, timed across the whole drag ─────────────────────
  for (const probe of probes) {
    if (probe.shape.kind !== "region") continue;

    // A region's probe is stamped at mouse-UP, but users narrate while DRAWING
    // — one measured lasso ran 6 seconds with the key phrase spoken mid-way.
    // The drag's start is recoverable because swallowing the drag events
    // freezes the OS cursor at the drag origin: the run of cursor samples
    // sitting exactly on path[0] IS the gesture.
    const origin = probe.shape.path?.[0] ?? probe.shape.origin;
    let dragStart = probe.t;
    for (let i = cursors.length - 1; i >= 0; i--) {
      const c = cursors[i];
      if (c.t >= probe.t) continue;
      if (probe.t - c.t > 30_000) break;
      if (Math.hypot(c.x - origin.x, c.y - origin.y) < 4) dragStart = c.t;
      else if (dragStart !== probe.t) break;
    }

    drafts.push({
      hold: probe.hold ?? 1,
      // Midpoint of the gesture, not its end — that is where the narration sits.
      t: dragStart + (probe.t - dragStart) / 2,
      span: { start: dragStart, end: probe.t },
      kind: "region",
      app: { name: probe.app?.name, bundleId: probe.app?.bundleId },
      window: probe.windowTitle,
      text: extractText(probe),
      cropPath: probe.crop?.path,
    });
  }

  // Chronological insertion, so `index` and `visit` mean what they claim.
  for (const draft of drafts.sort((a, b) => a.t - b.t)) stack.add(draft);
  return stack;
}

function extractText(probe: any): { ax: string[]; ocr: string[] } {
  const ax: string[] = (probe?.snapshot?.elements ?? [])
    .map((e: any) => e.value || e.title || e.elementDescription || e.selectedText)
    .filter((t: unknown): t is string => typeof t === "string" && t.trim().length > 0);
  const ocr: string[] = (probe?.crop?.ocr ?? [])
    .map((o: any) => o.text)
    .filter((t: unknown): t is string => typeof t === "string" && t.trim().length > 0);
  return { ax, ocr };
}
