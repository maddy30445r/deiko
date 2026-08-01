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

/** @returns {Transcriber} */
function sarvamTranscriber(apiKey) {
  return {
    name: "sarvam",
    async transcribe(wavPath, { language = "unknown" } = {}) {
      const file = readFileSync(wavPath);
      const pcm = file.subarray(44);
      const totalSeconds = pcm.length / (SAMPLE_RATE * BYTES_PER_SAMPLE);

      if (totalSeconds <= CHUNK_SECONDS) {
        return timed("sarvam", () => this._one(pcm, language));
      }

      const chunks = splitAtSilence(pcm, CHUNK_SECONDS);
      process.stderr.write(`(${totalSeconds.toFixed(0)}s → ${chunks.length} chunks) `);

      // Concurrently, not one after another. The chunks are independent uploads
      // of a recording that already exists — waiting for each round trip before
      // starting the next spent four times one chunk's latency to no purpose.
      // `Promise.all` preserves order, which the join below depends on: these
      // are consecutive stretches of one sentence, not a set.
      const parts = await timed("sarvam", () =>
        Promise.all(chunks.map((data) => this._one(data, language))));
      return { text: parts.map((p) => p.text).filter(Boolean).join(" ") };
    },

    async _one(pcm, language) {
      const audio = wrapWav(pcm);
      const form = new FormData();
      form.append("file", new Blob([audio], { type: "audio/wav" }), "audio.wav");
      form.append("model", "saaras:v3");
      // `translit` returns Latin script — "Yeh jo data hai ismein taxonomy ke
      // andar board ka naam" — matching the on-device timings and the Latin
      // half of the deictic lexicon. `codemix` returns Devanagari for the same
      // audio, which the lexicon also handles but which reads worse in a plan.
      form.append("mode", "translit");
      form.append("language_code", language);

      const response = await fetch(SARVAM_STT_URL, {
        method: "POST",
        headers: { "api-subscription-key": apiKey },
        body: form,
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
    },
  };
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
  // `Fovea.app/Contents/Resources/scripts/`, where `REPO_ROOT` is `Resources`
  // and `Resources/build/Fovea.app` does not exist — so the guess below threw
  // on every session of every install that was not a developer's checkout, and
  // the whole product came apart at the first stage. The app knows exactly
  // where it is; it passes that in.
  const app = process.env.FOVEA_APP_PATH || resolve(REPO_ROOT, "build/Fovea.app");
  if (!existsSync(app)) {
    throw new Error(
      process.env.FOVEA_APP_PATH
        ? `FOVEA_APP_PATH points at ${app}, which is not there`
        : "build/Fovea.app is missing — run `make bundle`",
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
  if (process.env.FOVEA_TIMINGS_READY === "1" && existsSync(out)) {
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

  const apiKey = process.env.SARVAM_API_KEY;
  if (!apiKey) {
    console.error("✗ SARVAM_API_KEY is not set. Copy .env.example to .env and fill it in,");
    console.error("  then run:  export $(grep -v '^#' .env | xargs)");
    process.exit(1);
  }

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
  const transcriber = sarvamTranscriber(apiKey);

  // Pair each hold's start (which carries the audio path) with its end (which
  // carries audioT0, only known once the first buffer landed).
  //
  // `sessionStart`/`sessionEnd` are accepted as well as `holdStart`/`holdEnd`:
  // holds used to be called sessions, and every session recorded before the
  // rename is still perfectly good data we do not want to strand. The `hold`
  // field is what tells them apart — a real session event has none.
  const isHold = (e, phase) =>
    (e.type === `hold${phase}` || e.type === `session${phase}`) && e.hold != null;
  const starts = events.filter((e) => isHold(e, "Start"));
  const ends = events.filter((e) => isHold(e, "End"));

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

  // Per-hold cache, so extending a session costs only the new audio.
  //
  // "Forgot something?" adds a hold and re-runs this script. Without a cache
  // that re-recognises hold 1 — whose WAV has not changed and cannot change —
  // paying its full recognition time again for an identical answer, and paying
  // Sarvam for it too. Keyed on the file's byte length, which is what changes
  // when audio does.
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

    const bytes = existsSync(wav) ? statSync(wav).size : 0;
    const cached = cache[hold];
    if (cached?.bytes === bytes && cached.words?.length) {
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

    // ON-DEVICE TIMINGS FAILING IS NOT THE END OF THE HOLD.
    //
    // It used to be: this `continue`d, and the hold was discarded whole —
    // including a Sarvam transcript that had arrived perfectly. Measured on
    // session 20260801-183429: 9.8s of quiet speech (RMS -39 dBFS, recorded
    // with the system input at 27%). Apple's en-IN recogniser returned "No
    // speech detected"; Sarvam returned the full Hinglish sentence. Fovea threw
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

    // Sarvam for the words themselves. Best-effort: without it the hold falls
    // back to Apple's words, which mishear Hindi function words but still bind
    // English sessions fine.
    let holdWords = timing.words;

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
    cache[hold] = {
      bytes,
      words: holdWords,
      text: holdTexts.find((h) => h.hold === hold)?.text ?? "",
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

  const out = join(dir, "transcript.json");
  await timed("write", async () =>
    writeFileSync(
      out,
      JSON.stringify(
        // Carried into the file, not just printed: the renderer and the orb
        // both need to be able to say that a session's word times are a
        // straight line rather than measurements, and stderr is not a channel
        // either of them can read.
        { words: allWords, holdTexts, ...(degradedHolds.length ? { degradedHolds } : {}) },
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
