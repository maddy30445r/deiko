// ─────────────────────────────────────────────────────────────────────────────
// THE CONTRACT BETWEEN TWO LANGUAGES THAT NEVER CALL EACH OTHER.
//
// `PipelineFailure.classify` (Swift) decides what the orb says when a stage
// fails, and it decides it by matching substrings that the Node scripts print
// to stderr. Nothing links the two: reword one `console.error` and the Swift
// side silently stops recognising it, the helpful sentence becomes the generic
// "<stage> failed", and every test on both sides still passes.
//
// The same exposure exists for the two withhold reasons `render-brief.mjs`
// writes into `brief.json`, which `ReviewWindow` branches on to decide whether
// to tell somebody a credential was visible on their screen.
//
// So this reads both sides as TEXT and checks the strings still meet. It needs
// no Swift toolchain, which is the point — it runs in `npm test`, where the
// person rewording a log line already is.
//
// The same approach as `docs.test.mjs`: source as data, not as code.
// ─────────────────────────────────────────────────────────────────────────────

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "..", "..");
const read = (p) => readFileSync(join(root, p), "utf8");

const swift = read("apps/capture/Sources/FoveaHandoff/PipelineFailure.swift");
const scripts = [
  "scripts/transcribe.mjs",
  "scripts/render-brief.mjs",
  "scripts/summarize.mjs",
  "scripts/lib/redact.mjs",
  "scripts/lib/prompt.mjs",
].map(read).join("\n");

/// Every literal the Swift taxonomy matches on, and where it comes from.
///
/// `text.contains("…")` is the only form `classify` uses, so the list is
/// extracted rather than hand-maintained — a new branch is covered the day it
/// is written, without anybody remembering to add it here.
const matched = [...swift.matchAll(/text\.contains\("([^"]+)"\)/g)].map((m) => m[1]);

test("the Swift failure taxonomy matches on strings that still exist", () => {
  assert.ok(matched.length >= 10, `expected a real taxonomy, found ${matched.length} branches`);

  // Not printed literally by any script, for three different reasons — and
  // the third category is a finding, not an exemption.
  const notOurs = new Set([
    // 1. Written by the Swift side itself.
    "timed out after",          // BriefPipeline's watchdog
    "could not find node",      // BriefPipelineError.nodeNotFound's description

    // 2. Arrives from somewhere else at runtime, so no source contains it.
    //    `transcribe.mjs` throws `Sarvam ${status}: …`, and the provider's own
    //    body supplies the rest.
    "sarvam 401",
    "sarvam 403",
    "sarvam 429",
    "quota",                    // Sarvam's response body
    "rate limit",               // Sarvam's response body
    "fetch failed",             // undici
    "enotfound",                // node:net
    "econnrefused",
    "network is unreachable",
    "etimedout",
    "node: command not found",  // the shell

    // 3. ALREADY UNREACHABLE. Nothing prints these any more: a missing Sarvam
    //    key is no longer an error at all, because `selectTranscriber` falls
    //    through to the relay and then to on-device words. The `.noAPIKey`
    //    branch they feed — "the commonest first-run failure", per its own
    //    comment — cannot fire. Listed rather than deleted because the fix is
    //    a judgement call about the taxonomy, not about this test; if the
    //    three-tier fallback is here to stay, so is the deletion.
    "sarvam_api_key is not set",
    "sarvam_api_key is missing",
  ]);

  const haystack = scripts.toLowerCase();
  const missing = matched
    .filter((s) => !notOurs.has(s))
    .filter((s) => !haystack.includes(s.toLowerCase()));

  assert.deepEqual(
    missing,
    [],
    "these strings are matched by PipelineFailure.classify but no script prints them any more — "
      + "the orb will fall back to a generic message for those failures",
  );
});

test("the Sarvam status prefix the taxonomy relies on is still constructed", () => {
  // `classify` matches "sarvam 401" and friends, which no source contains —
  // `transcribe.mjs` builds them from the status at runtime. So the thing to
  // pin is the template, because rewording THAT is what would break them all
  // at once, silently.
  assert.match(
    read("scripts/transcribe.mjs"),
    /`Sarvam \$\{response\.status\}/,
    "the taxonomy matches `sarvam <status>` — this template is where that shape comes from",
  );
});

test("the watchdog's timeout marker is what the Swift side looks for", () => {
  // Both halves are Swift, but they live in different targets and only meet
  // through this string: BriefPipeline writes it, FoveaHandoff classifies it.
  const pipeline = read("apps/capture/Sources/FoveaCapture/BriefPipeline.swift");
  assert.ok(
    pipeline.includes("timed out after"),
    "BriefPipeline must write the marker PipelineFailure matches on",
  );
  assert.ok(matched.includes("timed out after"));
});

test("the two withhold reasons are the ones the review window branches on", () => {
  // `ReviewWindow.withheldSentence` picks between "a credential was visible"
  // and "couldn't read them to check" by looking for these words. Reword the
  // renderer and a first-run user gets told a credential was on their screen.
  const renderer = read("scripts/render-brief.mjs");
  const review = read("apps/capture/Sources/FoveaCapture/ReviewWindow.swift");

  assert.match(renderer, /credential visible in this capture/);
  assert.match(renderer, /never OCR'd/);

  assert.ok(
    review.includes('$0.contains("credential")'),
    "the review window must still recognise the credential reason",
  );
  assert.ok(
    review.includes('$0.contains("OCR")'),
    "the review window must still recognise the unverified reason",
  );
});

test("the degraded flag the review window reads is the one the renderer writes", () => {
  const renderer = read("scripts/render-brief.mjs");
  const pipeline = read("apps/capture/Sources/FoveaCapture/BriefPipeline.swift");

  assert.match(renderer, /^\s*degraded,$/m, "render-brief must put `degraded` in the summary");
  assert.match(pipeline, /var degraded: Bool\?/, "BriefSummary must decode it, and optionally");
});
