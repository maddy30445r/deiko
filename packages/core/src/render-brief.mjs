#!/usr/bin/env node
/**
 * Render a recorded session into the message the developer hands over.
 *
 *   node scripts/render-brief.mjs ~/Documents/Fovea/<id>
 *
 * Two outputs. `prompt.txt` is what gets pasted into a chat — the developer's
 * own words, the screenshots they drew, and the exact strings under what they
 * pointed at. `brief.json` is the sidecar the app reads: the summary the review
 * window shows, and the crop paths, including which ones are being withheld.
 *
 * THE GOVERNING DECISION: this renderer does not write the task.
 *
 * It hands over what the developer said and showed, and nothing else. The first
 * brief was hand-written and phrased the task as imperatives ("Push X to Y"),
 * which presumed the work was unbuilt; the agent then discovered most of it
 * already existed. A renderer cannot know that either. It also does not explain
 * itself: a payload that spends 1500 words describing how it was assembled is a
 * payload the end user has to read in their own chat.
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { resolve, join, basename } from "node:path";

import { align } from "../packages/alignment/dist/src/align.js";
import { loadSession } from "../packages/alignment/dist/src/referents/session.js";
import { toCandidates } from "../packages/alignment/dist/src/referents/candidates.js";
import { loadEvents } from "./lib/session-io.mjs";
import { carriesSecret, assertNoSecrets } from "./lib/redact.mjs";
import { buildPrompt } from "./lib/prompt.mjs";

// ── Repo identity ───────────────────────────────────────────────────────────

/** App/browser names that are never a repo, so they can be discarded. */
const NOT_A_REPO =
  /google chrome|safari|firefox|arc|bitbucket|github|gitlab|jira|discord|slack|visual studio code|cursor|finder|terminal|iterm|warp|screen recording/i;

/**
 * Guess repo names from window titles. Editors render `App.tsx — acme-portal`
 * (EM dash, U+2014); browsers render `Pull requests — acme-api-service —
 * Bitbucket - Google Chrome – Alex`, where the trailing en dash is the Chrome
 * profile. So: split on em dashes, drop segments naming an app, take what's left.
 */
function repoHints(titles) {
  const hints = new Map();
  for (const title of titles) {
    if (!title) continue;
    const parts = title
      .split("—")
      .map((p) => p.trim())
      .filter((p) => p && !NOT_A_REPO.test(p));
    if (parts.length < 2) continue;
    // The last surviving segment is the workspace; earlier ones are the file.
    const name = parts[parts.length - 1].replace(/\s*\(.*\)\s*$/, "").trim();
    if (!name || name.includes(" ")) continue; // repo names do not have spaces
    hints.set(name, (hints.get(name) ?? 0) + 1);
  }
  return [...hints.entries()].sort((a, b) => b[1] - a[1]).map(([name]) => name);
}

// ── Rendering ───────────────────────────────────────────────────────────────

/** Narration reflowed into sentences, split on conversational pauses. */
function utteranceText(words, gapMs = 700) {
  const lines = [];
  let line = [];
  let prev = null;
  for (const w of words) {
    if (prev !== null && w.start - prev > gapMs && line.length) {
      lines.push(line.join(" "));
      line = [];
    }
    line.push(w.text);
    prev = w.end;
  }
  if (line.length) lines.push(line.join(" "));
  // Plain newlines. The caller adds the blockquote prefix — doing it in both
  // places produced "> > " on every continuation line.
  return lines.join("\n");
}

// ── Main ────────────────────────────────────────────────────────────────────

const sessionArg = process.argv[2];
if (!sessionArg) {
  console.error("usage: node scripts/render-brief.mjs <sessionDir> [--out <path>]");
  process.exit(2);
}

const dir = resolve(sessionArg.replace(/^~/, process.env.HOME ?? "~"));
const outFlag = process.argv.indexOf("--out");
const outPath = outFlag > -1 ? resolve(process.argv[outFlag + 1]) : join(dir, "prompt.txt");

const eventsPath = join(dir, "events.jsonl");
const transcriptPath = join(dir, "transcript.json");

