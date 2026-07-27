import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { ReferentStack } from "../src/stack.js";
import { detectBackReferences } from "../src/backref.js";
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

test('"earlier" prefers a previous visit over the one you are standing in', () => {
  const s = new ReferentStack();
  // First Compass visit — the field actually being referred back to.
  s.add(ref(1000, "Compass", { text: { ax: ["identifier", "CBSE"], ocr: [] } }));
  s.add(ref(5000, "Code", { text: { ax: ["tenantService"], ocr: [] } }));
  // Second Compass visit — recent, and mentions the same word.
  s.add(ref(9000, "Compass", { text: { ax: ["identifier", "Telangana"], ocr: [] } }));

  const back = s.resolveBackReference("that identifier we showed earlier", 10_000);

  assert.equal(
    back.candidates[0]?.referentId,
    "r1",
    "the earlier visit should outrank the one we are currently in",
  );
  assert.match(back.candidates[0]!.why, /earlier visit/);
});

test("exact accessibility text outranks an OCR guess", () => {
  const s = new ReferentStack();
  // Both candidates sit in EARLIER visits, so the visit term cancels out and
  // the only thing separating them is where their text came from. (An earlier
  // version of this test had the AX candidate in the current visit, so it was
  // measuring two signals at once and asserting on the wrong one.)
  s.add(ref(1000, "Compass", { text: { ax: [], ocr: ["identifier"] } }));
  s.add(ref(2000, "Code", { text: { ax: ["identifier"], ocr: [] } }));
  s.add(ref(8000, "Postman")); // where the phrase is spoken

  const back = s.resolveBackReference("that identifier from before", 9000);
  assert.equal(back.candidates[0]?.referentId, "r2");
  assert.match(back.candidates[0]!.why, /\(ax\)/);
});

test("nothing can be referred back to before it existed", () => {
  const s = new ReferentStack();
  s.add(ref(5000, "Compass", { text: { ax: ["identifier"], ocr: [] } }));

  const back = s.resolveBackReference("that identifier earlier", 3000);
  assert.deepEqual(back.candidates, [], "the referent is in the phrase's future");
});

test("a back-reference needs BOTH a distal word and a past marker", () => {
  const say = (text: string) =>
    text.split(" ").map((w, i) => ({ text: w, start: 1000 + i * 250, end: 1200 + i * 250 }));

  assert.equal(
    detectBackReferences(say("expose that key we showed earlier as status")).length,
    1,
    "distal + past marker → back-reference",
  );
  assert.equal(
    detectBackReferences(say("change that field to Telangana")).length,
    0,
    "distal alone is ordinary pointing, not a callback",
  );
  assert.equal(
    detectBackReferences(say("we showed the response body")).length,
    0,
    "a past marker alone is narration, not a reference",
  );
});

test("Hinglish back-references are detected too", () => {
  const say = (text: string) =>
    text.split(" ").map((w, i) => ({ text: w, start: 1000 + i * 250, end: 1200 + i * 250 }));

  const found = detectBackReferences(say("wo jo key pehle dikhaya tha usko expose karo"));
  assert.ok(found.length >= 1, "should detect the Hinglish callback");
});

test("loads the real recorded session into an ordered stack", () => {
  const path = new URL(
    "../../../sessions/20260727-220359/events.jsonl",
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

  assert.equal(all.length, 9, "5 point candidates + 4 lassos");
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

  // The founding-example query, against real captured data.
  const back = stack.resolveBackReference("that identifier we showed earlier", 40_000);
  assert.ok(back.candidates.length > 0, "should shortlist something");
});
