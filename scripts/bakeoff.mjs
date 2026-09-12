// ─────────────────────────────────────────────────────────────────────────────
// THE BAKEOFF — WHICH RECOGNISER ACTUALLY HEARS CODE-MIXED SPEECH
//
// Pro is sold on "better words", and for Hinglish that claim rests on one spike
// from T0.2 comparing Apple against Sarvam. Whisper was never in that
// comparison, and it is now the interesting candidate: multilingual, a third of
// Sarvam's price, and it translates. This runs every recogniser over the SAME
// audio so the answer is about the models rather than about how the audio was
// cut — every engine here goes through `transcribe.mjs`'s own chunker.
//
// It prints the transcripts verbatim, side by side, because for code-mixed
// speech that is the evidence. A word-error rate over a two-minute sample would
// be a number with a false air of authority; reading "engine x" where you said
// "nginx" is the finding. Scores are computed only when a reference exists.
//
//   make bakeoff SESSION=~/Documents/Deiko/20260912-143000
//
// Needs the WAVs, so record with DEIKO_KEEP_AUDIO=1 — the app deletes them the
// moment a brief renders.
// ─────────────────────────────────────────────────────────────────────────────

import { readFileSync, existsSync, readdirSync, writeFileSync } from "node:fs";
import { resolve, join } from "node:path";
import { homedir } from "node:os";

import {
  appleTimings, groqTranscriber, mergeWords, sarvamTranscriber, wavDurationMs,
} from "./transcribe.mjs";
import { loadEvents } from "./lib/session-io.mjs";
import { loadSession } from "../packages/alignment/dist/src/referents/session.js";

/// The engines, in the order the report prints them.
///
/// `en-IN` first because it is what ships today: an Indian-English recogniser
/// renders Hindi phonetically in Latin script, which is the whole reason the
/// free tier can see a Hinglish pointing word at all. `en-US` is the control
/// that says how much of the gap is the locale rather than the model.
const ENGINES = [
  { id: "apple-en-IN", label: "Apple on-device · en-IN", kind: "apple", locale: "en-IN" },
  { id: "apple-en-US", label: "Apple on-device · en-US", kind: "apple", locale: "en-US" },
  { id: "apple-ctx", label: "Apple on-device · en-IN + screen vocabulary", kind: "apple", locale: "en-IN", context: true },
  { id: "sarvam", label: "Sarvam saaras:v3 · translit", kind: "sarvam", cost: "$0.35/hr" },
  { id: "whisper", label: "Groq whisper-large-v3", kind: "groq", model: "whisper-large-v3", cost: "$0.111/hr" },
  { id: "whisper-turbo", label: "Groq whisper-large-v3-turbo", kind: "groq", model: "whisper-large-v3-turbo", cost: "$0.04/hr" },
  // THE ONE THE PRODUCT IS ABOUT TO SHIP. `/audio/transcriptions` with an
  // English hint usually yields English for Hindi input; `/audio/translations`
  // is the endpoint that means it, and English output for everybody is the
  // decision taken. Measured here, on audio already recorded, before anything
  // depends on it. Translation is large-v3 only — turbo cannot do it.
  { id: "whisper-translate", label: "Groq whisper-large-v3 · translate→English", kind: "groq", model: "whisper-large-v3", translate: true, cost: "$0.111/hr" },
];

const sessionArg = process.argv[2];
if (!sessionArg) {
  console.error("usage: node scripts/bakeoff.mjs <session-dir> [--language hi-IN]");
  console.error("       record with DEIKO_KEEP_AUDIO=1 so the WAVs survive the brief");
  process.exit(2);
}
const dir = resolve(sessionArg.replace(/^~/, homedir()));
const language = flag("--language", "hi-IN");

function flag(name, fallback) {
  const i = process.argv.indexOf(name);
  if (i > -1 && process.argv[i + 1]) return process.argv[i + 1];
  const joined = process.argv.find((a) => a.startsWith(`${name}=`));
  return joined ? joined.slice(name.length + 1) : fallback;
}

/// Every hold's recording, in order. Falls back to the whole-session WAV so a
/// recording made outside the app can still be compared.
function wavsIn(sessionDir) {
  const audio = join(sessionDir, "audio");
  if (!existsSync(audio)) return [];
  const files = readdirSync(audio).filter((f) => f.endsWith(".wav")).sort();
  const holds = files.filter((f) => f.startsWith("hold-"));
  return (holds.length ? holds : files).map((f) => join(audio, f));
}