if (!existsSync(eventsPath)) {
  console.error(`✗ no events.jsonl in ${dir}`);
  process.exit(1);
}
if (!existsSync(transcriptPath)) {
  console.error(`✗ no transcript.json in ${dir}`);
  console.error(`  transcribe first:  node scripts/transcribe.mjs ${sessionArg}`);
  process.exit(1);
}

const events = loadEvents(dir);

const { words } = JSON.parse(readFileSync(transcriptPath, "utf8"));
if (!words?.length) {
  console.error("✗ transcript.json has no words");
  process.exit(1);
}

const referents = loadSession(events).all();
const { bindings, unbound } = align(toCandidates(referents), words);
/// Keyed by `candidateId`, which is the referent's own id — this is how a
/// screenshot finds the sentence it was drawn during.
const bindingById = new Map(bindings.map((b) => [b.candidateId, b]));

// The developer's own correction of the narration, written by the review window
// before they press Good to go. Absent for a brief rendered straight from the
// command line, which is the same document it always was.
const overridePath = join(dir, "narration.override.txt");
const narrationOverride = existsSync(overridePath)
  ? readFileSync(overridePath, "utf8").trim() || null
  : null;

// The sidecar exists for ONE reason the markdown cannot serve: absolute crop
// paths. The brief names crops by basename so it stays readable and portable,
// but an agent that wants to look at one needs a path it can open — and that
// path must never exist for a referent whose capture had a credential in it.
// Deciding that here, where the redaction rules live, is what keeps the
// decision from being re-derived (and got wrong) by the bridge.
// Two conditions, and the second is the one that is easy to miss. A crop is
// released only if we have READ it — `ocrElapsedMs` is present exactly when
// Vision ran — because the secret test works on text, and text we never
// extracted proves nothing about the pixels. Six of the twelve crops in
// 20260728-112323 were never OCR'd (the old `OCR.isNeeded` skipped them), so a
// purely marker-based rule would have handed over six unexamined images from
// the one session known to have had a live key on screen.
const probeByCrop = new Map(
  events.filter((e) => e.type === "probe" && e.crop?.path).map((e) => [e.crop.path, e]),
);
const cropWasRead = (r) =>
  r.cropPath != null && probeByCrop.get(r.cropPath)?.crop?.ocrElapsedMs != null;

function cropRelease(r) {
  if (!r.cropPath) return { path: null, reason: null };
  if (carriesSecret(r)) return { path: null, reason: "credential visible in this capture" };
  if (!cropWasRead(r)) return { path: null, reason: "never OCR'd — contents unverified" };
  return { path: r.cropPath, reason: null };
}

// Built from the RELEASE decision, not from the raw referent. `cropRelease` is
// where "may this image be shared" is settled, and a path that failed it must
// never be written into a document — the old design let the path exist and
// relied on the delivery layer to refuse it, which is one more place to get it
// wrong.
// `said` is what makes a screenshot mean something. The aligner has always
// computed which words were spoken while each referent was pointed at — that
// binding IS the product — and the payload was listing paths without it, so an
// agent handed two screenshots had to guess which sentence went with which.
// The alignment is right here, one line away; not passing it on was the
// omission, not the alignment.
// A CORRECTED NARRATION SILENCES THE QUOTES.
//
// `said` is sliced from the raw transcript. The review window shows the
// narration "verbatim and editable" and promises that only the narration
// travels — but it never shows these quotes, so a developer who edits a client
// name out of what they said would have had it ship anyway, in a label under a
// screenshot, with no way to see it going. The correction UI is a promise about
// what leaves the Mac; a quote it cannot reach breaks that promise silently.
//
// So an edited narration drops every quote. The screenshots still travel, just
// unlabelled — which is a real loss (the label is what ties an image to a
// sentence) and the right trade: the alternative is shipping words the
// developer believes they deleted.
const quotesAreStale = narrationOverride != null;
const released = referents.map((r) => {
  const { path, reason } = cropRelease(r);
  return {
    ...r,
    cropPath: path,
    cropWithheld: reason,
    said: quotesAreStale ? null : (bindingById.get(r.id)?.utterance ?? null),
  };
});

const narration = narrationOverride ?? utteranceText(words).replace(/\s*\n\s*/g, " ");
const { text, evidence } = buildPrompt({ narration, referents: released });

