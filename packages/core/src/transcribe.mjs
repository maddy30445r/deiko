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

const SARVAM_STT_URL = "https://api.sarvam.ai/speech-to-text";

// ── The interface ───────────────────────────────────────────────────────────

/**
 * @typedef {{ name: string, transcribe: (wavPath: string, opts: {language?: string}) => Promise<{text: string}> }} Transcriber
 */

/**
 * Sarvam's REST endpoint rejects anything over 30 seconds ("please use the
 * batch API"), and the batch API returns chunk-level timestamps only — useless
 * for binding individual words to pointing events. So split long holds here.
 *
 * Production will use the streaming WebSocket API instead, which has no such
 * limit and gives partials during capture (PRD §9's latency budget assumes
 * exactly that). This is the gate harness, not the shipping path.
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
        return this._one(pcm, language);
      }

      const chunks = splitAtSilence(pcm, CHUNK_SECONDS);
      process.stderr.write(`(${totalSeconds.toFixed(0)}s → ${chunks.length} chunks) `);

      const texts = [];
      for (const data of chunks) {
        const part = await this._one(data, language);
        if (part.text) texts.push(part.text);
      }
      return { text: texts.join(" ") };
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
  const sTokens = sarvamText.split(/\s+/).filter((t) => normalizeWord(t).length > 0);
  if (sTokens.length === 0 || appleWords.length === 0) {
    return { words: appleWords, anchors: 0, total: sTokens.length };
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
    return { words: appleWords, anchors: 0, total: n };
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

  const words = sTokens.map((text, i) => ({
    text,
    start: times[i],
    end: Math.min(times[i] + 300, times[i + 1] ?? times[i] + 300),
    source: "merged",
  }));
  return { words, anchors: anchors.length, total: n };
}

/** 16kHz mono 16-bit PCM: duration falls straight out of the byte count. */
function wavDurationMs(wavPath) {
  return ((statSync(wavPath).size - 44) / (SAMPLE_RATE * BYTES_PER_SAMPLE)) * 1000;
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
async function appleTimings(wavPath, { locale = "en-IN", timeoutMs = 90_000 } = {}) {
  const app = resolve(REPO_ROOT, "build/Fovea.app");
  if (!existsSync(app)) {
    throw new Error("build/Fovea.app is missing — run `make bundle`");
  }

  const out = `${wavPath}.timing.json`;
  if (existsSync(out)) rmSync(out);

  execFileSync("open", [
    "-n", "-a", app, "--args",
    "timing", "--wav", wavPath, "--locale", locale, "--out", out,
  ]);

  const deadline = Date.now() + timeoutMs;
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
    await sleep(500);
  }
  // The app may still write the file after we stop waiting. Don't leave a
  // verbatim transcript of the user's narration lying around unmanaged.
  if (existsSync(out)) rmSync(out);
  throw new Error(`speech timing timed out after ${timeoutMs / 1000}s`);
}

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// ── Session driver ──────────────────────────────────────────────────────────

function loadEvents(sessionDir) {
  const path = join(sessionDir, "events.jsonl");
  if (!existsSync(path)) throw new Error(`no events.jsonl in ${sessionDir}`);
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

async function main() {
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

    // Timings first — without them there is nothing to align, so a failure here
    // is fatal for the hold in a way a missing Sarvam transcript is not.
    process.stderr.write(`  hold ${hold} → on-device timings … `);
    let timing;
    try {
      timing = await appleTimings(wav, { locale: args.locale });
    } catch (err) {
      console.error(`FAILED\n    ${err.message}`);
      continue;
    }
    console.error(`${timing.words.length} segments`);

    // Sarvam for the words themselves. Best-effort: without it the hold falls
    // back to Apple's words, which mishear Hindi function words but still bind
    // English sessions fine.
    let holdWords = timing.words;
    process.stderr.write(`  hold ${hold} → ${transcriber.name} text … `);
    try {
      const result = await transcriber.transcribe(wav, { language });
      holdTexts.push({ hold, text: result.text });
      if (result.text) {
        const merged = mergeWords(result.text, timing.words, wavDurationMs(wav));
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

    // THE SHIFT. Offsets into the wav become session-clock times, so words and
    // cursor events share one timeline.
    allWords.push(...holdWords.map((w) => ({
      text: w.text,
      start: w.start + audioT0,
      end: w.end + audioT0,
      hold,
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
  writeFileSync(out, JSON.stringify({ words: allWords, holdTexts }, null, 2));
  console.error(`\n✓ ${allWords.length} words on the session clock → ${out}`);
}

main().catch((err) => {
  console.error(`✗ ${err.message}`);
  process.exit(1);
});
