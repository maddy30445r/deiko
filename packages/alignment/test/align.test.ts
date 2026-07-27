import assert from "node:assert/strict";
import { test } from "node:test";

import { align } from "../src/align.js";
import type { Candidate, Word } from "../src/types.js";

/**
 * These encode the design claims, so a later "simplification" that breaks one
 * fails loudly. The real gate is measured on hand-labelled recordings; this
 * suite is what makes those measurements interpretable — if the binder is
 * broken here, a bad score on real data tells you nothing about the mechanic.
 */

let nextId = 0;
function candidate(t: number, over: Partial<Candidate> = {}): Candidate {
  return {
    id: `c${nextId++}`,
    t,
    position: { x: 0, y: 0 },
    features: { dwellMs: 400, approachSpeed: 900 },
    grounded: true,
    kind: "point",
    ...over,
  };
}

function say(text: string, start: number, gap = 250): Word[] {
  return text.split(" ").map((word, i) => ({
    text: word,
    start: start + i * gap,
    end: start + i * gap + 200,
  }));
}

test("a deictic word binds to the pointing act that preceded it", () => {
  const near = candidate(1000);
  const far = candidate(5000);
  const words = say("expose this key", 1400);

  const { bindings } = align([near, far], words);
  const bound = bindings.find((b) => b.reason === "deictic");

  assert.equal(bound?.candidateId, near.id);
  assert.equal(bound?.deicticWord, "this");
  assert.match(bound!.utterance, /expose this key/);
});

test("the window is asymmetric: pointing before speaking is normal, after is not", () => {
  // Cursor stops 1.2s BEFORE the word — within lookBack (1500ms).
  const before = align([candidate(800)], say("this", 2000)).bindings;
  assert.equal(before.length, 1, "a point 1.2s before the word should bind");

  // Cursor stops 1.2s AFTER the word — outside lookAhead (1000ms).
  const after = align([candidate(3200)], say("this", 2000)).bindings;
  assert.equal(
    after.find((b) => b.reason === "deictic"),
    undefined,
    "a point 1.2s after the word should not bind deictically",
  );
});

test("Hinglish points as well as English", () => {
  for (const word of ["yeh", "isko", "wahan", "woh"]) {
    const { bindings } = align([candidate(1000)], say(word, 1300));
    assert.equal(
      bindings[0]?.reason,
      "deictic",
      `"${word}" should be recognised as a pointing word`,
    );
  }
});

test("a settle right after an app switch loses to a clean one", () => {
  const arriving = candidate(1000, {
    features: { dwellMs: 400, approachSpeed: 900, msSinceAppSwitch: 150 },
  });
  const deliberate = candidate(1000, {
    features: { dwellMs: 400, approachSpeed: 900, msSinceAppSwitch: 5000 },
  });

  const { bindings } = align([arriving, deliberate], say("this", 1400));
  assert.equal(
    bindings[0]?.candidateId,
    deliberate.id,
    "the cursor landing after an app switch is arriving, not pointing",
  );
});

test("a settle while the page scrolls underneath loses to a clean one", () => {
  const scrolling = candidate(1000, {
    features: { dwellMs: 400, approachSpeed: 900, msSinceScroll: 100 },
  });
  const still = candidate(1000, {
    features: { dwellMs: 400, approachSpeed: 900, msSinceScroll: 4000 },
  });

  const { bindings } = align([scrolling, still], say("this", 1400));
  assert.equal(bindings[0]?.candidateId, still.id);
});

test("a drawn region outranks a bare settle at the same distance", () => {
  const point = candidate(1000);
  const region = candidate(1000, { kind: "region" });

  const { bindings } = align([point, region], say("this", 1400));
  assert.equal(
    bindings[0]?.candidateId,
    region.id,
    "nobody accidentally draws a loop — a region is the more deliberate gesture",
  );
});

test("a candidate that grounded nothing loses to one that did", () => {
  const empty = candidate(1000, { grounded: false });
  const grounded = candidate(1000, { grounded: true });

  const { bindings } = align([empty, grounded], say("this", 1400));
  assert.equal(bindings[0]?.candidateId, grounded.id);
});

test("confidence falls when two candidates are equally plausible", () => {
  const lone = align([candidate(1000)], say("this", 1400)).bindings[0]!;

  // Two settles a hair apart: genuinely ambiguous, and the review UI must be
  // told so rather than shown a false certainty.
  const ambiguous = align(
    [candidate(1000), candidate(1080)],
    say("this", 1400),
  ).bindings[0]!;

  assert.ok(
    ambiguous.confidence < lone.confidence,
    `ambiguous ${ambiguous.confidence.toFixed(2)} should be under unambiguous ${lone.confidence.toFixed(2)}`,
  );
});

test("silence leaves a candidate unbound rather than inventing a referent", () => {
  const resting = candidate(1000);
  const spoken = candidate(9000);
  const words = say("this one here", 9200);

  const { bindings, unbound } = align([resting, spoken], words);

  assert.deepEqual(unbound, [resting.id], "a settle in silence is a resting hand");
  assert.equal(bindings.length, 1);
});

test("speech overlapping a dwell binds without a deictic word, but weakly", () => {
  const c = candidate(2000, { features: { dwellMs: 800, approachSpeed: 900 } });
  const words = say("the padding is too big", 1500);

  const { bindings } = align([c], words);
  assert.equal(bindings[0]?.reason, "overlap");
  assert.ok(
    bindings[0]!.confidence < 0.6,
    "overlap is real evidence but weaker than an explicit pointing word",
  );
});

test("an utterance never spans a hold boundary", () => {
  // Two holds whose words happen to sit close together on the session clock.
  // Releasing the hotkey ended the first sentence; they must not merge.
  const words: Word[] = [
    ...say("expose this field", 1000).map((w) => ({ ...w, hold: 1 })),
    ...say("refactor karo", 1900).map((w) => ({ ...w, hold: 2 })),
  ];

  const { bindings } = align([candidate(800)], words);
  const bound = bindings.find((b) => b.reason === "deictic")!;

  assert.match(bound.utterance, /expose this field/);
  assert.doesNotMatch(
    bound.utterance,
    /refactor/,
    "words from the next hold must not be pulled into this utterance",
  );
});

test("two deictic words claim two different candidates", () => {
  const first = candidate(1000);
  const second = candidate(4000);
  const words = [...say("expose this field", 1300), ...say("in yeh response", 4300)];

  const { bindings } = align([first, second], words);
  const deictic = bindings.filter((b) => b.reason === "deictic");

  assert.equal(deictic.length, 2);
  assert.notEqual(deictic[0]!.candidateId, deictic[1]!.candidateId);
});