// The same message for a destination that cannot open a local path.
//
// Claude Code reads a crop with its own `Read` tool because the file is on the
// same machine; a browser chat has no filesystem, so the paths in `text` are
// links it cannot follow and may quietly claim to have followed. The handoff
// pastes the image bytes there instead and uses this variant, which numbers the
// screenshots by their position in the message rather than naming files.
//
// Rendered now, both of them, because nobody knows where the coin will land
// until the developer throws it — and re-running the renderer at that moment
// would put a Node spawn between letting go and the paste landing.
const attached = buildPrompt({ narration, referents: released, attached: true });

// Fail closed on the captured content, not on the assembled prompt. `text`
// includes crop paths Fovea minted itself — an absolute POSIX path is a
// 40-character run of `[A-Za-z0-9/_]` and trips the long-opaque-string rule
// on sight, so running the guard over `text` rejected every real prompt.
// `evidence` is narration and screen text only, which is the only place a
// secret this renderer didn't put there could hide.
assertNoSecrets(evidence);
writeFileSync(outPath, text);
// One assertion covers both: the two variants differ only in how the SCREENSHOT
// SECTION is written — Fovea's own words either way — and are built from the
// same narration and the same referents, so their evidence is identical. Guard
// it anyway rather than assume: the cost is microseconds and the assumption is
// exactly the kind that quietly stops being true.
assertNoSecrets(attached.evidence);
writeFileSync(join(dir, "prompt-attached.txt"), attached.text);

const manifest = {
  sessionId: basename(dir),
  // The brief in short, for the review window to show before you send it.
  //
  // Computed HERE rather than parsed back out of the markdown, because the
  // window and the brief must never disagree about what is in the session — a
  // reader that scrapes prose starts lying the first time the prose is reworded.
  //
  // `narration` is the session's context in the developer's own words. Nothing
  // summarises it and nothing should: they already said what the task is, out
  // loud, at capture time.
  summary: {
    // Flowing, not pause-split. `utteranceText` breaks a line at every 700ms
    // gap in speech, which reads correctly as a markdown blockquote in the brief
    // and reads as BROKEN PARAGRAPHS in the review window's text box — a lone
    // "ismein" on its own line looks like a bug in the transcript rather than
    // the shape of someone thinking mid-sentence.
    //
    // Only the generated text is collapsed. A developer's own correction keeps
    // whatever line breaks they typed: those are a choice, not an artefact.
    narration: narrationOverride ?? utteranceText(words).replace(/\s*\n\s*/g, " "),
    narrationEdited: narrationOverride != null,
    apps: [...new Set(referents.map((r) => r.app?.name).filter(Boolean))],
    repoHints: repoHints(referents.map((r) => r.window).filter(Boolean)),
    referentCount: referents.length,
    wordCount: words.length,
    boundCount: bindings.length,
    unboundCount: unbound.length,
    deicticCount: bindings.filter((b) => b.reason === "deictic").length,
    overlapCount: bindings.filter((b) => b.reason === "overlap").length,
    needsReviewCount: bindings.filter((b) => b.needsReview).length,
    durationMs:
      words.length ? Math.max(...words.map((w) => w.end)) - Math.min(...words.map((w) => w.start)) : 0,
  },
  referents: released.map((r) => ({
    id: r.id,
    app: r.app?.name ?? null,
    kind: r.span ? "region" : "point",
    // null, never omitted: an absent key reads as "no crop was taken", which
    // is a different fact from "a crop exists and you may not have it".
    cropPath: r.cropPath,
    cropWithheld: r.cropWithheld,
  })),
};
const withheld = manifest.referents.filter((r) => r.cropWithheld).length;
writeFileSync(join(dir, "brief.json"), JSON.stringify(manifest, null, 2) + "\n");

const shots = manifest.referents.filter((r) => r.cropPath).length;
console.error(
  `✓ ${referents.length} referents (${bindings.length} bound, ${unbound.length} unbound), ` +
    `${shots} screenshot(s) → ${outPath}`,
);
if (withheld) {
  console.error(`  ${withheld} crop(s) withheld — see cropWithheld in brief.json`);
}
