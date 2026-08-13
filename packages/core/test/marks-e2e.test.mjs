// PINS THE PIPELINE HALF OF INK-ON-EVIDENCE END TO END.
//
// Tasks 1-6 taught Swift to mint a numbered `mark` on every modifier stroke
// and the Node pipeline (loadSession, then buildPrompt) to turn those into
// `[n]` verb lines. This is the half of Task 7 that needs no app: a
// synthesized `events.jsonl` — one probe per gesture kind, plus a plain
// settle that carries no mark at all — fed through the REAL entry points a
// recorded session goes through. The live half (drawing on an actual screen,
// checking crops on disk) is the user's, done by hand.
//
// The events below are shaped exactly like what the recorder writes: probes
// for the five marks arrive with no paired `candidate` (a drag is explicit,
// and a tap-turned-point is demoted by the recorder itself — see
// packages/alignment/src/referents/session.ts's doc comment), so they take
// the "probe with no candidate" path. The settle is the ordinary case: a
// `candidate` carrying the noise features, paired with its `probe` by time
// (<1000ms) and position (<12px) — see PAIRING_WINDOW_MS / PAIRING_RADIUS_PX
// in the same file.

import { test } from "node:test";
import assert from "node:assert/strict";

import { loadSession } from "../../packages/alignment/dist/src/referents/session.js";
import { buildPrompt } from "../lib/prompt.mjs";

/** Every probe needs a crop that was actually OCR'd — `ocrElapsedMs` present
 *  is what render-brief.mjs's release rule reads as "we looked at this" (see
 *  its `cropWasRead`). Not exercised by this test directly (buildPrompt is
 *  called on loadSession's referents, not through render-brief's release
 *  gate), but a shape any real probe carries, so the marks get it too. */
function crop(path) {
  return {
    path,
    rect: { x: 80, y: 180, width: 40, height: 40 },
    rectFromAX: false,
    ocr: [],
    captureElapsedMs: 1,
    ocrElapsedMs: 1,
    error: null,
  };
}

const app = { name: "Xcode", bundleId: "com.apple.dt.Xcode" };

const events = [
  { type: "sessionStart", t: 0 },
  { type: "holdStart", t: 10, hold: 1 },

  // [1] tap — a point, no candidate (a flick too small to enclose anything is
  // demoted to a point by the recorder and arrives as a bare probe).
  {
    type: "probe",
    t: 110,
    app,
    windowTitle: "AuthView.swift — acme-portal",
    shape: { kind: "point", origin: { x: 100, y: 200 } },
    mark: { kind: "point", number: 1 },
    snapshot: { elements: [{ value: "Sign In" }] },
    crop: crop("/tmp/e2e/h01-r001.png"),
  },

  // [2] lasso — a region.
  {
    type: "probe",
    t: 230,
    app,
    windowTitle: "AuthView.swift — acme-portal",
    shape: {
      kind: "region",
      path: [
        { x: 10, y: 10 },
        { x: 50, y: 10 },
        { x: 50, y: 50 },
        { x: 10, y: 50 },
      ],
      bounds: { x: 10, y: 10, width: 40, height: 40 },
      origin: { x: 10, y: 10 },
    },
    span: { start: 200, end: 240 },
    mark: { kind: "lasso", number: 2 },
    snapshot: { elements: [{ value: "UserList" }] },
    crop: crop("/tmp/e2e/h01-r002.png"),
  },

  // [3] connector — sweeps from one endpoint (startSnapshot) to another
  // (snapshot).
  {
    type: "probe",
    t: 330,
    app,
    windowTitle: "AuthView.swift — acme-portal",
    shape: {
      kind: "region",
      path: [
        { x: 60, y: 60 },
        { x: 160, y: 160 },
      ],
      bounds: { x: 60, y: 60, width: 100, height: 100 },
      origin: { x: 60, y: 60 },
    },
    span: { start: 300, end: 340 },
    mark: { kind: "connector", number: 3 },
    startSnapshot: { resolved: true, elements: [{ value: "fetchUser()" }] },
    snapshot: { elements: [{ value: "OrderList" }] },
    crop: crop("/tmp/e2e/h01-r003.png"),
  },

  // [4] trace — an L drawn through a region.
  {
    type: "probe",
    t: 430,
    app,
    windowTitle: "AuthView.swift — acme-portal",
    shape: {
      kind: "region",
      path: [
        { x: 20, y: 20 },
        { x: 20, y: 60 },
        { x: 60, y: 60 },
      ],
      bounds: { x: 20, y: 20, width: 40, height: 40 },
      origin: { x: 20, y: 20 },
    },
    span: { start: 400, end: 440 },
    mark: { kind: "trace", number: 4 },
    snapshot: { elements: [{ value: "RouteTable" }] },
    crop: crop("/tmp/e2e/h01-r004.png"),
  },

  // [5] emphasis — a scribble over a word.
  {
    type: "probe",
    t: 530,
    app,
    windowTitle: "AuthView.swift — acme-portal",
    shape: {
      kind: "region",
      path: [
        { x: 30, y: 30 },
        { x: 45, y: 35 },
        { x: 30, y: 40 },
      ],
      bounds: { x: 30, y: 30, width: 15, height: 10 },
      origin: { x: 30, y: 30 },
    },
    span: { start: 500, end: 540 },
    mark: { kind: "emphasis", number: 5 },
    snapshot: { elements: [{ value: "TODO" }] },
    crop: crop("/tmp/e2e/h01-r005.png"),
  },

  // A plain settle: candidate + its paired probe, no mark. Probe lands 10ms
  // after the candidate, 2.8px away — inside the 1000ms / 12px pairing
  // window — and carries no crop path, the way an unmarked settle does.
  {
    type: "candidate",
    t: 650,
    app,
    position: { x: 300, y: 300 },
    features: { dwellMs: 250, approachSpeed: 0.1 },
  },
  {
    type: "probe",
    t: 660,
    app,
    windowTitle: "AuthView.swift — acme-portal",
    shape: { kind: "point", origin: { x: 302, y: 298 } },
    snapshot: { elements: [] },
    crop: { path: null, rect: null, rectFromAX: false, ocr: [], captureElapsedMs: 1, ocrElapsedMs: 1, error: null },
  },

  { type: "holdEnd", t: 700, hold: 1 },
  { type: "sessionEnd", t: 710 },
];

