#!/usr/bin/env node
/**
 * Transcribe a recorded session's narration into words on the session clock.
 *
 *   node packages/core/src/transcribe.mjs sessions/<id>
 *
 * An ASR returns word times as offsets into an audio file; the aligner needs
 * them on the same monotonic clock as the cursor samples, so every word is
 * shifted by that hold's `audioT0`, the moment the first audio buffer actually
 * arrived. Skip the shift and every word sits a quarter-second early, and
 * alignment fails in a way that looks like the mechanic not working.
 *
 * The cloud recogniser is behind a one-method interface, so a provider can be
 * swapped without the aligner noticing.
 */

import { readFileSync, existsSync, rmSync, statSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { execFileSync } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

// The \p{M}-preserving normaliser from the aligner — imported, not copied,
// because the whole point of normalising here is to match what the aligner
// will match on.
import { normalizeWord } from "@deiko/alignment/deictic";
import { awaitPrecomputed, loadEvents, writeAtomic } from "./lib/session-io.mjs";
import { refusalReason, REFUSAL_IS_FINAL, withOneRetry } from "./lib/cloud.mjs";


// ── Stage timing ──
//
// Recognition runs on the finished file at roughly realtime, so for a long
// session it dominates everything else. Timings are printed so a change that
// claims to speed transcription up has to move these numbers.
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

// ── The interface ──

/**
 * @typedef {{ name: string, transcribe: (wavPath: string, opts: {language?: string}) => Promise<{text: string}> }} Transcriber
 */

/**
 * Long holds are split into chunks that upload concurrently, and the whole
 * cloud call runs alongside on-device recognition rather than after it, so it
 * costs nothing on the clock. Chunking also means a failed chunk costs its own
 * stretch of sentence rather than the whole hold.
 */
const CHUNK_SECONDS = 25;
const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;

/// How many chunks may be in flight at once. Four, because the relay's Lambda
/// reserves five concurrent executions (`services/relay/deploy.sh`): a long
/// session fired all at once throttles against that reservation, and one
/// throttled chunk would lose the whole session's cloud text. Staying under it
/// makes the fallback rare rather than routine.
const UPLOAD_CONCURRENCY = 4;

/// "Same as I speak" (Settings → Brief language). Whisper writes down what it
/// heard, in that language, with its own word timestamps, and those times are
/// the timeline instead of Apple's English recogniser's. The default translates
/// to English and matches against Apple's timeline, which is the right design
/// for Hinglish (see `mergeWords`).
const NATIVE = process.env.DEIKO_NARRATION === "native";

/// A stalled upload should cost one chunk, not the session. Without a signal
/// `fetch` falls through to undici's ~300s default, which is five minutes of an
/// orb reading "Transcribing…". Sixty seconds matches the relay's own Lambda
/// timeout: past that there is nothing coming.
const UPLOAD_TIMEOUT_MS = 60_000;

/**
 * The chunking half, shared by every network transcriber: splitting long audio
 * at silence and uploading the pieces concurrently is the same problem whoever
 * is on the other end, so `uploadOne` is the only part that differs.
 *
 * `state` is the transcriber's own scratchpad, shared with `uploadOne` and read
 * back by the caller once every hold is done. Today it carries why the relay
 * refused, a fact about the session rather than any one chunk.
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

      const upload = (data) => withOneRetry((last) => uploadOne(data, language, { last }));
      if (totalSeconds <= CHUNK_SECONDS) {
        return timed(name, () => upload(pcm));
      }

      const chunks = splitAtSilence(pcm, CHUNK_SECONDS);
      process.stderr.write(`(${totalSeconds.toFixed(0)}s → ${chunks.length} chunks) `);

      // Concurrently, but in slices, never all at once: firing every chunk at
      // once throttles against the relay's reserved concurrency (see
      // `UPLOAD_CONCURRENCY`), and under a plain `Promise.all` one throttled
      // chunk would reject the whole session. `allSettled` per slice is the
      // other half: a chunk that still fails costs its own stretch of sentence,
      // and the failures are reported so the brief can say it reads short.
      const parts = [];
      const failures = [];
      await timed(name, async () => {
        for (let i = 0; i < chunks.length; i += UPLOAD_CONCURRENCY) {
          const slice = chunks.slice(i, i + UPLOAD_CONCURRENCY);
          const settled = await Promise.allSettled(
            slice.map(upload));
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
      // Each chunk's times start at its own zero. Walk the chunk lengths to put
      // them on the hold's clock before anything downstream sees them.
      let offsetMs = 0;
      const shifted = parts.map((p, i) => {
        const at = offsetMs;
        offsetMs += (chunks[i].length / (SAMPLE_RATE * BYTES_PER_SAMPLE)) * 1000;
        const shift = (xs) => (xs ?? []).map((x) => ({ ...x, start: x.start + at, end: x.end + at }));
        return { ...p, segments: shift(p.segments), words: shift(p.words) };
      });
      return {
        text: shifted.map((p) => p.text).filter(Boolean).join(" "),
        language: shifted.find((p) => p.language)?.language ?? null,
        segments: shifted.flatMap((p) => p.segments),
        words: shifted.flatMap((p) => p.words),
        failedChunks: failures.length,
        // Carried up so the cache can tell a refused stretch from silence.
        refused: parts.some((p) => p.refused),
      };
    },
  };
}

/// The multipart body both Groq and the relay accept.
///
/// Translation, not transcription: `/audio/translations` always answers in
/// English, while `/transcriptions` on Hinglish returns Devanagari, which
/// cannot match the Latin tokens of the on-device timeline, so the merge would
/// have nothing to bind screenshots with. A user who speaks English gets plain
/// transcription (there is nothing to translate); one who code-switches gets
/// clean English. The review window says so where the narration is shown.
///
/// `language` is sent only in "Same as I speak" mode, because the translation
/// endpoint takes no language hint; it stays in the signature because
/// `chunkedTranscriber` passes it to every uploader.
function sttForm(pcm, language) {
  const form = new FormData();
  form.append("file", new Blob([wrapWav(pcm)], { type: "audio/wav" }), "audio.wav");
  // large-v3, not turbo: turbo is cheaper but cannot translate, and
  // translation is the whole point of the endpoint below.
  form.append("model", "whisper-large-v3");
  // `verbose_json` carries the segments with their times on both endpoints, and
  // the words on transcription.
  form.append("response_format", "verbose_json");
  if (NATIVE) {
    form.append("timestamp_granularities[]", "word");
    form.append("timestamp_granularities[]", "segment");
    if (language && language !== "unknown") form.append("language", language.split("-")[0]);
  }
  return form;
}

/// The developer's own Groq key: their key, their bill, nothing in between.
/// One key covers both the audio and the summary, which is what makes the
/// promise in Settings true: bringing it takes Deiko's servers out of the path.
///
/// `translate` is the shipped behaviour; `false` is for comparing the
/// alternative.
function groqTranscriber(apiKey, model = "whisper-large-v3", { translate = !NATIVE } = {}) {
  return chunkedTranscriber(`groq:${model}${translate ? ":translate" : ""}`, async (pcm, language) => {
    const form = new FormData();
    form.append("file", new Blob([wrapWav(pcm)], { type: "audio/wav" }), "audio.wav");
    form.append("model", model);
    form.append("response_format", "verbose_json");
    if (!translate) {
      form.append("timestamp_granularities[]", "word");
      form.append("timestamp_granularities[]", "segment");
    }
    // The language hint costs nothing and stops Whisper guessing on a short
    // clip. `unknown` means "decide for yourself", which is what a mixed
    // session wants. The translation endpoint takes no language: its output is
    // always English, which is the point of using it.
    if (!translate && language && language !== "unknown") {
      form.append("language", language.split("-")[0]);
    }

    const response = await fetch(
      `https://api.groq.com/openai/v1/audio/${translate ? "translations" : "transcriptions"}`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${apiKey}` },
        body: form,
        signal: AbortSignal.timeout(UPLOAD_TIMEOUT_MS),
      });

    const bodyText = await response.text();
    if (!response.ok) {
      throw new Error(`Groq ${response.status}: ${bodyText.slice(0, 400)}`);
    }
    try {
      return extractResult(JSON.parse(bodyText));
    } catch {
      throw new Error(`Groq returned non-JSON: ${bodyText.slice(0, 400)}`);
    }
  });
}

/**
 * Deiko's relay: the default, so a new user transcribes without holding an
 * account anywhere. The audio goes to Deiko's server, which forwards it and
 * keeps nothing: a materially different promise from "only to Groq", which the
 * app states before people start. Their own key skips this entirely.
 */
function relayTranscriber(endpoint, token) {
  // The relay picks the Groq endpoint from this query, not from a form field:
  // it rebuilds the multipart body from an allowlist and refuses anything
  // else. What reaches Groq is exactly what `sttForm` sends — the audio, the
  // model, `response_format`, and for "Same as I speak" the timestamp
  // granularities and the language.
  const url = `${endpoint.replace(/\/+$/, "")}/v1/transcribe${NATIVE ? "?task=transcribe" : ""}`;

  // Some refusals answer for the whole session, and some are worth retrying.
  // A spent trial, a spent month and the daily ceiling are facts about the
  // account or the day, so every later chunk would hear the same thing: stop
  // uploading, ride on Apple's on-device words (the fallback quota.mjs
  // documents), and do not count it as a failure. A rate limit or a 503 is not
  // such a fact: the relay's limiter allows 30 requests a minute per token
  // (services/relay/src/relay.mjs), so a burst 429 partway through a long
  // recording is plausible and temporary. It throws like any other chunk
  // failure and the next chunk tries again. `REFUSAL_IS_FINAL` is where that
  // distinction lives.
  //
  // `state.refused` is remembered either way, and the first reason wins: "your
  // trial is used up" outranks the rate limit that followed it.
  const state = { refused: null, uploaded: 0 };
  return chunkedTranscriber("deiko", async (pcm, language, { last = true } = {}) => {
    if (state.refused && REFUSAL_IS_FINAL.has(state.refused)) {
      return { text: "", refused: true };
    }

    let response;
    let bodyText;
    try {
      // Counted before the await, because the bytes are on the wire either way:
      // the review window has to be able to say whether audio left this Mac,
      // and a request that was sent and then refused still left it. A DNS
      // failure that never opened a socket does not reach here, which is the
      // distinction the trust line needs.
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
      // Only on the last try: one the retry rescues was never unavailable.
      if (last) state.refused ??= refusalReason(0);
      throw err;
    }

    const reason = refusalReason(response.status, bodyText);
    if (reason) {
      if (last || REFUSAL_IS_FINAL.has(reason)) state.refused ??= reason;
      if (REFUSAL_IS_FINAL.has(reason)) {
        process.stderr.write(`· ${REFUSAL_NOTE[reason]} — continuing on on-device words `);
        return { text: "", refused: true };
      }
      throw new Error(`Deiko relay ${response.status}: ${bodyText.slice(0, 400)}`);
    }

    try {
      return extractResult(JSON.parse(bodyText));
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
 * Nobody on the other end, which is a supported way to run.
 *
 * Returning empty text rather than throwing makes this a configuration rather
 * than a branch: the merge step below already handles "no cloud words, keep
 * the on-device ones". The words and their timings both come from Apple, and
 * the session is intact.
 */
function onDeviceOnlyTranscriber() {
  return { name: "on-device", async transcribe() { return { text: "" }; } };
}

/**
 * Who transcribes, most specific first.
 *
 * 1. the developer's own Groq key — an explicit choice, so it wins, and one
 *    key covers both the words and the summary;
 * 2. Deiko's relay — the default, and the reason a new install needs no key;
 * 3. on-device only — offline, or nothing configured. Degraded, not broken.
 */
function selectTranscriber() {
  if (process.env.GROQ_API_KEY) return groqTranscriber(process.env.GROQ_API_KEY);
  if (process.env.DEIKO_RELAY_URL) {
    return relayTranscriber(process.env.DEIKO_RELAY_URL, process.env.DEIKO_RELAY_TOKEN);
  }
  return onDeviceOnlyTranscriber();
}

/**
 * Split PCM into chunks at the quietest point near each boundary rather than at
 * a fixed offset: a fixed cut lands mid-word roughly as often as not, and a
 * word sliced in half is dropped or mis-transcribed at every boundary.
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

/// What a Whisper answer contributes, in one shape for both endpoints and both
/// response formats. Times come back in seconds from the start of the audio
/// that was sent — a chunk, not the hold — and leave here in milliseconds;
/// `chunkedTranscriber` shifts them onto the hold.
function extractResult(raw) {
  const ms = (v) => Math.round(Number(v ?? 0) * 1000);
  const clean = (t) => String(t ?? "").trim();
  return {
    text: clean(raw?.text),
    language: raw?.language ? String(raw.language) : null,
    segments: (raw?.segments ?? [])
      .map((x) => ({ start: ms(x.start), end: ms(x.end), text: clean(x.text) }))
      .filter((x) => x.text),
    words: (raw?.words ?? [])
      .map((x) => ({ start: ms(x.start), end: ms(x.end), text: clean(x.word) }))
      .filter((x) => x.text),
  };
}

/// The cloud's words on the cloud's own timeline, best measurement first:
/// Whisper's words when it was asked for them, its segments otherwise, and an
/// even spread only when it gave no times at all.
function timeFromCloud(cloud, audioDurationMs) {
  if (cloud.words?.length) {
    return cloud.words.map((w) => ({ ...w, source: "whisper", anchored: true }));
  }
  if (cloud.segments?.length) {
    return cloud.segments.flatMap((seg) => {
      const tokens = seg.text.split(/\s+/).filter(Boolean);
      const per = (seg.end - seg.start) / Math.max(tokens.length, 1);
      return tokens.map((word, i) => ({
        text: word,
        start: seg.start + i * per,
        end: seg.start + (i + 1) * per,
        source: "segment",
        anchored: false,
      }));
    });
  }
  return spreadEvenly(cloud.text, audioDurationMs);
}

// ── The anchor merge ──

/**
 * Put the cloud's words (right text, no times) onto Apple's timeline (wrong
 * text, real times).
 *
 * Both recognisers heard the same audio, so their token sequences are two noisy
 * views of one utterance, monotonic in time. The tokens they agree on become
 * anchors via longest-common-subsequence (so anchors can never cross), and
 * cloud tokens between two anchors are spread evenly across the gap. The
 * binding window is ±1.5s, so that is good enough.
 *
 * The anchor count is how this is judged: Whisper asked to transcribe Hinglish
 * returns Devanagari and anchors almost nothing, which is why the shipped path
 * translates instead.
 */
function mergeWords(cloudText, appleWords, audioDurationMs) {
  // Apple's own segments are measurements, so they are anchored by definition.
  // Labelling them keeps `anchored` meaning the same thing on every path: an
  // absent field would be indistinguishable from "not anchored".
  const asAnchored = (ws) => ws.map((w) => ({ ...w, anchored: true }));

  const sTokens = cloudText.split(/\s+/).filter((t) => normalizeWord(t).length > 0);
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

  // Which words carry a real timing and which were interpolated between two.
  // It is also the confidence signal the aligner needs: a binding resting on an
  // anchored word stands on a measurement, one resting on an interpolated word
  // stands on a straight line between two distant measurements, and those are
  // not equally trustworthy.
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
 * Words spread evenly across a duration, none of them anchored: the fallback
 * when on-device recognition produced nothing to anchor against. `anchored:
 * false` is the honest claim, since these positions are a straight line
 * through the hold, and a binding built on them is scored as weak.
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

// ── On-device word timings ──

/**
 * Apple's Speech framework, via the app bundle, for word timings.
 *
 * The cloud gives better text but no usable word timings, so the cloud says
 * what was said, Apple says when, and the aligner runs on Apple's clock.
 *
 * Launched with `open -n` rather than executed directly, because TCC blames the
 * responsible process: a binary exec'd from a terminal inherits that terminal's
 * identity (inside an IDE, Electron), whose Info.plist has no speech usage
 * description, and the request is killed with SIGABRT. Going through
 * LaunchServices makes the app answer for itself. `-n` forces a new instance;
 * without it `open` silently hands the request to an already-running process.
 */
async function appleTimings(wavPath, { locale = "en-IN", timeoutMs, contextFile } = {}) {
  // Told, not derived: a shipped app runs this script from
  // `Deiko.app/Contents/Resources/scripts/`, where `REPO_ROOT` is `Resources`
  // and `Resources/build/Deiko.app` does not exist. The app knows where it is
  // and passes it in.
  const app = process.env.DEIKO_APP_PATH || resolve(REPO_ROOT, "build/Deiko.app");
  if (!existsSync(app)) {
    throw new Error(
      process.env.DEIKO_APP_PATH
        ? `DEIKO_APP_PATH points at ${app}, which is not there`
        : "build/Deiko.app is missing — run `make bundle`",
    );
  }

  // Scaled by the recording, not fixed: on-device recognition is roughly
  // realtime, so a flat timeout gives up on long sessions. Four times realtime
  // plus 30s of model load leaves room on the slowest machine without waiting
  // forever on a hang, and scales with the 20-minute session ceiling.
  const audioMs = wavDurationMs(wavPath);
  timeoutMs ??= Math.max(90_000, audioMs * 4 + 30_000);

  const out = `${wavPath}.timing.json`;

  // When the app itself drives this pipeline it recognises the holds
  // in-process (it holds the Speech grant) while this uploads, so wait for its
  // file here instead of launching a second copy of the app; a hold it
  // finished without falls through to launching. This has to come before the
  // `rmSync` below, which clears a stale file and would delete a freshly
  // precomputed one.
  if (process.env.DEIKO_TIMINGS_PENDING === "1") {
    const ready = await timed("apple:precomputed", () => awaitPrecomputed(out, { deadline: Date.now() + timeoutMs }));
    if (ready) {
      const result = JSON.parse(readFileSync(out, "utf8"));
      rmSync(out);
      if (result.error) throw new Error(`speech timing: ${result.error}`);
      return result;
    }
  }

  if (existsSync(out)) rmSync(out);

  // Timed apart from the recognition itself: launching a second copy of the app
  // through LaunchServices is pure overhead that disappears once timings are
  // produced during capture, and it should not hide inside the recognition
  // number.
  await timed("apple:launch", async () =>
    execFileSync("open", [
      "-n", "-a", app, "--args",
      "timing", "--wav", wavPath, "--locale", locale, "--out", out,
      // Vocabulary hints, only when the caller has some; the pipeline passes
      // none.
      ...(contextFile ? ["--context", contextFile] : []),
    ]));

  return await timed("apple:recognise", () => awaitTimingFile(out, { timeoutMs, audioMs }));
}

/**
 * Wait for the app to drop its timing file, and clean up if it never does.
 *
 * Split out of `appleTimings` so the wait, which is the recognition itself
 * running at roughly realtime on the finished file, can be measured apart from
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
        // The writer is atomic, but a half-visible file is "not ready yet", not
        // "this hold is lost".
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
  // The app may still write the file after this script stops waiting, so a single check
  // here cannot do the job, and a timed-out run would leave a verbatim
  // transcript of the user's narration in their session directory. Keep
  // sweeping for a while after giving up, and say so plainly if it still
  // appears.
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

// ── Session driver ──


async function main() {
  const startedAt = performance.now();
  const sessionDir = process.argv[2];
  if (!sessionDir) {
    console.error("usage: node packages/core/src/transcribe.mjs sessions/<id> [--language hi-IN]");
    process.exit(2);
  }

  // No key is not an error: `selectTranscriber` decides who transcribes, and
  // every outcome, including nobody, renders a brief.

  // Accepts both `--language hi-IN` and `--language=hi-IN`.
  const flag = (name, fallback) => {
    const eq = process.argv.find((a) => a.startsWith(`${name}=`));
    if (eq) return eq.slice(name.length + 1);
    const i = process.argv.indexOf(name);
    return i > -1 ? process.argv[i + 1] : fallback;
  };
  const language = flag("--language", "unknown");
  // Settings → offline recogniser, via the app's environment; `en-IN` when
  // unset.
  const args = { locale: flag("--locale", process.env.DEIKO_SPEECH_LOCALE || "en-IN") };

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

  // Per-hold cache, so extending a session costs only the new audio:
  // "Forgot something?" adds a hold and re-runs this script, and hold 1's WAV
  // cannot have changed, so re-recognising it would pay its full recognition
  // time again for an identical answer. Keyed on the file's byte length, which
  // is what changes when audio does. Read before this run can overwrite it (see
  // `cloudBlock`).
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

    // A deleted recording is a cache hit, not a miss. The app removes each
    // session's WAVs once the brief exists, but the cache is keyed on file
    // size, so a deleted WAV would read as 0, miss, and send this loop off to
    // transcribe a file that is not there (breaking "Point at more", which
    // re-runs every hold). A deleted recording can never be re-transcribed, so
    // the cached words are the only record.
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
      // Cached words are stored on the audio clock, before the shift, so the
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

    // Both recognisers at once: they read the same file and never read each
    // other, so the upload hides inside Apple's recognition. `allSettled`, not
    // `all`: timings are fatal for the hold (nothing to align without them)
    // while a missing cloud transcript merely falls back to Apple's own words.
    process.stderr.write(`  hold ${hold} → on-device timings + ${transcriber.name} text … `);
    const [timingOutcome, textOutcome] = await Promise.allSettled([
      appleTimings(wav, { locale: args.locale }),
      transcriber.transcribe(wav, { language }),
    ]);

    // A rejected hold is one lost stretch of audio, same as a rejected chunk
    // inside a long one: the short-audio path returns `uploadOne`'s object
    // directly, so a single-chunk hold that threw shows up here and nowhere
    // else. Counted before anything below can `continue` past it.
    failedChunks += textOutcome.status === "rejected"
      ? 1
      : (textOutcome.value?.failedChunks ?? 0);

    // On-device timings failing is not the end of the hold. Discarding it whole
    // would throw away a cloud transcript that arrived perfectly (Apple's
    // recogniser can return "No speech detected" for quiet speech the cloud
    // transcribes fine), and the narration is the most valuable thing a session
    // produces. So keep the words, spread them evenly across the hold, and mark
    // every one unanchored: referent binding degrades, honestly, rather than
    // the session evaporating.
    let timing;
    let degraded = false;
    if (timingOutcome.status === "rejected") {
      const text = textOutcome.status === "fulfilled" ? textOutcome.value?.text : null;
      if (!text) {
        console.error(`FAILED\n    ${timingOutcome.reason.message}`);
        continue;
      }
      // Whether the words are still timed depends on whether the cloud timed
      // them. With "Same as I speak" Whisper sends word timestamps, and an
      // Apple failure costs nothing but the fallback; without them the words
      // are placed by segment or spread evenly, and that is degraded.
      const cloud = textOutcome.value;
      const measured = (cloud.words?.length ?? 0) > 0;
      console.error(
        `on-device FAILED (${timingOutcome.reason.message}) — keeping ${transcriber.name} text`
          + (measured ? ", on its own word times" : ", unanchored"),
      );
      if (!measured) {
        degradedHolds.push(hold);
        degraded = true;
      }
      timing = {
        words: timeFromCloud(cloud, wavDurationMs(wav)),
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
    // Labelled anchored here rather than only inside `mergeWords`: these are
    // the recogniser's own measured segments, and every path that keeps them
    // unmerged would otherwise hand them on with the field absent, which reads
    // as `anchored: false` and makes the brief tell the agent to trust
    // referent binding less than it should.
    let holdWords = timing.words.map((w) => ({ ...w, anchored: true }));

    // Nothing to merge against. These words are the transcriber's text already,
    // laid out on a line; running the merge would compare that text with itself
    // and, worse, `mergeWords` labels its input anchored by definition, because
    // its input is normally a measurement. That would report "32/32 words carry
    // a measured time" when not one of them does.
    if (degraded) {
      holdTexts.push({ hold, text: timing.transcript });
      console.error(`  hold ${hold} → ${holdWords.length} words, times ${holdWords.some((w) => w.source === "segment") ? "from the cloud's segments" : "estimated across the hold"}`);
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

    const cloud = textOutcome.status === "fulfilled" ? textOutcome.value : null;

    if (NATIVE && cloud?.words?.length) {
      // "Same as I speak": Whisper's words on Whisper's clock, and no merge.
      // There is nothing for Apple's recogniser to anchor (a Chinese transcript
      // shares no token with an English timeline) and no need: word timestamps
      // come back with the text. Apple's words stay the fallback for the holds
      // the cloud did not answer.
      holdWords = timeFromCloud(cloud, wavDurationMs(wav));
      holdTexts.push({ hold, text: cloud.text });
      console.error(
        `  hold ${hold} → ${holdWords.length} words timed by ${transcriber.name}`
          + `${cloud.language ? ` (${cloud.language})` : ""}`);
      console.error(`    "${cloud.text.slice(0, 110)}"`);
    } else {
    process.stderr.write(`  hold ${hold} → merging … `);
    try {
      if (textOutcome.status === "rejected") throw textOutcome.reason;
      holdTexts.push({ hold, text: cloud.text });
      if (cloud.text) {
        const merged = await timed("merge", async () =>
          mergeWords(cloud.text, timing.words, wavDurationMs(wav)));
        if (merged.anchors > 0) {
          holdWords = merged.words;
          console.error(`merged ${merged.total} words (anchors ${merged.anchors}/${merged.total})`);
        } else {
          // Nothing agreed: keep the cloud's words anyway. The cloud text is
          // still the right text (Apple's English recogniser mishears Chinese,
          // and the translation shares no token with it), and Whisper's own
          // segment times place the words to within a second or two, inside the
          // ±1.5s binding window.
          holdWords = timeFromCloud(cloud, wavDurationMs(wav));
          if (!cloud.segments?.length) degradedHolds.push(hold);
          console.error(
            `no anchors — keeping ${transcriber.name}'s words, times `
              + `${cloud.segments?.length ? "from its segments" : "estimated across the hold"}`);
        }
        console.error(`    "${cloud.text.slice(0, 110)}"`);
      } else {
        console.error(`empty — keeping on-device words`);
      }
    } catch (err) {
      console.error(`failed (${err.message.slice(0, 80)}) — continuing on timings alone`);
      holdTexts.push({ hold, text: timing.transcript });
    }
    }

    // Cached before the shift: these are offsets into this hold's audio, the
    // only form that stays true if the session is re-rendered later.
    //
    // A partial result is cached, and marked. The app deletes every WAV once
    // the brief renders, so a refused hold with no cached words would lose its
    // on-device words on re-render. `partial` tells the read side to retry only
    // while the audio is still there. A complete result is cached even when
    // empty: silence is a fact, a refusal is a circumstance.
    const partial = textOutcome.status === "rejected"
      || (textOutcome.value?.failedChunks ?? 0) > 0
      || textOutcome.value?.refused === true;
    cache[hold] = {
      bytes,
      words: holdWords,
      text: holdTexts.find((h) => h.hold === hold)?.text ?? "",
      ...(partial ? { partial: true } : {}),
    };

    // The shift. Offsets into the wav become session-clock times, so words and
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
    // Never write an empty transcript and call it success: the next step would
    // report "alignment found nothing" for what is a transcription failure.
    console.error("\n✗ no words transcribed — not writing transcript.json");
    process.exit(1);
  }

  // What happened to this session's audio, not what would happen if it ran
  // now. Re-running this script over a finished session is routine, and every
  // hold is then served from `transcript.cache.json`, so nothing is uploaded;
  // restamping `transcriber` from the current environment would rewrite
  // history (e.g. claim audio went to the relay for a session that never left
  // the machine). So if nothing was uploaded this run and a previous answer is
  // on disk, that answer stands. `uploaded` tells the two apart.
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
    writeAtomic(
      out,
      JSON.stringify(
        // Carried into the file, not just printed: the renderer and the orb
        // both need to say that a session's word times are a straight line
        // rather than measurements, and stderr is not a channel either can read.
        {
          words: allWords,
          holdTexts,
          // Who produced these words. On-device only is a supported way to run
          // and a materially worse transcript, so the renderer can say which one
          // the agent is reading.
          transcriber: transcriber.name,
          // Why the transcript is what it is, for the one screen that has to
          // explain it. `refused` is the relay's own answer mapped to something
          // a user can act on (packages/core/src/lib/cloud.mjs); `failedChunks`
          // says the words read short. The renderer turns this into one
          // sentence (see `degradedReason`).
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
    writeAtomic(cachePath, JSON.stringify(cache));
  } catch { /* not worth reporting */ }

  const anchored = allWords.filter((w) => w.anchored).length;
  console.error(`\n✓ ${allWords.length} words on the session clock → ${out}`);
  // Anchored share, printed where the run happens.
  console.error(`  anchored: ${anchored}/${allWords.length} words carry a measured time`);
  if (degradedHolds.length) {
    console.error(
      `  ⚠ hold${degradedHolds.length > 1 ? "s" : ""} ${degradedHolds.join(", ")}: nothing measured these ` +
        `word times, so they are estimated. What you said is intact; what you pointed at may bind loosely.`,
    );
  }
  console.error(timingReport(performance.now() - startedAt));
}

/// Run only when run, so this file can also be imported: a bare `main()` call
/// would make importing it transcribe a session as a side effect.
const invokedDirectly = process.argv[1]
  && resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (invokedDirectly) {
  main().catch((err) => {
    console.error(`✗ ${err.message}`);
    process.exit(1);
  });
}

export { appleTimings, groqTranscriber, mergeWords, wavDurationMs };
