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

const swift = read("apps/capture/Sources/DeikoHandoff/PipelineFailure.swift");
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
    //    `transcribe.mjs` throws `Groq ${status}: …`, and the provider's own
    //    body supplies the rest. The `sarvam` spellings stay matched because a
    //    session recorded before the switch can be re-rendered after it, and
    //    its cached failure text still names the old vendor.
    "groq 401",
    "groq 403",
    "groq 429",
    "sarvam 401",
    "sarvam 403",
    "sarvam 429",
    "quota",                    // the provider's response body
    "rate limit",               // the provider's response body
    "fetch failed",             // undici
    "enotfound",                // node:net
    "econnrefused",
    "network is unreachable",
    "etimedout",
    "node: command not found",  // the shell

    //    The relay's own refusals. `transcribe.mjs` throws
    //    `Deiko relay ${status}: ${body}`, and the body is written by
    //    services/relay/{quota,relay}.mjs — a different deployable, which is
    //    why nothing under scripts/ contains them. The status-and-body →
    //    reason mapping lives in scripts/lib/cloud.mjs and is tested in
    //    cloud.test.mjs; these are what the Swift taxonomy matches on when one
    //    of them fails a stage outright rather than merely degrading it.
    "fair-use limit",            // quota.mjs:200 — a Pro month is spent
    "daily ceiling",             // quota.mjs:190 — the SERVICE is spent, not the user
    "usage service unavailable", // relay.mjs:223/249 — metering down, failing closed
  ]);

  // Category 3 held "sarvam_api_key is not set" / "is missing", marked ALREADY
  // UNREACHABLE: a keyless install transcribes via the relay and then
  // on-device, so the `.noAPIKey` branch could not fire. This test said the fix
  // was a judgement call about the taxonomy rather than about the test. That
  // call has now been made — the branch and its enum case are deleted — so the
  // exemption goes with them. If either string reappears in `classify`, this
  // test fails again, which is right: nothing prints them.

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

test("the provider status prefix the taxonomy relies on is still constructed", () => {
  // `classify` matches "groq 401" and friends, which no source contains —
  // `transcribe.mjs` builds them from the status at runtime. So the thing to
  // pin is the template, because rewording THAT is what would break them all
  // at once, silently.
  assert.match(
    read("scripts/transcribe.mjs"),
    /`Groq \$\{response\.status\}/,
    "the taxonomy matches `groq <status>` — this template is where that shape comes from",
  );
});

test("the watchdog's timeout marker is what the Swift side looks for", () => {
  // Both halves are Swift, but they live in different targets and only meet
  // through this string: BriefPipeline writes it, DeikoHandoff classifies it.
  const pipeline = read("apps/capture/Sources/DeikoCapture/BriefPipeline.swift");
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
  const review = read("apps/capture/Sources/DeikoCapture/ReviewWindow.swift");

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
  const pipeline = read("apps/capture/Sources/DeikoCapture/BriefPipeline.swift");

  assert.match(renderer, /^\s*degraded,$/m, "render-brief must put `degraded` in the summary");
  assert.match(pipeline, /var degraded: Bool\?/, "BriefSummary must decode it, and optionally");
});

test("every summary key the review window reads is one the renderer writes", () => {
  // Same contract as `degraded` above, for the keys added when the window
  // learned to explain itself. Each pair is a JSON key crossing from a Node
  // script into a Swift `Codable` with no shared type between them, so the
  // only thing holding them together is this test.
  const renderer = read("scripts/render-brief.mjs");
  const pipeline = read("apps/capture/Sources/DeikoCapture/BriefPipeline.swift");

  for (const [key, decl] of [
    ["degradedReason", /var degradedReason: String\?/],
    ["transcriber", /var transcriber: String\?/],
    ["labelsDropped", /var labelsDropped: Int\?/],
    ["cropsRemoved", /var cropsRemoved: Int\?/],
  ]) {
    // Either spelling of an object entry: the shorthand `key,` or an explicit
    // `key: <expr>,`. Which one a key uses is a detail of the renderer; that
    // the key reaches `brief.json` at all is the contract.
    assert.match(
      renderer,
      new RegExp(`^\\s*${key}(,|:)`, "m"),
      `render-brief must put \`${key}\` in the summary`,
    );
    assert.match(pipeline, decl, `BriefSummary must decode \`${key}\`, and optionally`);
  }
});

