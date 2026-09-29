import assert from "node:assert/strict";
import { test } from "node:test";

import { align } from "../src/align.js";
import type { Candidate, Word } from "../src/types.js";

/**
 * These encode the design claims, so a later "simplification" that breaks one
 * fails loudly.
 */

let nextId = 0;
function candidate(t: number, over: Partial<Candidate> = {}): Candidate {
  return {
    id: `c${nextId++}`,
    t,
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

test("the window is bounded on both sides, and speak-then-point is allowed", () => {
  // Cursor stops 1.2s before the word, within lookBack (1500ms).
  const before = align([candidate(800)], say("this", 2000)).bindings;
  assert.equal(before.length, 1, "a point 1.2s before the word should bind");

  // Cursor stops 1.4s after the word: speaking first and pointing later is
  // common. Within lookAhead (2000ms).
  const speakThenPoint = align([candidate(3400)], say("this", 2000)).bindings;
  assert.equal(
    speakThenPoint.find((b) => b.reason === "deictic")?.deicticWord,
    "this",
    "speaking first and pointing 1.4s later must bind — observed in real data",
  );

  // Cursor stops 2.5s after the word, outside lookAhead.
  const after = align([candidate(4500)], say("this", 2000)).bindings;
  assert.equal(
    after.find((b) => b.reason === "deictic"),
    undefined,
    "a point 2.5s after the word should not bind deictically",
  );
});

test("Hinglish points as well as English", () => {
  // Oblique forms and ASR spellings the lexicon must cover.
  for (const word of ["yeh", "isko", "wahan", "woh", "ismein", "Issko", "usmein"]) {
    const { bindings } = align([candidate(1000)], say(word, 1300));
    assert.equal(
      bindings[0]?.reason,
      "deictic",
      `"${word}" should be recognised as a pointing word`,
    );
  }
});

test("Devanagari points too — the script depends on the recogniser, not the speaker", () => {
  // Devanagari forms as a code-mixing recogniser returns them.
  for (const word of ["यह", "इसमें", "उसको", "यहां"]) {
    const { bindings } = align([candidate(1000)], say(word, 1300));
    assert.equal(
      bindings[0]?.reason,
      "deictic",
      `"${word}" should be recognised as a pointing word`,
    );
  }
});

test("punctuation and case never hide a pointing word", () => {
  const { bindings } = align([candidate(1000)], say("This,", 1300));
  assert.equal(bindings[0]?.reason, "deictic");
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
  // Two holds whose words sit close together on the session clock: releasing
  // the hotkey ended the first sentence, so they must not merge.
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

// `needsReview` is not `confidence < 0.5`; these tests pin the distinction.

test("an overlap binding is never flagged for review", () => {
  // 0.45 with at most a x1.1 and a x1.05 lift cannot reach 0.5, so a threshold
  // test would mark every overlap binding. Overlap being weaker is a fact about
  // the class, not an alarm on each row.
  const c = candidate(1000, { features: { dwellMs: 400, approachSpeed: 0 } });
  const { bindings } = align([c], say("the padding looks wrong", 800));
  const bound = bindings.find((b) => b.reason === "overlap")!;

  assert.ok(bound.confidence < 0.5, "precondition: overlap scores below the threshold");
  assert.equal(bound.needsReview, false);
});

test("a deictic binding the aligner was torn over IS flagged", () => {
  // Two candidates almost equidistant from one deictic word: the margin over
  // the runner-up collapses, which is exactly the ambiguity worth surfacing.
  const a = candidate(1000);
  const b = candidate(1100);
  const { bindings } = align([a, b], say("expose this key", 1400));
  const bound = bindings.find((x) => x.reason === "deictic")!;

  assert.ok(bound.confidence < 0.5, `expected a weak binding, got ${bound.confidence}`);
  assert.equal(bound.needsReview, true);
});

test("a confident deictic binding is not flagged", () => {
  const only = candidate(1200);
  const { bindings } = align([only], say("expose this key", 1400));
  const bound = bindings.find((b) => b.reason === "deictic")!;

  assert.ok(bound.confidence >= 0.5, `expected a strong binding, got ${bound.confidence}`);
  assert.equal(bound.needsReview, false);
});

test("timing provenance is carried through, and absent when unknown", () => {
  // Reported, never scored (see `anchoredTiming` in types.ts). A transcript
  // written before `anchored` existed must leave the field absent rather than
  // claim the timing was interpolated.
  const words = say("expose this key", 1400);
  const withAnchor = words.map((w, i) => (i === 1 ? { ...w, anchored: true } : w));

  const anchored = align([candidate(1200)], withAnchor).bindings
    .find((b) => b.reason === "deictic")!;
  assert.equal(anchored.anchoredTiming, true);

  const unknown = align([candidate(1200)], words).bindings
    .find((b) => b.reason === "deictic")!;
  assert.ok(
    !("anchoredTiming" in unknown),
    "an unknown provenance must be absent, not false",
  );
});
