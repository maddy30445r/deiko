// Contract between the Swift app and the Node scripts, which never call each
// other. `PipelineFailure.classify` (Swift) picks the orb's message by matching
// substrings the scripts print to stderr, and `ReviewWindow` branches on the
// withhold reasons `render-brief.mjs` writes to `brief.json`. Rewording either
// side would break the other silently, so this test reads both as text and
// checks that the strings still meet. It needs no Swift toolchain.

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { TIMINGS_DONE, awaitPrecomputed } from "../src/lib/session-io.mjs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "..", "..", "..");
const read = (p) => readFileSync(join(root, p), "utf8");

const swift = read("apps/macos/Sources/DeikoHandoff/PipelineFailure.swift");
const scripts = [
  "packages/core/src/transcribe.mjs",
  "packages/core/src/render-brief.mjs",
  "packages/core/src/summarize.mjs",
  "packages/core/src/lib/redact.mjs",
  "packages/core/src/lib/prompt.mjs",
].map(read).join("\n");

// Every literal the Swift taxonomy matches on. `text.contains("…")` is the only
// form `classify` uses, so the list is extracted rather than hand-maintained.
const matched = [...swift.matchAll(/text\.contains\("([^"]+)"\)/g)].map((m) => m[1]);

test("the Swift failure taxonomy matches on strings that still exist", () => {
  assert.ok(matched.length >= 10, `expected a real taxonomy, found ${matched.length} branches`);

  // Not printed literally by any script, for the reasons below.
  const notOurs = new Set([
    // 1. Written by the Swift side itself.
    "timed out after",          // BriefPipeline's watchdog
    "could not find node",      // BriefPipelineError.nodeNotFound's description

    // 2. Arrives from elsewhere at runtime. `transcribe.mjs` throws
    //    `Groq ${status}: …` and the provider's body supplies the rest. The
    //    `sarvam` spellings stay matched for cached failures of older sessions.
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

    // The relay's own refusals. `transcribe.mjs` throws
    // `Deiko relay ${status}: ${body}` and the body comes from
    // services/relay/{quota,relay}.mjs, a different deployable. The
    // status-and-body → reason mapping is in packages/core/src/lib/cloud.mjs
    // (tested in cloud.test.mjs).
    "fair-use limit",            // quota.mjs: the monthly allowance is spent
    "daily ceiling",             // quota.mjs: the service is spent, not the user
    "usage service unavailable", // relay.mjs: metering down, failing closed
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

test("the provider status prefix the taxonomy relies on is still constructed", () => {
  // `classify` matches "groq 401" and friends, which no source contains:
  // `transcribe.mjs` builds them from the status at runtime. Pin the template,
  // since rewording it would break them all silently.
  assert.match(
    read("packages/core/src/transcribe.mjs"),
    /`Groq \$\{response\.status\}/,
    "the taxonomy matches `groq <status>` — this template is where that shape comes from",
  );
});

test("the watchdog's timeout marker is what the Swift side looks for", () => {
  // Both halves are Swift, but they live in different targets and only meet
  // through this string: BriefPipeline writes it, DeikoHandoff classifies it.
  const pipeline = read("apps/macos/Sources/DeikoCapture/BriefPipeline.swift");
  assert.ok(
    pipeline.includes("timed out after"),
    "BriefPipeline must write the marker PipelineFailure matches on",
  );
  assert.ok(matched.includes("timed out after"));
});

test("the two withhold reasons are the ones the review window branches on", () => {
  // `ReviewWindow.withheldSentence` picks between "a credential was visible"
  // and "couldn't read them to check" by looking for these words. Rewording the
  // renderer would tell a first-run user a credential was on their screen.
  const renderer = read("packages/core/src/render-brief.mjs");
  const review = read("apps/macos/Sources/DeikoCapture/ReviewWindow.swift");

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
  const renderer = read("packages/core/src/render-brief.mjs");
  const pipeline = read("apps/macos/Sources/DeikoCapture/BriefPipeline.swift");

  assert.match(renderer, /^\s*degraded,$/m, "render-brief must put `degraded` in the summary");
  assert.match(pipeline, /var degraded: Bool\?/, "BriefSummary must decode it, and optionally");
});

test("every summary key the review window reads is one the renderer writes", () => {
  // Same contract as `degraded`. Each key crosses from a Node script into a
  // Swift `Codable` with no shared type, so only this test holds them together.
  const renderer = read("packages/core/src/render-brief.mjs");
  const pipeline = read("apps/macos/Sources/DeikoCapture/BriefPipeline.swift");

  for (const [key, decl] of [
    ["degradedReason", /var degradedReason: String\?/],
    ["transcriber", /var transcriber: String\?/],
    ["labelsDropped", /var labelsDropped: Int\?/],
    ["cropsRemoved", /var cropsRemoved: Int\?/],
  ]) {
    // Either the shorthand `key,` or an explicit `key: <expr>,`; that the key
    // reaches `brief.json` is the contract.
    assert.match(
      renderer,
      new RegExp(`^\\s*${key}(,|:)`, "m"),
      `render-brief must put \`${key}\` in the summary`,
    );
    assert.match(pipeline, decl, `BriefSummary must decode \`${key}\`, and optionally`);
  }
});

test("the renderer reads the exclusion file the app writes", () => {
  // The × on a thumbnail writes this and the renderer is the only reader. A
  // rename on either side would silently un-remove every screenshot the
  // developer held back.
  const renderer = read("packages/core/src/render-brief.mjs");
  const pipeline = read("apps/macos/Sources/DeikoCapture/BriefPipeline.swift");

  assert.match(renderer, /crops\.excluded\.json/);
  assert.match(pipeline, /crops\.excluded\.json/);
});

test("an excluded screenshot's referent is dropped, not just its path", () => {
  // `lib/prompt.mjs` ships a referent's screen text exactly when it has no crop
  // and speech was bound to it, so nulling `cropPath` would send the text of
  // the image the developer removed. The filter must run before `released` is
  // built.
  const renderer = read("packages/core/src/render-brief.mjs");
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
  // `transcribe.mjs` runs `main()` at top level, so it cannot be imported and
  // driven without real audio. Check instead that `relayTranscriber` records a
  // reason, `chunkedTranscriber` carries the state out, and `main` writes it.
  const transcribe = read("packages/core/src/transcribe.mjs");

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
  // A transient 429 must fall through to the throw so the next chunk retries;
  // short-circuiting it would drop every word after the first blip.
  const transcribe = read("packages/core/src/transcribe.mjs");
  assert.match(
    transcribe,
    /if \(state\.refused && REFUSAL_IS_FINAL\.has\(state\.refused\)\)/,
    "the short-circuit must be gated on REFUSAL_IS_FINAL, not on any refusal",
  );
});

test("the trust line's upload count survives from transcriber to Swift", () => {
  // `uploaded` stops the review panel claiming an upload that never happened (a
  // relay never reached, or an old session reopened from the transcript cache).
  // Three files, no shared type.
  const transcribe = read("packages/core/src/transcribe.mjs");
  const renderer = read("packages/core/src/render-brief.mjs");
  const pipeline = read("apps/macos/Sources/DeikoCapture/BriefPipeline.swift");

  assert.match(transcribe, /state\.uploaded \+= 1;/, "requests that reach the network must be counted");
  assert.match(renderer, /uploadedChunks: cloud\?\.uploaded \?\? null/);
  assert.match(pipeline, /var uploadedChunks: Int\?/);
});

test("a re-render over a cached session cannot restamp what happened to it", () => {
  // Reopening an old session re-runs transcribe.mjs with every hold served from
  // the cache. Rewriting `cloud` from the current environment would announce an
  // upload for a session that never had one.
  const transcribe = read("packages/core/src/transcribe.mjs");
  assert.match(
    transcribe,
    /if \(uploaded === 0 && priorCloud\) return priorCloud;/,
    "the previous answer must stand when this run uploaded nothing",
  );
});

test("an edited narration still suppresses screen text from crop-less referents", () => {
  // `said` gates screen text on a referent with no screenshot, and overlap
  // bindings are often one to three words ("this one", "here") that survive a
  // correction by coincidence. Per-quote survival alone would ship the text of
  // a window the developer had just edited themselves out of.
  const renderer = read("packages/core/src/render-brief.mjs");
  assert.match(
    renderer,
    /const keepQuote = path != null \? survives : \(narrationOverride == null/,
    "screen text must keep the strict rule; only captions get per-quote survival",
  );
});

// ── Degradation reasons ──

test("each reason degradedReason returns has a sentence in SessionClaims", () => {
  // `degradedReason` mints these names and `degradedSentence` renders them, so
  // a reason with no Swift case would degrade silently.
  const cloud = read("packages/core/src/lib/cloud.mjs");
  const claims = read("apps/macos/Sources/DeikoHandoff/SessionClaims.swift");

  const body = cloud.slice(cloud.indexOf("export function degradedReason"));
  const returned = [...body.matchAll(/return "([a-z-]+)"/g)].map((m) => m[1]);

  assert.ok(returned.includes("on-device"), "degradedReason should still name a relay-less build");
  for (const reason of new Set(returned)) {
    assert.ok(
      claims.includes(`case "${reason}"`),
      `degradedReason can return "${reason}" and SessionClaims has no case for it`,
    );
  }
  // Node ⊆ Swift only: Swift also switches on transcriber names in trustLine,
  // so the reverse check would fail on strings that are not reasons.
});

test("the transcriber's name reaches the cloud block degradedReason reads", () => {
  // `degradedReason` classifies on `cloud.transcriber`; if cloudBlock stops
  // writing it, relay-less sessions claim they are fine.
  const transcribe = read("packages/core/src/transcribe.mjs");
  const block = transcribe.slice(transcribe.indexOf("function cloudBlock"));
  assert.match(block.slice(0, 900), /transcriber:/, "cloudBlock must carry the transcriber's name");
});

// ── Build stamps ──

test("the four stamped values default from .env", () => {
  // A plain `make install` must not stamp the four values empty: each defaults
  // from .env via the helper.
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
  // A release bakes its URLs into a plist that cannot be corrected remotely, so
  // they must come from the command line, never from .env.
  const mk = read("Makefile");
  for (const name of ["RELAY_URL", "SITE_URL"]) {
    assert.match(
      mk,
      new RegExp(`origin ${name}\\)' = 'command line'`),
      `${name} release guard no longer checks origin`,
    );
  }
});

// ── On-device timings ──

test("the app's done marker is the one the script waits on, and the script is told to wait", () => {
  const pipeline = read("apps/macos/Sources/DeikoCapture/BriefPipeline.swift");
  assert.match(pipeline, new RegExp(`doneMarker = "${TIMINGS_DONE.replace(".", "\\.")}"`));
  assert.match(pipeline, /"DEIKO_TIMINGS_PENDING": "1"/);
  assert.match(read("packages/core/src/transcribe.mjs"), /process\.env\.DEIKO_TIMINGS_PENDING === "1"/);
});

test("a pending timing file is waited for, and given up on once the app says it is done", async () => {
  const dir = mkdtempSync(join(tmpdir(), "deiko-timings-"));
  const out = join(dir, "hold-1.wav.timing.json");
  const far = () => Date.now() + 5_000;

  setTimeout(() => writeFileSync(out, "{}"), 300);
  assert.equal(await awaitPrecomputed(out, { deadline: far() }), out, "lands while we wait");

  rmSync(out);
  writeFileSync(join(dir, TIMINGS_DONE), "");
  const t0 = Date.now();
  assert.equal(await awaitPrecomputed(out, { deadline: far() }), null, "the app finished without it");
  assert.ok(Date.now() - t0 < 1_000, "at once, not at the deadline");

  rmSync(join(dir, TIMINGS_DONE));
  assert.equal(await awaitPrecomputed(out, { deadline: Date.now() + 250 }), null, "and never past the deadline");
});