test("the renderer reads the exclusion file the app writes", () => {
  // The × on a thumbnail writes this; the renderer is the only reader. A
  // rename on either side silently un-removes every screenshot somebody chose
  // to hold back, which is the one failure this feature cannot have.
  const renderer = read("scripts/render-brief.mjs");
  const pipeline = read("apps/capture/Sources/DeikoCapture/BriefPipeline.swift");

  assert.match(renderer, /crops\.excluded\.json/);
  assert.match(pipeline, /crops\.excluded\.json/);
});

test("an excluded screenshot's referent is dropped, not just its path", () => {
  // `lib/prompt.mjs` ships a referent's screen text exactly when it has NO
  // crop and speech was bound to it. So nulling `cropPath` the way a withheld
  // crop does would send the TEXT of the image the developer removed. The
  // filter has to run before `released` is built.
  const renderer = read("scripts/render-brief.mjs");
  assert.match(
    renderer,
    /const kept = referents\.filter\(/,
    "the exclusion must filter referents, not blank a field on them",
  );
  assert.match(
    renderer,
    /const released = kept\.map\(/,
    "`released` must be built from the filtered list",
  );
});

test("the transcript's `cloud` block is written from the transcriber's own state", () => {
  // `transcribe.mjs` is a script with top-level `main()`, so it cannot be
  // imported and this seam cannot be driven without real audio and a Speech
  // grant. What can be checked is that the three pieces still line up:
  // `relayTranscriber` records a reason, `chunkedTranscriber` carries the
  // state object out, and `main` writes it. Break any one and the review
  // window silently goes back to explaining nothing.
  const transcribe = read("scripts/transcribe.mjs");

  assert.match(
    transcribe,
    /function chunkedTranscriber\(name, uploadOne, state = \{\}\)/,
    "the transcriber must accept and expose a state object",
  );
  assert.match(
    transcribe,
    /state\.refused \?\?= /,
    "the FIRST reason must win — a later rate limit must not overwrite `trial`",
  );
  assert.match(
    transcribe,
    /refused: transcriber\.state\?\.refused \?\? null/,
    "the reason must reach transcript.json",
  );
  // The on-device and Sarvam transcribers carry no state, so `?.` and `?? null`
  // are what keep those paths writing a well-formed block rather than crashing.
  assert.match(transcribe, /failedChunks,/, "the chunk count must reach transcript.json too");
});

test("only account-level refusals end the session's uploads", () => {
  // The distinction `REFUSAL_IS_FINAL` encodes, asserted where it is USED: a
  // transient 429 must fall through to the throw, so the next chunk retries.
  // Short-circuiting it would drop every word after the first blip on a long
  // recording, which is the failure this shape exists to avoid.
  const transcribe = read("scripts/transcribe.mjs");
  assert.match(
    transcribe,
    /if \(state\.refused && REFUSAL_IS_FINAL\.has\(state\.refused\)\)/,
    "the short-circuit must be gated on REFUSAL_IS_FINAL, not on any refusal",
  );
});

test("the trust line's upload count survives from transcriber to Swift", () => {
  // `uploaded` is what stops the review panel claiming an upload that never
  // happened — a relay that was never reached, or an old session reopened
  // entirely from the transcript cache. Three files, no shared type.
  const transcribe = read("scripts/transcribe.mjs");
  const renderer = read("scripts/render-brief.mjs");
  const pipeline = read("apps/capture/Sources/DeikoCapture/BriefPipeline.swift");

  assert.match(transcribe, /state\.uploaded \+= 1;/, "requests that reach the network must be counted");
  assert.match(renderer, /uploadedChunks: cloud\?\.uploaded \?\? null/);
  assert.match(pipeline, /var uploadedChunks: Int\?/);
});

test("a re-render over a cached session cannot restamp what happened to it", () => {
  // Reopening an old session re-runs transcribe.mjs with every hold served
  // from the cache. Rewriting `cloud` from the CURRENT environment would make
  // the panel announce an upload for a session recorded on a build that had no
  // relay at all.
  const transcribe = read("scripts/transcribe.mjs");
  assert.match(
    transcribe,
    /if \(uploaded === 0 && priorCloud\) return priorCloud;/,
    "the previous answer must stand when this run uploaded nothing",
  );
});

test("an edited narration still suppresses screen text from crop-less referents", () => {
  // `said` gates two different things, and only one of them is a caption. On a
  // referent with no screenshot it decides whether that referent's ACCESSIBILITY
  // TEXT reaches the prompt — and overlap bindings are often one to three words
  // ("this one", "here"), which survive a correction by coincidence. Per-quote
  // survival alone would therefore ship the contents of a window the developer
  // had just edited themselves out of.
  const renderer = read("scripts/render-brief.mjs");
  assert.match(
    renderer,
    /const keepQuote = path != null \? survives : \(narrationOverride == null/,
    "screen text must keep the strict rule; only captions get per-quote survival",
  );
});

// ── every degradation Node can name, Swift can say ──────────────────────────

test("each reason degradedReason returns has a sentence in SessionClaims", () => {
  // GENERALISED ON PURPOSE, rather than pinning one more string pair by hand.
  // `degradedReason` is the only thing that mints these names and
  // `degradedSentence` is the only thing that renders them, so a reason added
  // on the Node side with no Swift case is a session that degrades silently —
  // which is the exact bug this whole change exists to fix, in miniature.
  const cloud = read("scripts/lib/cloud.mjs");
  const claims = read("apps/capture/Sources/DeikoHandoff/SessionClaims.swift");

  const body = cloud.slice(cloud.indexOf("export function degradedReason"));
  const returned = [...body.matchAll(/return "([a-z-]+)"/g)].map((m) => m[1]);

  assert.ok(returned.includes("on-device"), "degradedReason should still name a relay-less build");
  for (const reason of new Set(returned)) {
    assert.ok(
      claims.includes(`case "${reason}"`),
      `degradedReason can return "${reason}" and SessionClaims has no case for it`,
    );
  }
  // Direction matters: Node ⊆ Swift. Swift also switches on transcriber names
  // in trustLine, so the reverse check would fail on strings that are not
  // reasons at all.
});

test("the transcriber's name reaches the cloud block degradedReason reads", () => {
  // `degradedReason` now classifies on `cloud.transcriber`. If cloudBlock stops
  // writing it, every relay-less session goes back to claiming it is fine.
  const transcribe = read("scripts/transcribe.mjs");
  const block = transcribe.slice(transcribe.indexOf("function cloudBlock"));
  assert.match(block.slice(0, 900), /transcriber:/, "cloudBlock must carry the transcriber's name");
});

// ── the build stamps what it was told, and a release says so out loud ───────

test("the four stamped values default from .env", () => {
  // The bug: `make install RELAY_URL=…` produced a correct app, and the next
  // plain `make install` stamped all four EMPTY over it. Deleting either half
  // of the fix — the helper or a default — brings that back.
  const mk = read("Makefile");
  assert.match(mk, /^env-default = /m, "the .env reader is gone");
  for (const name of ["RELAY_URL", "SITE_URL", "BUY_URL", "SUPPORT_EMAIL"]) {
    assert.match(
      mk,
      new RegExp(`^${name}\\s*\\?= \\$\\(call env-default,${name}\\)`, "m"),
      `${name} no longer defaults from .env`,
    );
  }
});

test("a release refuses to inherit a URL from somebody's .env", () => {
  // `-n` stopped proving intent the moment .env could supply a value, and a
  // release is the one build whose URLs are baked into a plist that can never
  // be corrected remotely.
  const mk = read("Makefile");
  for (const name of ["RELAY_URL", "SITE_URL"]) {
    assert.match(
      mk,
      new RegExp(`origin ${name}\\)' = 'command line'`),
      `${name} release guard no longer checks origin`,
    );
  }
});