test("loadSession yields six referents, five badged 1-5, the settle bare", () => {
  const referents = loadSession(events).all();
  assert.equal(referents.length, 6);

  const marked = referents.filter((r) => r.mark);
  assert.equal(marked.length, 5);
  assert.deepEqual(
    marked.map((r) => r.mark.kind),
    ["point", "lasso", "connector", "trace", "emphasis"],
  );
  assert.deepEqual(
    marked.map((r) => r.mark.number),
    [1, 2, 3, 4, 5],
  );

  const settle = referents.find((r) => !r.mark);
  assert.ok(settle, "the settle referent survived pairing");
  assert.equal(settle.mark, undefined);
  assert.equal(settle.cropPath, null);
});

test("buildPrompt renders the five marks with their verbs and withholds nothing about the settle", () => {
  const referents = loadSession(events).all();

  // `said` is not something loadSession produces — it is bound later, by the
  // aligner, and named onto the referent by render-brief.mjs's `released`
  // mapping (see its doc comment: "said is what makes a screenshot mean
  // something"). buildPrompt only ever reads `r.said`, never `r.utterance`,
  // so this test does the same minimal mapping render-brief does, stubbing
  // it onto two referents rather than wiring up the full aligner.
  const prepared = referents.map((r) => ({ ...r, cropWithheld: null, said: null }));
  const lasso = prepared.find((r) => r.mark?.kind === "lasso");
  lasso.said = "and this list of users here";
  const connector = prepared.find((r) => r.mark?.kind === "connector");
  connector.said = "this feeds that";

  const { text } = buildPrompt({ narration: "look at the login flow", referents: prepared });

  // The badge + verb for each mark kind.
  assert.match(text, /- \[1\] pointed at: \/tmp\/e2e\/h01-r001\.png/);
  assert.match(
    text,
    /- \[2\] circled: \/tmp\/e2e\/h01-r002\.png — while I said "and this list of users here"/,
  );
  assert.match(text, /- \[4\] traced through: \/tmp\/e2e\/h01-r004\.png/);
  assert.match(text, /- \[5\] scribbled over: \/tmp\/e2e\/h01-r005\.png/);

  // The connector names both ends, not just a generic verb.
  assert.match(
    text,
    /- \[3\] swept from "fetchUser\(\)" to "OrderList": \/tmp\/e2e\/h01-r003\.png — while I said "this feeds that"/,
  );

  // Every shot carries a mark, so the heading is the "marked" variant, not
  // the pre-mark "circled" copy.
  assert.match(text, /Screenshots of what I marked \(badge numbers match\):/);

  // The settle contributed no shot line at all: exactly five `- ` bullets,
  // one per mark, none for the settle's null crop path.
  const bullets = text.split("\n").filter((l) => l.startsWith("- "));
  assert.equal(bullets.length, 5);
});