/// What was on screen, as vocabulary hints.
///
/// The identifiers a developer says are usually the ones in front of them, and
/// Deiko has already read them through AX and OCR. This is the whole thesis of
/// the `apple-ctx` engine: the free tier can be told what words to expect
/// without anything leaving the Mac.
function screenVocabulary(sessionDir) {
  if (!existsSync(join(sessionDir, "events.jsonl"))) return [];
  // The same reader the brief uses, so the hints are exactly the text the
  // product already had in hand — `text.ax` first, OCR where there was no
  // accessibility text, which is the order `prompt.mjs` itself prefers.
  const referents = loadSession(loadEvents(sessionDir)).all();
  const seen = new Set();
  for (const r of referents) {
    const strings = [
      ...(r.text?.ax ?? []),
      ...(r.text?.axStart ?? []),
      ...(r.text?.ocr ?? []),
      r.appName, r.windowTitle,
    ].filter((s) => typeof s === "string");
    for (const s of strings) {
      // Identifier-shaped tokens only. Whole sentences of screen text would
      // dilute the bias rather than focus it, and the point is the words a
      // dictation model has never heard of.
      for (const token of s.split(/[^A-Za-z0-9_.\-/]+/)) {
        if (token.length < 3 || token.length > 40) continue;
        if (/^[a-z]+$/.test(token) && token.length < 6) continue; // ordinary words
        seen.add(token);
      }
    }
  }
  return [...seen];
}

const normalise = (s) => String(s ?? "").toLowerCase().replace(/[^\p{L}\p{N}\p{M}\s]/gu, "").split(/\s+/).filter(Boolean);

/// Levenshtein over words. Only ever reported when a reference exists.
function wordErrorRate(referenceText, hypothesisText) {
  const ref = normalise(referenceText);
  const hyp = normalise(hypothesisText);
  if (ref.length === 0) return null;
  const d = Array.from({ length: ref.length + 1 }, (_, i) =>
    Array.from({ length: hyp.length + 1 }, (_, j) => (i === 0 ? j : j === 0 ? i : 0)));
  for (let i = 1; i <= ref.length; i++) {
    for (let j = 1; j <= hyp.length; j++) {
      d[i][j] = ref[i - 1] === hyp[j - 1]
        ? d[i - 1][j - 1]
        : 1 + Math.min(d[i - 1][j - 1], d[i - 1][j], d[i][j - 1]);
    }
  }
  return d[ref.length][hyp.length] / ref.length;
}

/// THE NUMBER THAT DECIDES ANYTHING. A word-error rate counts "the" and
/// `useEffect` the same; a developer does not. `terms.txt` lists the
/// identifiers actually said, one per line, and this reports how many survived.
function termRecall(terms, hypothesisText) {
  if (!terms.length) return null;
  const hay = normalise(hypothesisText).join(" ");
  const hit = terms.filter((t) => hay.includes(normalise(t).join(" ")));
  return { hit: hit.length, total: terms.length, missed: terms.filter((t) => !hit.includes(t)) };
}

async function runEngine(engine, wavs, contextFile, appleWordsByWav) {
  const parts = [];
  const started = Date.now();
  let anchors = 0;
  let anchorTotal = 0;
  for (const wav of wavs) {
    if (engine.kind === "apple") {
      const result = await appleTimings(wav, {
        locale: engine.locale,
        contextFile: engine.context ? contextFile : undefined,
      });
      // The timing source anchors itself by definition — its words ARE
      // measurements. Recorded so the baseline column is not blank, and so a
      // cloud engine scoring near it is visibly scoring near the ceiling.
      const words = result.words ?? [];
      if (engine.locale === "en-IN" && !engine.context) appleWordsByWav.set(wav, words);
      anchors += words.length;
      anchorTotal += words.length;
      parts.push(result.transcript ?? words.map((w) => w.text).join(" "));
    } else {
      const key = engine.kind === "sarvam" ? process.env.SARVAM_API_KEY : process.env.GROQ_API_KEY;
      if (!key) throw new Error(`${engine.kind.toUpperCase()}_API_KEY is not set`);
      const t = engine.kind === "sarvam"
        ? sarvamTranscriber(key)
        : groqTranscriber(key, engine.model, { translate: engine.translate === true });
      const { text } = await t.transcribe(wav, { language });
      // THE NUMBER THE PRODUCT RESTS ON. A screenshot binds to the sentence it
      // was taken during through words that carry a measured time, and a cloud
      // word only gets one by matching an Apple word — longest common
      // subsequence, in `mergeWords`. A transcript that reads beautifully but
      // shares no tokens with the timing source anchors nothing, and every
      // referent in that stretch ends up quoting the same span.
      const apple = appleWordsByWav.get(wav) ?? [];
      if (apple.length) {
        const merged = mergeWords(text, apple, wavDurationMs(wav));
        anchors += merged.anchors;
        anchorTotal += merged.total;
      }
      parts.push(text);
    }
  }
  return {
    text: parts.join(" ").replace(/\s+/g, " ").trim(),
    ms: Date.now() - started,
    anchors: anchorTotal ? `${anchors}/${anchorTotal}` : "—",
  };
}

