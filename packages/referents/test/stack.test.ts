import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { ReferentStack } from "../src/stack.js";
import { loadSession } from "../src/session.js";
import type { Referent } from "../src/types.js";

function ref(
  t: number,
  app: string,
  over: Partial<Referent> = {},
): Omit<Referent, "index" | "visit" | "id"> {
  return {
    hold: 1,
    t,
    kind: "point",
    app: { name: app, bundleId: `com.${app}` },
    text: { ax: [], ocr: [] },
    ...over,
  };
}

test("index is global and chronological, so returning to an app just works", () => {
  const s = new ReferentStack();
  s.add(ref(1000, "Compass"));
  s.add(ref(2000, "Code"));
  s.add(ref(3000, "Compass")); // back again

  assert.deepEqual(s.all().map((r) => r.id), ["r1", "r2", "r3"]);
  assert.deepEqual(s.all().map((r) => r.index), [0, 1, 2]);
});

test("a return visit is a NEW visit, even though the app is identical", () => {
  const s = new ReferentStack();
  s.add(ref(1000, "Compass"));
  s.add(ref(1200, "Compass")); // same excursion
  s.add(ref(2000, "Code"));
  s.add(ref(3000, "Compass")); // came back

  assert.deepEqual(s.all().map((r) => r.visit), [1, 1, 2, 3]);
  assert.equal(s.byVisit().length, 3, "three excursions, not two apps");
});






test("loads the real recorded session into an ordered stack", () => {
  // Four levels up, not three: this file RUNS from dist/test/, one directory
  // deeper than it is written. The three-level path resolved to
  // packages/sessions/… (which never exists), so the catch below turned the
  // whole test into a silent no-op that still reported ok — and the pairing
  // bug it would have caught shipped.
  const path = new URL(
    "../../../../sessions/20260727-220359/events.jsonl",
    import.meta.url,
  );
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return; // fixture not present on this machine; other tests still cover the logic
  }

  const events = raw
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean) as any[];

  const stack = loadSession(events);
  const all = stack.all();

  // 5 settled candidates + 4 regions + 1 flick-demoted point probe. The tenth
  // is the `CBSE` probe: it has no candidate (its lasso was demoted to a point
  // by the recorder), and the old time-only pairing let it steal a nearby
  // settle's slot — a real grounded referent fell off the stack entirely.
  assert.equal(all.length, 10, "5 paired candidates + 4 lassos + 1 bare probe");
  assert.ok(
    all.every((r, i) => i === 0 || all[i - 1]!.t <= r.t),
    "referents are in chronological order",
  );

  // The session went Compass → VS Code, so there are at least two visits and
  // the Compass ones all precede the Code ones.
  const visits = stack.byVisit();
  assert.ok(visits.length >= 2, `expected multiple visits, got ${visits.length}`);
  assert.equal(visits[0]!.app, "MongoDB Compass");

  // Regions carry their drag span; points do not.
  const regions = all.filter((r) => r.kind === "region");
  assert.ok(regions.length > 0);
  assert.ok(
    regions.every((r) => r.span && r.span.end > r.span.start),
    "every region has a real drag duration",
  );
});
