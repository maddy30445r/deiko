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

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve, join } from "node:path";

const SARVAM_STT_URL = "https://api.sarvam.ai/speech-to-text";

// ── The interface ───────────────────────────────────────────────────────────

/**
 * @typedef {{ text: string, start: number, end: number }} Word
 * @typedef {{ name: string, transcribe: (wavPath: string, opts: {language?: string}) => Promise<{words: Word[], text: string, raw: unknown}> }} Transcriber
 */

/** @returns {Transcriber} */
function sarvamTranscriber(apiKey) {
  return {
    name: "sarvam",
    async transcribe(wavPath, { language = "unknown" } = {}) {
      const audio = readFileSync(wavPath);
      const form = new FormData();
      form.append("file", new Blob([audio], { type: "audio/wav" }), "audio.wav");
      form.append("model", "saaras:v3");
      // codemix keeps Hinglish as Hinglish instead of translating it to
      // English — we need the words the user actually said, because the
      // deictic lexicon matches on "yeh"/"isko", not on their translations.
      form.append("mode", "codemix");
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

      return { words: normalizeWords(raw), text: extractText(raw), raw };
    },
  };
}

/**
 * Pull word timings out of the response.
 *
 * Written tolerantly on purpose: Sarvam's published docs do not pin the exact
 * nesting for word timestamps, and their model names and URLs have moved
 * before. Rather than hard-code one guess and silently produce an empty
 * transcript, try the plausible shapes and throw with the raw payload attached
 * if none match — so the fix takes one look instead of a debugging session.
 */
function normalizeWords(raw) {
  const candidates = [
    raw?.words,
    raw?.timestamps,
    raw?.word_timestamps,
    raw?.output?.words,
    raw?.transcript?.words,
    raw?.results?.[0]?.words,
    raw?.diarized_transcript?.entries?.flatMap((e) => e.words ?? []),
  ].filter(Array.isArray);

  for (const list of candidates) {
    const words = list
      .map((w) => ({
        text: String(w.word ?? w.text ?? w.token ?? "").trim(),
        start: toMs(w.start ?? w.start_time ?? w.start_time_seconds ?? w.startTime),
        end: toMs(w.end ?? w.end_time ?? w.end_time_seconds ?? w.endTime),
      }))
      .filter((w) => w.text && Number.isFinite(w.start) && Number.isFinite(w.end));
    if (words.length > 0) return words;
  }

  // Sarvam's `timestamps` block is sometimes parallel arrays rather than
  // objects: {words: [...], start_time_seconds: [...], end_time_seconds: [...]}
  const t = raw?.timestamps;
  if (t && Array.isArray(t.words) && Array.isArray(t.start_time_seconds)) {
    return t.words
      .map((word, i) => ({
        text: String(word).trim(),
        start: toMs(t.start_time_seconds[i]),
        end: toMs(t.end_time_seconds?.[i] ?? t.start_time_seconds[i]),
      }))
      .filter((w) => w.text && Number.isFinite(w.start));
  }

  const err = new Error(
    "could not find word timestamps in the Sarvam response — see raw payload above",
  );
  err.raw = raw;
  throw err;
}

/** Seconds or milliseconds in, milliseconds out. Values under 1000 are almost
 *  certainly seconds: no single word runs for 1000ms of *offset* in a clip this
 *  short, and treating seconds as ms would compress a 7s hold into 7ms. */
function toMs(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return NaN;
  return n < 1000 ? n * 1000 : n;
}

function extractText(raw) {
  return String(raw?.transcript ?? raw?.text ?? raw?.output?.transcript ?? "").trim();
}

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

  const langFlag = process.argv.indexOf("--language");
  const language = langFlag > -1 ? process.argv[langFlag + 1] : "unknown";

  const dir = resolve(sessionDir);
  const events = loadEvents(dir);
  const transcriber = sarvamTranscriber(apiKey);

  // Pair each hold's start (which carries the audio path) with its end (which
  // carries audioT0, only known once the first buffer landed).
  const starts = events.filter((e) => e.type === "sessionStart");
  const ends = events.filter((e) => e.type === "sessionEnd");

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
  for (const { hold, audioPath, audioT0 } of holds) {
    const wav = resolve(audioPath);
    process.stderr.write(`  hold ${hold} → ${transcriber.name} … `);

    let result;
    try {
      result = await transcriber.transcribe(wav, { language });
    } catch (err) {
      console.error(`FAILED\n    ${err.message}`);
      if (err.raw) console.error(`    raw: ${JSON.stringify(err.raw).slice(0, 600)}`);
      continue;
    }

    // THE SHIFT. Offsets into the wav become session-clock times.
    const shifted = result.words.map((w) => ({
      text: w.text,
      start: w.start + audioT0,
      end: w.end + audioT0,
      hold,
    }));
    allWords.push(...shifted);

    console.error(`${shifted.length} words`);
    if (result.text) console.error(`    "${result.text.slice(0, 100)}"`);
  }

  allWords.sort((a, b) => a.start - b.start);

  const out = join(dir, "transcript.json");
  writeFileSync(out, JSON.stringify({ words: allWords }, null, 2));
  console.error(`\n✓ ${allWords.length} words on the session clock → ${out}`);
}

main().catch((err) => {
  console.error(`✗ ${err.message}`);
  process.exit(1);
});
