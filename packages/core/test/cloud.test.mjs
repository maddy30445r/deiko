import { test } from "node:test";
import assert from "node:assert/strict";

import { refusalReason, REFUSAL_IS_FINAL, degradedReason, withOneRetry } from "../src/lib/cloud.mjs";

// Fixture bodies are copied from services/relay/src/quota.mjs and relay.mjs.
// The mapping is a string contract between two deployables, so rewording a
// body there should fail here.
const TRIAL = JSON.stringify({ error: "the free trial is used up — transcription continues on your Mac" });
const MONTHLY = JSON.stringify({ error: "this month's fair-use limit is used up" });
const CEILING = JSON.stringify({ error: "the service is at its daily ceiling — try again tomorrow" });
const RATE = JSON.stringify({ error: "rate limit exceeded" });
const UNAVAILABLE = JSON.stringify({ error: "usage service unavailable: timeout" });

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
  // 401/403 cannot heal by being resent. Treating them as transient would
  // upload every remaining chunk of a revoked key's session to be rejected.
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
  // 413 (body too large) says nothing about the bearer, so it stays retryable.
  assert.equal(refusalReason(413, ""), "unavailable");
});

test("the body is matched case-insensitively", () => {
  assert.equal(refusalReason(429, "THIS MONTH'S FAIR-USE LIMIT IS USED UP"), "monthly");
});

test("only facts about the account or the day are final", () => {
  assert.ok(REFUSAL_IS_FINAL.has("trial"));
  assert.ok(REFUSAL_IS_FINAL.has("monthly"));
  assert.ok(REFUSAL_IS_FINAL.has("ceiling"));
  // A twelve-minute session is ~29 chunks against a 30/min limiter, so a burst
  // 429 must not silence the chunks after it.
  assert.ok(!REFUSAL_IS_FINAL.has("unavailable"));
});

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
  // The opposite degradation: the on-device clock failed and the cloud text
  // survived. Sharing the others' label would state the reverse.
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

test("a build with no relay is a degradation, and a different one from a spent trial", () => {
  // Transcriber "on-device", nothing uploaded, nothing refused: no relay was
  // configured, so `selectTranscriber` never had one to call. This must not
  // read as `degraded: false`.
  const noRelay = { cloud: { transcriber: "on-device", uploaded: 0, refused: null, failedChunks: 0 } };
  assert.equal(degradedReason(noRelay), "on-device");

  // A spent trial is normal and its answer is a purchase; a missing relay is a
  // misconfiguration and its answer is a rebuild. They must stay distinct.
  assert.equal(
    degradedReason({ cloud: { transcriber: "deiko", uploaded: 3, refused: "trial", failedChunks: 0 } }),
    "trial",
  );
  // A relay that was reached and then failed keeps its own name.
  assert.equal(
    degradedReason({ cloud: { transcriber: "deiko", uploaded: 2, refused: null, failedChunks: 2 } }),
    "unavailable",
  );
});

test("a reached relay and a user's own key are not degraded", () => {
  assert.equal(
    degradedReason({ cloud: { transcriber: "deiko", uploaded: 5, refused: null, failedChunks: 0 } }),
    null,
  );
  // A BYO key names itself, which is what makes "on-device" unambiguous above.
  assert.equal(
    degradedReason({ cloud: { transcriber: "groq:whisper-large-v3", uploaded: 4, refused: null, failedChunks: 0 } }),
    null,
  );
});

test("on-device outranks timing", () => {
  // A wholly-local transcript is the larger claim; timing's "what you said is
  // intact" would be the wrong reassurance when no cloud words existed.
  assert.equal(
    degradedReason({
      cloud: { transcriber: "on-device", uploaded: 0, refused: null, failedChunks: 0 },
      degradedHolds: [1, 2],
    }),
    "on-device",
  );
});

test("a transcript written before `cloud` existed still reads", () => {
  // Sessions written by older builds have neither key.
  assert.equal(degradedReason({ degradedHolds: undefined }), null);
});

test("a chunk gets one retry, told which try is its last", async () => {
  const tries = [];
  const flaky = async (last) => { tries.push(last); if (!last) throw new Error("dropped"); return "words"; };
  assert.equal(await withOneRetry(flaky, 1), "words");
  assert.deepEqual(tries, [false, true]);

  const fine = [];
  assert.equal(await withOneRetry(async (last) => { fine.push(last); return "ok"; }, 1), "ok");
  assert.deepEqual(fine, [false], "a chunk that lands is sent once");

  await assert.rejects(withOneRetry(async () => { throw new Error("down"); }, 1), /down/, "twice failed is failed");
});
