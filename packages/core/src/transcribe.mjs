#!/usr/bin/env node
/**
 * Transcribe a recorded session's narration into words on the SESSION CLOCK.
 *
 *   node scripts/transcribe.mjs sessions/<id>
 *
 * The important step is the last one. An ASR returns word times as offsets into
 * an audio file; the aligner needs them on the same monotonic clock as the
 * cursor samples. So every word is shifted by that hold's `audioT0` — the
 * moment the first audio buffer actually arrived, which we measured at a
 * consistent ~255ms after the hotkey went down. Skip the shift and every word
 * sits a quarter-second early, uniformly, and alignment fails in a way that
 * looks like the mechanic not working rather than a clock bug.
 *
 * Sarvam is behind a one-method interface because PRD §14 lists the dependency
 * as a real risk; Whisper or Apple Speech drop in without the aligner noticing.
 */

import { readFileSync, writeFileSync, existsSync, rmSync, statSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { execFileSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

// The \p{M}-preserving normaliser from the aligner — imported, not copied,
// because the whole point of normalising here is to match what the aligner
// will match on.
import { normalizeWord } from "../packages/alignment/dist/src/deictic.js";
import { loadEvents } from "./lib/session-io.mjs";
import { refusalReason, REFUSAL_IS_FINAL } from "./lib/cloud.mjs";

const SARVAM_STT_URL = "https://api.sarvam.ai/speech-to-text";

// ── Stage timing ────────────────────────────────────────────────────────────
//
// The cost of this pipeline is not where it looks. Recognition runs on the
// FINISHED file at roughly realtime, so for any session worth recording it
// dominates everything else put together — and nothing in the output said so
// until this printed it.
//
// Kept after the fact deliberately: it is the regression check. Any change that
// claims to make transcription faster has to move these numbers, and any change
// that quietly makes it slower shows up here instead of in a user's patience.
const stages = new Map();

async function timed(name, fn) {
  const t0 = performance.now();
  try {
    return await fn();
  } finally {
    stages.set(name, (stages.get(name) ?? 0) + (performance.now() - t0));
  }
}

function timingReport(totalMs) {
  const secs = (ms) => `${(ms / 1000).toFixed(1)}s`;
  const parts = [...stages].map(([name, ms]) => `${name} ${secs(ms)}`);
  // Accounted-for time is not the whole wall clock — event loading, the merge's
  // callers and process startup sit outside every stage — so print the total
  // separately rather than implying the parts sum to it.
  return `  timing: ${parts.join(" · ")}  |  total ${secs(totalMs)}`;
}

// ── The interface ───────────────────────────────────────────────────────────

/**
 * @typedef {{ name: string, transcribe: (wavPath: string, opts: {language?: string}) => Promise<{text: string}> }} Transcriber
 */

/**
 * Sarvam's REST endpoint rejects anything over 30 seconds ("please use the
 * batch API"), and the batch API returns chunk-level timestamps only — useless
 * for binding individual words to pointing events. So split long holds here.
 *
 * These chunks upload CONCURRENTLY, and the whole Sarvam call now runs alongside
 * on-device recognition rather than after it, so it costs nothing on the clock —
 * about 2s hidden inside recognition's 12s on a 77s session.
 *
 * This comment used to say a streaming WebSocket API was the shipping path and
 * this was only a gate harness. It is the shipping path. Streaming would remove
 * the last chunk's round trip; it is not where the latency was.
 */
const CHUNK_SECONDS = 25;
const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;

/// How many chunks may be in flight at once.
///
/// Four, because the relay's Lambda reserves five concurrent executions
/// (`services/relay/deploy-aws.sh`). A long session split into two dozen
/// chunks and fired all at once throttles against that reservation, and one
/// throttled chunk used to lose the whole session's cloud text. Staying under
/// the reservation is what makes the fallback rare rather than routine.
const UPLOAD_CONCURRENCY = 4;

/// A stalled upload should cost one chunk, not the session. Without a signal
/// `fetch` falls through to undici's ~300s default, which is five minutes of
/// an orb reading "Transcribing…" with nothing to show for it. Sixty seconds
/// matches the relay's own Lambda timeout — past that there is nothing coming.
const UPLOAD_TIMEOUT_MS = 60_000;

/**
 * The chunking half, shared by every network transcriber.
 *
 * Splitting long audio at silence and uploading the pieces concurrently is the
 * same problem whoever is on the other end, so `uploadOne` is the only thing
 * that differs between talking to Sarvam directly and talking to Deiko's relay.
 *
 * `state` is the transcriber's own scratchpad, shared with `uploadOne` and read
 * back by the caller once every hold is done — today it carries WHY the relay
 * refused, which is a fact about the session rather than about any one chunk.
 *
 * @returns {Transcriber}
 */
function chunkedTranscriber(name, uploadOne, state = {}) {
  return {
    name,
    state,
    async transcribe(wavPath, { language = "unknown" } = {}) {
      const file = readFileSync(wavPath);
      const pcm = file.subarray(44);
      const totalSeconds = pcm.length / (SAMPLE_RATE * BYTES_PER_SAMPLE);

      if (totalSeconds <= CHUNK_SECONDS) {
        return timed(name, () => uploadOne(pcm, language));
      }

      const chunks = splitAtSilence(pcm, CHUNK_SECONDS);
      process.stderr.write(`(${totalSeconds.toFixed(0)}s → ${chunks.length} chunks) `);

      // Concurrently, but IN SLICES, and never all at once. The chunks are
      // independent uploads of a recording that already exists, so waiting for
      // each round trip before starting the next spends latency for nothing —
      // but firing all of them spends something worse. A ten-minute session is
      // twenty-four uploads against a relay whose reserved concurrency is five;
      // Lambda throttles the excess, and under a plain `Promise.all` one
      // throttled chunk rejected the whole session and dropped every word to
      // the on-device fallback. Four at a time stays under the reservation.
      //
      // `allSettled` per slice is the other half: a chunk that still fails
      // costs its own stretch of sentence and nothing else. The failures are
      // reported so the brief can say it is missing something rather than
      // quietly reading short.
      const parts = [];
      const failures = [];
      await timed(name, async () => {
        for (let i = 0; i < chunks.length; i += UPLOAD_CONCURRENCY) {
          const slice = chunks.slice(i, i + UPLOAD_CONCURRENCY);
          const settled = await Promise.allSettled(
            slice.map((data) => uploadOne(data, language)));
          settled.forEach((outcome, n) => {
            // Order is what the join depends on — these are consecutive
            // stretches of one sentence, not a set — so a failed chunk holds
            // its place with empty text rather than closing the gap.
            if (outcome.status === "fulfilled") parts.push(outcome.value);
            else {
              parts.push({ text: "" });
              failures.push({ chunk: i + n, reason: String(outcome.reason?.message ?? outcome.reason) });
            }
          });
        }
      });

      if (failures.length) {
        process.stderr.write(
          `· ${failures.length}/${chunks.length} chunks failed — the transcript is missing some words `);
      }
      return {
        text: parts.map((p) => p.text).filter(Boolean).join(" "),
        failedChunks: failures.length,
        // Carried up so the cache can tell a refused stretch from silence.
        refused: parts.some((p) => p.refused),
      };
    },
  };
}

/** The multipart body both Sarvam and the relay accept. */
function sttForm(pcm, language) {
  const form = new FormData();
  form.append("file", new Blob([wrapWav(pcm)], { type: "audio/wav" }), "audio.wav");
  form.append("model", "saaras:v3");
  // `translit` returns Latin script — "Yeh jo data hai ismein taxonomy ke
  // andar board ka naam" — matching the on-device timings and the Latin
  // half of the deictic lexicon. `codemix` returns Devanagari for the same
  // audio, which the lexicon also handles but which reads worse in a plan.
  form.append("mode", "translit");
  form.append("language_code", language);
  return form;
}

/** The developer's own Sarvam key: their key, their bill, nothing in between. */
function sarvamTranscriber(apiKey) {
  return chunkedTranscriber("sarvam", async (pcm, language) => {
    const response = await fetch(SARVAM_STT_URL, {
      method: "POST",
      headers: { "api-subscription-key": apiKey },
      body: sttForm(pcm, language),
      signal: AbortSignal.timeout(UPLOAD_TIMEOUT_MS),
    });

    const bodyText = await response.text();
    if (!response.ok) {
      throw new Error(`Sarvam ${response.status}: ${bodyText.slice(0, 400)}`);
    }

    let raw;
    try {
      raw = JSON.parse(bodyText);
    } catch {
      throw new Error(`Sarvam returned non-JSON: ${bodyText.slice(0, 400)}`);
    }

    // TEXT only. Sarvam returns no word-level timings on any model or
    // parameter combination we tried — one span for the whole clip — so the
    // timeline comes from on-device Apple Speech and Sarvam supplies the
    // words. There used to be a 60-line tolerant extractor here for timings
    // that never arrived, feeding a field nothing read.
    return { text: extractText(raw) };
  });
}

/**
 * Deiko's relay: the default, so a new user transcribes without holding an
 * account anywhere.
 *
 * The audio goes to Deiko's server, which forwards it and keeps nothing. That
 * is a materially different promise from "only to Sarvam", and the app says so
 * where people can read it before they start. Anyone who would rather not is
 * one Settings field away from their own key, which skips this entirely.
 */
function relayTranscriber(endpoint, token) {
  const url = `${endpoint.replace(/\/+$/, "")}/v1/transcribe`;

  // SOME REFUSALS ANSWER FOR THE WHOLE SESSION, AND SOME ARE WORTH RETRYING.
  //
  // A spent trial, a spent month and the service's daily ceiling are facts
  // about the account or the day — every later chunk would hear the same
  // thing, and uploading them anyway spends bandwidth and relay requests to be
  // told what is already known. A refused stretch rides on Apple's on-device
  // words, exactly the fallback quota.mjs documents, and is not counted as a
  // failure: the session is degraded, not broken.
  //
  // A rate limit or a 503 is NOT such a fact. The relay's in-memory limiter
  // allows 30 requests a minute per token (services/relay/relay.mjs:104) and a
  // twelve-minute session is ~29 chunks plus quota calls, so a burst 429 on
  // chunk 7 of a long recording is both plausible and temporary. It throws
  // like any other chunk failure — costing its own stretch of sentence and
  // nothing else — and the next chunk tries again. `REFUSAL_IS_FINAL` is where
  // that distinction lives.
  //
  // `state.refused` is remembered either way, and the FIRST reason wins: it is
  // what the review window shows, and "your trial is used up" outranks the
  // rate limit that followed it.
  const state = { refused: null, uploaded: 0 };
  return chunkedTranscriber("deiko", async (pcm, language) => {
    if (state.refused && REFUSAL_IS_FINAL.has(state.refused)) {
      return { text: "", refused: true };
    }

    let response;
    let bodyText;
    try {
      // Counted BEFORE the await, because the bytes are on the wire either
      // way: what the review window has to be able to say is whether audio
      // left this Mac, and a request that was sent and then refused still
      // left it. A DNS failure that never opened a socket does not reach
      // here, which is exactly the distinction the trust line needs.
      state.uploaded += 1;
      response = await fetch(url, {
        method: "POST",
        headers: token ? { authorization: `Bearer ${token}` } : {},
        body: sttForm(pcm, language),
        signal: AbortSignal.timeout(UPLOAD_TIMEOUT_MS),
      });
      bodyText = await response.text();
    } catch (err) {
      // The request never landed — a timeout, DNS, no route. Status 0 is how
      // `refusalReason` spells that, and it is `unavailable` like any 503.
      state.refused ??= refusalReason(0);
      throw err;
    }

    const reason = refusalReason(response.status, bodyText);
    if (reason) {
      state.refused ??= reason;
      if (REFUSAL_IS_FINAL.has(reason)) {
        process.stderr.write(`· ${REFUSAL_NOTE[reason]} — continuing on on-device words `);
        return { text: "", refused: true };
      }
      throw new Error(`Deiko relay ${response.status}: ${bodyText.slice(0, 400)}`);
    }

    try {
      return { text: extractText(JSON.parse(bodyText)) };
    } catch {
      throw new Error(`Deiko relay returned non-JSON: ${bodyText.slice(0, 400)}`);
    }
  }, state);
}

/** What stderr says when a refusal ends the session's cloud transcription. */
const REFUSAL_NOTE = {
  trial: "free trial used up",
  monthly: "this month's Pro hours used up",
  ceiling: "the service is at its daily ceiling",
};

/**
 * Nobody on the other end — and that is a supported way to run.
 *
 * Returning empty text rather than throwing is what makes this a configuration
 * rather than a branch: the merge step below already handles "no cloud words,
 * keep the on-device ones", because that is what it does when Sarvam fails.
 * The words and their timings both come from Apple, and the session is intact.
 */
function onDeviceOnlyTranscriber() {
  return { name: "on-device", async transcribe() { return { text: "" }; } };
}

/**
 * Who transcribes, most specific first.
 *
 * 1. the developer's own Sarvam key — an explicit choice, so it wins;
 * 2. Deiko's relay — the default, and the reason a new install needs no key;
 * 3. on-device only — offline, or nothing configured. Degraded, not broken.
 */
function selectTranscriber() {
  if (process.env.SARVAM_API_KEY) return sarvamTranscriber(process.env.SARVAM_API_KEY);
  if (process.env.DEIKO_RELAY_URL) {
    return relayTranscriber(process.env.DEIKO_RELAY_URL, process.env.DEIKO_RELAY_TOKEN);
  }
  return onDeviceOnlyTranscriber();
}

/**
 * Split PCM into chunks at the QUIETEST point near each boundary rather than at
 * a fixed offset. A fixed cut lands mid-word roughly as often as not, and a
 * word sliced in half is either dropped or mis-transcribed at every boundary —
 * which would show up in the gate as an alignment failure rather than as an
 * audio-handling one.
 */
function splitAtSilence(pcm, chunkSeconds) {
  const bytesPerChunk = chunkSeconds * SAMPLE_RATE * BYTES_PER_SAMPLE;
  const searchRadius = 2 * SAMPLE_RATE * BYTES_PER_SAMPLE; // ±2s
  const windowBytes = 0.1 * SAMPLE_RATE * BYTES_PER_SAMPLE; // 100ms

  const chunks = [];
  let start = 0;

  while (start < pcm.length) {
    let end = start + bytesPerChunk;
    if (end >= pcm.length) {
      end = pcm.length;
    } else {
      // Scan a window either side of the nominal boundary for the lowest energy.
      let quietestAt = end;
      let quietest = Infinity;
      const from = Math.max(start + bytesPerChunk / 2, end - searchRadius);
      const to = Math.min(pcm.length - windowBytes, end + searchRadius);

      for (let at = from; at < to; at += windowBytes) {
        let energy = 0;
        for (let i = at; i < at + windowBytes; i += 64) {
          energy += Math.abs(pcm.readInt16LE(i & ~1));
        }
        if (energy < quietest) {
          quietest = energy;
          quietestAt = at;
        }
      }
      end = quietestAt & ~1; // keep 16-bit sample alignment
    }

    chunks.push(pcm.subarray(start, end));
    start = end;
  }

  return chunks;
}

/** Wrap raw 16kHz mono PCM in a minimal WAV header. */
function wrapWav(pcm) {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16); // PCM chunk size
  header.writeUInt16LE(1, 20); // format = PCM
  header.writeUInt16LE(1, 22); // channels
  header.writeUInt32LE(SAMPLE_RATE, 24);
  header.writeUInt32LE(SAMPLE_RATE * BYTES_PER_SAMPLE, 28); // byte rate
  header.writeUInt16LE(BYTES_PER_SAMPLE, 32); // block align
  header.writeUInt16LE(16, 34); // bits per sample
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

function extractText(raw) {
  return String(raw?.transcript ?? raw?.text ?? raw?.output?.transcript ?? "").trim();
}

// ── The anchor merge ────────────────────────────────────────────────────────

/**
 * Put Sarvam's words (right text, no times) onto Apple's timeline (wrong text,
 * real times).
 *
 * Why this works: both recognisers heard the SAME audio, so their token
 * sequences are two noisy views of one utterance, monotonic in time. The
 * tokens they agree on — in this session: taxonomy, CBSE, Telangana, tenant,
 * Yeh, Yahan — become anchors via longest-common-subsequence (monotonic by
 * construction, so anchors can never cross). Sarvam tokens between two anchors
 * are spread evenly across the gap.
 *
 * The binding window is ±1.5s, so evenly-spread is genuinely good enough: a
 * word only needs to land within a second or so of when it was said, not on
 * the exact syllable.
 */
function mergeWords(sarvamText, appleWords, audioDurationMs) {
  // Apple's own segments are measurements, so they are anchored by definition.
  // Labelling them keeps `anchored` meaning the same thing on every path — an
  // absent field would be indistinguishable from "not anchored".
  const asAnchored = (ws) => ws.map((w) => ({ ...w, anchored: true }));

  const sTokens = sarvamText.split(/\s+/).filter((t) => normalizeWord(t).length > 0);
  if (sTokens.length === 0 || appleWords.length === 0) {
    return { words: asAnchored(appleWords), anchors: 0, total: sTokens.length };
  }
  const sNorm = sTokens.map(normalizeWord);

  // Apple's "words" are segments that may hold several words ("tenant check
  // if"); flatten to timed tokens, spreading times within each segment.
  const aTokens = [];
  for (const seg of appleWords) {
    const parts = seg.text.split(/\s+/).filter((t) => normalizeWord(t).length > 0);
    const span = Math.max(seg.end - seg.start, 1);
    parts.forEach((p, k) => {
      aTokens.push({ norm: normalizeWord(p), t: seg.start + (span * k) / parts.length });
    });
  }

  // Longest common subsequence over normalized tokens → anchor pairs.
  // Sequences are tiny (tens of tokens), so the O(n·m) table is nothing.
  const n = sNorm.length;
  const m = aTokens.length;
  const lcs = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lcs[i][j] =
        sNorm[i] === aTokens[j].norm
          ? lcs[i + 1][j + 1] + 1
          : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const anchors = [];
  for (let i = 0, j = 0; i < n && j < m; ) {
    if (sNorm[i] === aTokens[j].norm) {
      anchors.push({ idx: i, t: aTokens[j].t });
      i++; j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) i++;
    else j++;
  }

  if (anchors.length === 0) {
    // Nothing agreed — keep Apple's words rather than inventing a timeline.
    return { words: asAnchored(appleWords), anchors: 0, total: n };
  }

  // Interpolate: anchored tokens keep their time; the rest spread evenly
  // between the surrounding anchors (start of audio / end of audio at the
  // edges).
  const times = new Array(n);
  let prevIdx = -1;
  let prevT = 0;
  for (const b of [...anchors, { idx: n, t: audioDurationMs }]) {
    const gap = b.idx - prevIdx;
    for (let i = prevIdx + 1; i < b.idx; i++) {
      times[i] = prevT + ((i - prevIdx) / gap) * (b.t - prevT);
    }
    if (b.idx < n) times[b.idx] = b.t;
    prevIdx = b.idx;
    prevT = b.t;
  }

  // Which words carry a REAL timing and which were interpolated between two.
  // The merge already knows; it used to throw the answer away, and that made a
  // whole class of question unanswerable after the fact — when anchors came out
  // at 37/223 on good audio there was no way to tell from the transcript whether
  // they were spread evenly or bunched at one end.
  //
  // It is also the confidence signal the aligner is missing. A binding resting
  // on an anchored word is standing on a measurement; one resting on an
  // interpolated word is standing on a straight line drawn between two distant
  // measurements, and those are not equally trustworthy.
  const anchoredAt = new Set(anchors.map((a) => a.idx));

  const words = sTokens.map((text, i) => ({
    text,
    start: times[i],
    end: Math.min(times[i] + 300, times[i + 1] ?? times[i] + 300),
    source: "merged",
    anchored: anchoredAt.has(i),
  }));
  return { words, anchors: anchors.length, total: n };
}

/** 16kHz mono 16-bit PCM: duration falls straight out of the byte count. */
function wavDurationMs(wavPath) {
  return ((statSync(wavPath).size - 44) / (SAMPLE_RATE * BYTES_PER_SAMPLE)) * 1000;
}

/**
 * Words spread evenly across a duration, none of them anchored.
 *
 * The fallback when on-device recognition produced nothing to anchor against.
 * Every word is explicitly `anchored: false`, which is the honest claim: these
 * positions are a straight line through the hold, not measurements. The aligner
 * already treats anchored and interpolated words differently, so saying so is
 * enough — a binding built on these is weak and is scored as such.
 */
function spreadEvenly(text, audioDurationMs) {
  const tokens = text.split(/\s+/).filter(Boolean);
  if (!tokens.length) return [];
  const per = audioDurationMs / tokens.length;
  return tokens.map((word, i) => ({
    text: word,
    start: i * per,
    end: Math.min((i + 1) * per, audioDurationMs),
    source: "text-only",
    anchored: false,
  }));
}

// ── On-device word timings ──────────────────────────────────────────────────

/**
 * Apple's Speech framework, via the app bundle, for WORD TIMINGS.
 *
 * Sarvam gives far better Hinglish text but no usable timings — its REST API
 * returns one timestamp spanning the whole clip on every model and parameter
 * combination. So the two split the work: Sarvam says WHAT was said, Apple says
 * WHEN, and the aligner runs on Apple's clock.
 *
 * Launched with `open -n` rather than executed directly, because TCC blames the
 * RESPONSIBLE process: a binary exec'd from a terminal inherits that terminal's
 * identity (inside an IDE, that is Electron), whose Info.plist has no speech
 * usage description — and the request is killed with SIGABRT before our own
 * plist is ever read. Going through LaunchServices makes the app answer for
 * itself. `-n` forces a new instance; without it `open` silently hands the
 * request to an already-running process.
 */
async function appleTimings(wavPath, { locale = "en-IN", timeoutMs } = {}) {
  // TOLD, not derived. A shipped app runs this script from
  // `Deiko.app/Contents/Resources/scripts/`, where `REPO_ROOT` is `Resources`
  // and `Resources/build/Deiko.app` does not exist — so the guess below threw
  // on every session of every install that was not a developer's checkout, and
  // the whole product came apart at the first stage. The app knows exactly
  // where it is; it passes that in.
  const app = process.env.DEIKO_APP_PATH || resolve(REPO_ROOT, "build/Deiko.app");
  if (!existsSync(app)) {
    throw new Error(
      process.env.DEIKO_APP_PATH
        ? `DEIKO_APP_PATH points at ${app}, which is not there`
        : "build/Deiko.app is missing — run `make bundle`",
    );
  }

  // Scaled by the recording, not fixed. A flat 90s worked for every session
  // until one ran 77 seconds: on-device recognition is roughly realtime, it
  // finished at about 100s, and the script had already given up on a result that
  // was perfectly good (55 words, 70.6s span). Four times realtime plus 30s of
  // model load leaves room on the slowest machine without waiting forever on a
  // hang — and it scales with the 20-minute session ceiling instead of silently
  // capping how long a session may usefully be.
  const audioMs = wavDurationMs(wavPath);
  timeoutMs ??= Math.max(90_000, audioMs * 4 + 30_000);

  const out = `${wavPath}.timing.json`;

  // ALREADY DONE. When the app itself drives this pipeline it recognises the
  // holds in-process first — it is the process that holds the Speech grant, so
  // the LaunchServices dance below buys nothing there and costs a whole app
  // launch per hold. Read the result and skip straight past it.
  //
  // Note the ORDER: this has to come before the `rmSync` that follows, which
  // exists to clear a stale file from a previous run and would cheerfully
  // delete a freshly precomputed one.
  if (process.env.DEIKO_TIMINGS_READY === "1" && existsSync(out)) {
    return await timed("apple:precomputed", async () => {
      const result = JSON.parse(readFileSync(out, "utf8"));
      rmSync(out);
      if (result.error) throw new Error(`speech timing: ${result.error}`);
      return result;
    });
  }

  if (existsSync(out)) rmSync(out);

  // Timed apart from the recognition itself: launching a second copy of the app
  // through LaunchServices is pure overhead that disappears the moment timings
  // are produced during capture, and it should not be able to hide inside the
  // recognition number it is not part of.
  await timed("apple:launch", async () =>
    execFileSync("open", [
      "-n", "-a", app, "--args",
      "timing", "--wav", wavPath, "--locale", locale, "--out", out,
    ]));

  return await timed("apple:recognise", () => awaitTimingFile(out, { timeoutMs, audioMs }));
}

/**
 * Wait for the app to drop its timing file, and clean up if it never does.
 *
 * Split out of `appleTimings` so the wait — which IS the recognition, running at
 * roughly realtime on the finished file — can be measured on its own, apart from
 * the app launch that precedes it.
 */
async function awaitTimingFile(out, { timeoutMs, audioMs }) {
  const deadline = Date.now() + timeoutMs;
  const startedAt = Date.now();
  while (Date.now() < deadline) {
    if (existsSync(out)) {
      let result;
      try {
        result = JSON.parse(readFileSync(out, "utf8"));
      } catch {
        // The writer is atomic now, but belt-and-braces: a half-visible file
        // is "not ready yet", not "this hold is lost". One thrown parse here
        // used to discard the hold's audio entirely.
        await sleep(200);
        continue;
      }
      rmSync(out);
      if (result.error) throw new Error(`speech timing: ${result.error}`);
      return result;
    }
    // A short hold finishes in about a second, so a flat 500ms tick spent up
    // to half of the total wait doing nothing. Check often while the answer is
    // plausibly imminent, then back off so a long recording is not polled
    // thousands of times.
    await sleep(Date.now() - startedAt < 5_000 ? 100 : 500);
  }
  // The app may still write the file AFTER we stop waiting, so a single check
  // here cannot do the job — and it didn't: a timed-out run left a verbatim
  // transcript of the user's narration sitting in their session directory, which
  // is exactly what this cleanup exists to prevent. Keep sweeping for a while
  // after giving up, and say so plainly if it still appears.
  for (let i = 0; i < 60; i++) {
    if (existsSync(out)) {
      rmSync(out);
      break;
    }
    await sleep(1000);
  }
  if (existsSync(out)) {
    console.error(`⚠ could not remove ${out} — it holds a verbatim transcript. Delete it.`);
  }
  throw new Error(
    `speech timing timed out after ${Math.round(timeoutMs / 1000)}s ` +
      `for ${Math.round(audioMs / 1000)}s of audio`,
  );
}

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// ── Session driver ──────────────────────────────────────────────────────────


async function main() {
  const startedAt = performance.now();
  const sessionDir = process.argv[2];
  if (!sessionDir) {
    console.error("usage: node scripts/transcribe.mjs sessions/<id> [--language hi-IN]");
    process.exit(2);
  }

  // NO KEY IS NOT AN ERROR. It used to exit(1) here, which meant a new install
  // produced nothing at all — while the machinery for a keyless session was
  // already present and working three hundred lines below, in the path that
  // keeps Apple's words when Sarvam fails. `selectTranscriber` decides who
  // transcribes; every outcome, including nobody, renders a brief.

  // Accepts both `--language hi-IN` and `--language=hi-IN`. The indexOf form
  // alone silently ignored the `=` spelling — Sarvam then got
  // `language_code=unknown` with nothing to say the flag was dropped.
  const flag = (name, fallback) => {
    const eq = process.argv.find((a) => a.startsWith(`${name}=`));
    if (eq) return eq.slice(name.length + 1);
    const i = process.argv.indexOf(name);
    return i > -1 ? process.argv[i + 1] : fallback;
  };
  const language = flag("--language", "unknown");
  const args = { locale: flag("--locale", "en-IN") };

  const dir = resolve(sessionDir);
  const events = loadEvents(dir);
  const transcriber = selectTranscriber();
  if (transcriber.name === "on-device") {
    console.error(
      "  no transcription service — using on-device words only. "
        + "Accuracy is lower, especially for mixed-language speech."
    );
  }

  // Pair each hold's start (which carries the audio path) with its end (which
  // carries audioT0, only known once the first buffer landed). The session-level
  // `sessionStart`/`sessionEnd` pair carries no `hold` and is skipped.
  const starts = events.filter((e) => e.type === "holdStart" && e.hold != null);
  const ends = events.filter((e) => e.type === "holdEnd" && e.hold != null);

  const holds = [];
  for (const start of starts) {
    const end = ends.find((e) => e.hold === start.hold);
    if (!start.audioPath) {
      console.error(`  hold ${start.hold}: no audio recorded — skipping`);
      continue;
    }
    if (end?.audioT0 == null) {
      console.error(`  hold ${start.hold}: no audioT0 — mic never delivered a buffer, skipping`);
      continue;
    }
    holds.push({ hold: start.hold, audioPath: start.audioPath, audioT0: end.audioT0 });
  }

  if (holds.length === 0) {
    console.error("✗ no holds with usable audio");
    process.exit(1);
  }

  const allWords = [];
  const holdTexts = [];
  /// Holds that lost their on-device timings and are running on text alone.
  /// Reported at the end so a degraded session cannot pass for a normal one.
  const degradedHolds = [];
  /// Chunks the cloud never returned, across every hold. A stretch of sentence
  /// is missing for each one, so the brief must be able to say the transcript
  /// reads short rather than leaving it to look like bad recognition.
  let failedChunks = 0;

  // Per-hold cache, so extending a session costs only the new audio.
  //
  // "Forgot something?" adds a hold and re-runs this script. Without a cache
  // that re-recognises hold 1 — whose WAV has not changed and cannot change —
  // paying its full recognition time again for an identical answer, and paying
  // Sarvam for it too. Keyed on the file's byte length, which is what changes
  // when audio does.
  // Read before this run can overwrite it — see `cloudBlock`.
  let priorCloud = null;
  try {
    priorCloud = JSON.parse(readFileSync(join(dir, "transcript.json"), "utf8")).cloud ?? null;
  } catch {
    // No previous transcript, or an unreadable one. Either way there is no
    // earlier answer to preserve and this run's own is the truth.
  }

  const cachePath = join(dir, "transcript.cache.json");
  let cache = {};
  try {
    cache = JSON.parse(readFileSync(cachePath, "utf8"));
  } catch {
    // No cache, an unreadable one, or one from an older shape — all mean the
    // same thing: transcribe everything. Never fatal.
  }

  for (const { hold, audioPath, audioT0 } of holds) {
    // The event's audioPath was recorded relative to the recorder's cwd, which
    // is not necessarily ours. Resolve against cwd first (works when run from
    // the repo root, as documented), then fall back to the session directory —
    // the WAVs always live in <session>/audio/.
    let wav = resolve(audioPath);
    if (!existsSync(wav)) {
      const inSession = join(dir, "audio", audioPath.split("/").pop());
      if (existsSync(inSession)) wav = inSession;
    }

    // A DELETED RECORDING IS A CACHE HIT, NOT A MISS.
    //
    // The app removes each session's WAVs the moment the brief exists — the
    // recording of somebody's voice should not outlive its one use. But the
    // cache is keyed on the file's byte size, so a deleted WAV reads as 0,
    // misses, and sends this loop off to transcribe a file that is not there.
    // That would break "Point at more", which re-runs the whole pipeline over
    // every hold including the ones already done.
    //
    // The size check is there to notice a CHANGED recording. A deleted one can
    // never be re-transcribed, so the cached words are the only record there
    // will ever be, and they are exactly right.
    const present = existsSync(wav);
    const bytes = present ? statSync(wav).size : 0;
    const cached = cache[hold];
    // A `partial` entry is a hit only once the audio is gone — while the WAV
    // is still on disk (DEIKO_KEEP_AUDIO, or a re-render before the app's
    // sweep) it is worth another attempt at the words a refusal withheld.
    // Without the WAV the cached on-device words are the only record there
    // will ever be, and skipping the hold would throw them away.
    const usable = cached?.words?.length
      && (!present || (cached.bytes === bytes && !cached.partial));
    if (usable) {
      // Cached words are stored on the AUDIO clock, before the shift, so the
      // shift below applies identically whether they were just recognised or
      // read back. Storing them shifted would bake in an `audioT0` that a
      // re-render is entitled to recompute.
      console.error(`  hold ${hold} → cached (${cached.words.length} words)`);
      holdTexts.push({ hold, text: cached.text ?? "" });
      allWords.push(...cached.words.map((w) => ({
        text: w.text,
        start: w.start + audioT0,
        end: w.end + audioT0,
        hold,
        anchored: w.anchored === true,
      })));
      continue;
    }

    // Gone, and nothing cached to stand in for it. Say what happened rather
    // than failing later with a file-not-found from inside a recogniser.
    if (!present) {
      console.error(
        `  hold ${hold}: the recording was deleted after the brief was made, `
          + `and there is no cached transcript for it — skipping`
      );
      continue;
    }

    // Both recognisers at once. They read the same file and never read each
    // other — one is on-device, the other is a network upload — so running them
    // in sequence spent Sarvam's whole round trip waiting for work that had
    // already finished. Started together, Sarvam hides entirely inside Apple's
    // recognition.
    //
    // `allSettled`, not `all`: timings are fatal for the hold (nothing to align
    // without them) while a missing Sarvam transcript merely falls back to
    // Apple's own words. `all` would collapse that distinction into one failure.
    process.stderr.write(`  hold ${hold} → on-device timings + ${transcriber.name} text … `);
    const [timingOutcome, textOutcome] = await Promise.allSettled([
      appleTimings(wav, { locale: args.locale }),
      transcriber.transcribe(wav, { language }),
    ]);

    // A rejected hold is one lost stretch of audio, same as a rejected chunk
    // inside a long one — the short-audio path returns `uploadOne`'s object
    // directly, so a single-chunk hold that threw shows up here and nowhere
    // else. Counted before anything below can `continue` past it.
    failedChunks += textOutcome.status === "rejected"
      ? 1
      : (textOutcome.value?.failedChunks ?? 0);

    // ON-DEVICE TIMINGS FAILING IS NOT THE END OF THE HOLD.
    //
    // It used to be: this `continue`d, and the hold was discarded whole —
    // including a Sarvam transcript that had arrived perfectly. Measured on
    // session 20260801-183429: 9.8s of quiet speech (RMS -39 dBFS, recorded
    // with the system input at 27%). Apple's en-IN recogniser returned "No
    // speech detected"; Sarvam returned the full Hinglish sentence. Deiko threw
    // it away and reported "no words transcribed".
    //
    // That made a recogniser STATE.md already documents as hearing ~25% of
    // Hinglish into a hard gate on the entire session. The narration is the
    // most valuable thing a session produces — the brief says so — and losing
    // it because a SECONDARY signal failed is the wrong trade. So: keep the
    // words, spread them evenly across the hold, and mark every one unanchored.
    // Referent binding degrades (it has nothing measured to bind against) and
    // is honest about it, rather than the session evaporating.
    let timing;
    let degraded = false;
    if (timingOutcome.status === "rejected") {
      const text = textOutcome.status === "fulfilled" ? textOutcome.value?.text : null;
      if (!text) {
        console.error(`FAILED\n    ${timingOutcome.reason.message}`);
        continue;
      }
      console.error(
        `on-device FAILED (${timingOutcome.reason.message}) — keeping ${transcriber.name} text, unanchored`,
      );
      degradedHolds.push(hold);
      degraded = true;
      timing = {
        words: spreadEvenly(text, wavDurationMs(wav)),
        transcript: text,
        deliveryGapsMs: [],
      };
    } else {
      timing = timingOutcome.value;
    }
    // The widest pause between the recogniser's deliveries. It matters because
    // the app finishes a recognition that stops short by waiting out an idle
    // threshold; if this ever approaches that threshold, recognition starts
    // being cut off mid-file, and the only warning is this number creeping up.
    const widestGap = Math.max(0, ...(timing.deliveryGapsMs ?? [0]));
    if (widestGap) stages.set("apple:widest-gap", widestGap);
    console.error(`${timing.words.length} segments`);

    // A cloud transcriber for the words themselves. Best-effort: without one
    // the hold falls back to Apple's words, which mishear Hindi function words
    // but still bind English sessions fine.
    //
    // Labelled anchored HERE rather than only inside `mergeWords`. These are
    // the recogniser's own measured segments — the most anchored words that
    // exist — and every path that keeps them unmerged (no cloud text at all,
    // or a merge that found no anchors) used to hand them on with the field
    // absent, which reads as `anchored: false`. A keyless session therefore
    // reported "0 of 5 words carry a measured time" about five words whose
    // times were all measured, and the brief tells the agent to trust referent
    // binding less on exactly that signal.
    let holdWords = timing.words.map((w) => ({ ...w, anchored: true }));

    // Nothing to merge against. These words ARE the transcriber's text already,
    // laid out on a line; running the merge would compare that text with itself
    // and — worse — `mergeWords` labels its input anchored BY DEFINITION,
    // because its input is normally a measurement. That would restore the exact
    // lie this path exists to avoid: a session reporting "32/32 words carry a
    // measured time" when not one of them does.
    if (degraded) {
      holdTexts.push({ hold, text: timing.transcript });
      console.error(`  hold ${hold} → ${holdWords.length} words, times estimated across the hold`);
      cache[hold] = { bytes, words: holdWords };
      allWords.push(...holdWords.map((w) => ({
        text: w.text,
        start: w.start + audioT0,
        end: w.end + audioT0,
        hold,
        anchored: false,
      })));
      continue;
    }

    process.stderr.write(`  hold ${hold} → merging … `);
    try {
      if (textOutcome.status === "rejected") throw textOutcome.reason;
      const result = textOutcome.value;
      holdTexts.push({ hold, text: result.text });
      if (result.text) {
        const merged = await timed("merge", async () =>
          mergeWords(result.text, timing.words, wavDurationMs(wav)));
        if (merged.anchors > 0) {
          holdWords = merged.words;
          console.error(`merged ${merged.total} words (anchors ${merged.anchors}/${merged.total})`);
        } else {
          console.error(`no anchors — keeping on-device words`);
        }
        console.error(`    "${result.text.slice(0, 110)}"`);
      } else {
        console.error(`empty — keeping on-device words`);
      }
    } catch (err) {
      console.error(`failed (${err.message.slice(0, 80)}) — continuing on timings alone`);
      holdTexts.push({ hold, text: timing.transcript });
    }

    // Cached before the shift, for the same reason the shift is applied after:
    // these are offsets into this hold's audio, which is the only form that
    // stays true if the session is re-rendered later.
    //
    // A PARTIAL RESULT IS CACHED, AND MARKED. This used to skip the cache
    // after a failed or refused chunk, so that a 402 mid-session would not pin
    // degraded words forever and a network blip could heal on re-render. The
    // reasoning was sound and the outcome was data loss: the app deletes every
    // WAV the moment the brief renders, on the stated invariant that "a
    // missing WAV with cached words is a hit" — and a refused hold had no
    // cached words. Re-render after the free trial ran out mid-session and
    // that hold's on-device words were gone from the brief, at exactly the
    // moment a new user meets the trial's end. The words that exist are kept;
    // `partial` tells the read side below to try again ONLY while the audio
    // is still there to try with. A complete result is cached even when empty:
    // silence is a fact, a refusal is a circumstance.
    const partial = textOutcome.status === "rejected"
      || (textOutcome.value?.failedChunks ?? 0) > 0
      || textOutcome.value?.refused === true;
    cache[hold] = {
      bytes,
      words: holdWords,
      text: holdTexts.find((h) => h.hold === hold)?.text ?? "",
      ...(partial ? { partial: true } : {}),
    };

    // THE SHIFT. Offsets into the wav become session-clock times, so words and
    // cursor events share one timeline.
    allWords.push(...holdWords.map((w) => ({
      text: w.text,
      start: w.start + audioT0,
      end: w.end + audioT0,
      hold,
      // Carried through, not rebuilt away: this says whether `start` is a
      // measurement or a point on a line drawn between two of them.
      anchored: w.anchored === true,
    })));
  }

  allWords.sort((a, b) => a.start - b.start);

  if (allWords.length === 0) {
    // Never write an empty transcript and call it success — the next step would
    // report "alignment found nothing" for what is actually a transcription
    // failure, and the gate would be measuring the wrong thing.
    console.error("\n✗ no words transcribed — not writing transcript.json");
    process.exit(1);
  }

  /// WHAT HAPPENED TO THIS SESSION'S AUDIO — not what would happen if it ran now.
  ///
  /// STICKY, and that is the whole point. Re-running this script over a
  /// finished session is routine — "Recent sessions" reopens one, and every
  /// hold is then served from `transcript.cache.json` because the WAVs were
  /// deleted when the brief was first made. Not one byte is uploaded on that
  /// pass. Restamping `transcriber` from the CURRENT environment would then
  /// rewrite history: open a session recorded on a keyless build from a
  /// relay-stamped one and the review panel would announce "Left this Mac:
  /// ~62s of audio to Deiko's transcription" about a session that never left
  /// the machine — a false claim, produced by the feature that exists to
  /// answer that exact question.
  ///
  /// So: if nothing was uploaded this run and a previous answer is on disk,
  /// that answer stands. `uploaded` is what tells the two apart, and it also
  /// keeps the trust line honest about a relay that was never reached at all
  /// (a DNS failure never opens a socket, so it never increments).
  function cloudBlock() {
    const uploaded = transcriber.state?.uploaded ?? 0;
    if (uploaded === 0 && priorCloud) return priorCloud;
    return {
      transcriber: transcriber.name,
      uploaded,
      refused: transcriber.state?.refused ?? null,
      failedChunks,
    };
  }

  const out = join(dir, "transcript.json");
  await timed("write", async () =>
    writeFileSync(
      out,
      JSON.stringify(
        // Carried into the file, not just printed: the renderer and the orb
        // both need to be able to say that a session's word times are a
        // straight line rather than measurements, and stderr is not a channel
        // either of them can read.
        {
          words: allWords,
          holdTexts,
          // WHO PRODUCED THESE WORDS. On-device only is a real, supported way
          // to run and a materially worse transcript, so the renderer can say
          // which one the agent is reading — the same reason `degradedHolds`
          // travels rather than staying in stderr nobody reads.
          transcriber: transcriber.name,
          // WHY the transcript is what it is, for the one screen that has to
          // explain it. `refused` is the relay's own answer mapped to something
          // a user can act on (scripts/lib/cloud.mjs); `failedChunks` says the
          // words read short. The renderer turns this into one sentence — see
          // `degradedReason` — and without it a spent trial and a dead relay
          // were indistinguishable from bad recognition.
          cloud: cloudBlock(),
          ...(degradedHolds.length ? { degradedHolds } : {}),
        },
        null,
        2,
      ),
    ));
  // Best effort. A cache that cannot be written costs time on the next run and
  // nothing else — never fail a good transcript over it.
  try {
    writeFileSync(cachePath, JSON.stringify(cache));
  } catch { /* not worth reporting */ }

  const anchored = allWords.filter((w) => w.anchored).length;
  console.error(`\n✓ ${allWords.length} words on the session clock → ${out}`);
  // Anchored share, printed where the run happens. It was previously only
  // discoverable by reading the JSON, which is why a session sat at 37/223 for
  // a day without anyone noticing.
  console.error(`  anchored: ${anchored}/${allWords.length} words carry a measured time`);
  if (degradedHolds.length) {
    console.error(
      `  ⚠ hold${degradedHolds.length > 1 ? "s" : ""} ${degradedHolds.join(", ")}: on-device recognition ` +
        `heard nothing, so word times are estimated. What you said is intact; what you pointed at may bind loosely.`,
    );
  }
  console.error(timingReport(performance.now() - startedAt));
}

main().catch((err) => {
  console.error(`✗ ${err.message}`);
  process.exit(1);
});