async function main() {
  const wavs = wavsIn(dir);
  if (!wavs.length) {
    console.error(`✗ no WAVs under ${dir}/audio — record with DEIKO_KEEP_AUDIO=1`);
    process.exit(1);
  }

  const vocabulary = screenVocabulary(dir);
  const contextFile = join(dir, "bakeoff.context.txt");
  writeFileSync(contextFile, vocabulary.join("\n"));

  const referencePath = join(dir, "reference.txt");
  const termsPath = join(dir, "terms.txt");
  const reference = existsSync(referencePath) ? readFileSync(referencePath, "utf8").trim() : "";
  const terms = existsSync(termsPath)
    ? readFileSync(termsPath, "utf8").split("\n").map((t) => t.trim()).filter(Boolean)
    : [];

  console.error(`${wavs.length} recording${wavs.length > 1 ? "s" : ""} · language ${language}`);
  console.error(`${vocabulary.length} screen vocabulary hints → ${contextFile}`);
  if (!reference) console.error("no reference.txt — printing transcripts only, no scores");
  console.error("");

  // Apple runs first in ENGINES on purpose: its words are the timing source
  // every cloud engine is then scored against.
  const appleWordsByWav = new Map();
  const results = [];
  for (const engine of ENGINES) {
    process.stderr.write(`  ${engine.label} … `);
    try {
      const { text, ms, anchors } = await runEngine(engine, wavs, contextFile, appleWordsByWav);
      results.push({ engine, text, ms, anchors });
      process.stderr.write(`${(ms / 1000).toFixed(1)}s · anchors ${anchors}\n`);
    } catch (err) {
      results.push({ engine, error: err.message });
      process.stderr.write(`FAILED — ${err.message}\n`);
    }
  }

  const out = [`# Bakeoff — ${dir}`, "", `Language \`${language}\` · ${wavs.length} recording(s)`, ""];
  out.push("## Scores", "",
    "`anchors` is how many of the engine's words got a measured time by matching the",
    "on-device timing source — what binds a screenshot to the sentence it was taken during.",
    "",
    `| Engine | Anchors |${reference ? " Term recall | WER |" : ""} Time | Cost |`,
    `|---|---|${reference ? "---|---|" : ""}---|---|`);
  for (const { engine, text, error, ms, anchors } of results) {
    if (error) {
      out.push(`| ${engine.label} | — |${reference ? " — | — |" : ""} — | ${engine.cost ?? "free"} |`);
      continue;
    }
    const scores = reference
      ? ` ${(() => { const r = termRecall(terms, text); return r ? `${r.hit}/${r.total}` : "—"; })()} `
        + `| ${(() => { const w = wordErrorRate(reference, text); return w != null ? `${(w * 100).toFixed(1)}%` : "—"; })()} |`
      : "";
    out.push(`| ${engine.label} | ${anchors} |${scores} ${(ms / 1000).toFixed(1)}s | ${engine.cost ?? "free"} |`);
  }
  out.push("");
  out.push("## Transcripts", "");
  if (reference) out.push("**Reference (what was said):**", "", `> ${reference}`, "");
  for (const { engine, text, error } of results) {
    out.push(`**${engine.label}**${engine.cost ? ` · ${engine.cost}` : " · free"}`, "");
    out.push(error ? `> _failed: ${error}_` : `> ${text || "_(nothing)_"}`, "");
    const recall = !error && termRecall(terms, text);
    if (recall?.missed?.length) out.push(`missed: ${recall.missed.join(", ")}`, "");
  }

  const report = join(dir, "bakeoff.md");
  writeFileSync(report, out.join("\n"));
  console.error(`\n✓ ${report}\n`);
  console.log(out.join("\n"));
}

main().catch((err) => {
  console.error(`✗ ${err.message}`);
  process.exit(1);
});
