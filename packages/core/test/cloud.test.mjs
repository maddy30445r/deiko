import { test } from "node:test";
import assert from "node:assert/strict";

import { refusalReason, REFUSAL_IS_FINAL, degradedReason } from "../lib/cloud.mjs";

// The bodies below are the relay's own, copied from services/relay/quota.mjs
// and relay.mjs. If somebody rewords them there, these fixtures are what fails
// — which is the point: the mapping is a string contract between two
// deployables that never import each other.
const TRIAL = JSON.stringify({ error: "the free trial is used up — transcription continues on your Mac" });
const MONTHLY = JSON.stringify({ error: "this month's fair-use limit is used up" });
const CEILING = JSON.stringify({ error: "the service is at its daily ceiling — try again tomorrow" });
const RATE = JSON.stringify({ error: "rate limit exceeded" });
const UNAVAILABLE = JSON.stringify({ error: "usage service unavailable: timeout" });

// ── refusalReason ───────────────────────────────────────────────────────────

test("402 is the free trial, whatever the body says", () => {
  assert.equal(refusalReason(402, TRIAL), "trial");
  assert.equal(refusalReason(402, ""), "trial");
});

test("the two 429s that differ only by their body are told apart", () => {
  assert.equal(refusalReason(429, MONTHLY), "monthly");
  assert.equal(refusalReason(429, CEILING), "ceiling");
});

test("the in-memory limiter's 429 is transient, not a fact about the plan", () => {
  assert.equal(refusalReason(429, RATE), "unavailable");
});

test("a bearer the relay will not accept is final, not retried", () => {
  // 401/403 cannot heal by being sent again. Left in the transient bucket, a
  // revoked key uploaded every remaining chunk of the session to be rejected
  // one at a time — minutes of somebody's audio sent to be refused.
  assert.equal(refusalReason(401, ""), "rejected");
  assert.equal(refusalReason(403, JSON.stringify({ error: "token revoked" })), "rejected");
  assert.ok(REFUSAL_IS_FINAL.has("rejected"));
});

test("503 and a request that never landed are the same answer", () => {
  assert.equal(refusalReason(503, UNAVAILABLE), "unavailable");
  assert.equal(refusalReason(0), "unavailable");
});

test("a success is not a refusal", () => {
  assert.equal(refusalReason(200, "{}"), null);
});

test("an unexpected 4xx still degrades rather than reading as success", () => {
  // 413 (body too large) means no words came back, but it is not a statement
  // about the bearer, so it stays retryable.
  assert.equal(refusalReason(413, ""), "unavailable");
});

test("the body is matched case-insensitively", () => {
  assert.equal(refusalReason(429, "THIS MONTH'S FAIR-USE LIMIT IS USED UP"), "monthly");
});

// ── which refusals end the session's uploads ────────────────────────────────

test("only facts about the account or the day are final", () => {
  assert.ok(REFUSAL_IS_FINAL.has("trial"));
  assert.ok(REFUSAL_IS_FINAL.has("monthly"));
  assert.ok(REFUSAL_IS_FINAL.has("ceiling"));
  // A twelve-minute session is ~29 chunks against a 30/min limiter, so a burst
  // 429 partway through must not silence every chunk after it.
  assert.ok(!REFUSAL_IS_FINAL.has("unavailable"));
});

// ── degradedReason: what the window ends up saying ──────────────────────────

test("a refusal outranks everything else", () => {
  assert.equal(
    degradedReason({ cloud: { refused: "trial", failedChunks: 3 }, degradedHolds: [1] }),
    "trial",
  );
});

test("failed chunks with no refusal read as unavailable", () => {
  assert.equal(degradedReason({ cloud: { refused: null, failedChunks: 2 } }), "unavailable");
});

test("degradedHolds is its own reason, not 'transcribed on your Mac'", () => {
  // The opposite degradation: the on-device CLOCK failed and the cloud text is
  // what survived. Labelling it with the others would state the reverse of
  // what happened.
  assert.equal(
    degradedReason({ cloud: { refused: null, failedChunks: 0 }, degradedHolds: [2] }),
    "timing",
  );
});

test("a clean session has no reason at all", () => {
  assert.equal(degradedReason({ cloud: { refused: null, failedChunks: 0 }, degradedHolds: [] }), null);
  assert.equal(degradedReason({}), null);
  assert.equal(degradedReason(), null);
});

test("a transcript written before `cloud` existed still reads", () => {
  // Sessions on disk from an older build have neither key.
  assert.equal(degradedReason({ degradedHolds: undefined }), null);
});
