#!/usr/bin/env node
/**
 * Render a recorded session into the message the developer hands over.
 *
 *   node packages/core/src/render-brief.mjs ~/Library/Application\ Support/Deiko/<id>
 *
 * Two outputs. `prompt.txt` is what gets pasted into a chat: the developer's
 * own words, the screenshots they drew, and the exact strings under what they
 * pointed at. `brief.json` is the sidecar the app reads: the summary the review
 * window shows, and the crop paths, including which ones are being withheld.
 *
 * This renderer does not write the task. It hands over what the developer said
 * and showed, and nothing else: it cannot know whether the work already
 * exists, and it does not explain itself, since a payload that describes how it
 * was assembled is one the end user has to read in their own chat.
 */

import { readFileSync, existsSync, rmSync } from "node:fs";
import { resolve, join, basename, dirname } from "node:path";

import { align, joinWords } from "@deiko/alignment";
import { loadSession } from "@deiko/alignment/session";
import { toCandidates } from "@deiko/alignment/candidates";
import { loadEvents, writeAtomic } from "./lib/session-io.mjs";
import { carriesSecret, assertNoSecrets, redact, redactBlock } from "./lib/redact.mjs";
import { briefKeys, repoHints } from "./lib/labels.mjs";
import { buildPrompt, quoteSurvives } from "./lib/prompt.mjs";
import { degradedReason as cloudDegradedReason } from "./lib/cloud.mjs";
import { readBriefLine, relativeAge, wantsQuickHint } from "./lib/context.mjs";
import { briefText, currentModel, isReady, loadModel, vectorIsCurrent, writeVector } from "./lib/meaning.mjs";
import { groupTasks, historyPath, readBoard, readTasks, stampTime, taskIdFor, taskMemory, taskState, titleFor, tokens, writeTaskNotes } from "./lib/tasks.mjs";

// ── Rendering ──

/** Narration reflowed into sentences, split on conversational pauses. */
function utteranceText(words, gapMs = 700) {
  const lines = [];
  let line = [];
  let prev = null;
  for (const w of words) {
    if (prev !== null && w.start - prev > gapMs && line.length) {
      lines.push(joinWords(line));
      line = [];
    }
    line.push(w.text);
    prev = w.end;
  }
  if (line.length) lines.push(joinWords(line));
  // Plain newlines. The caller adds the blockquote prefix; doing it in both
  // places would double it ("> > ").
  return lines.join("\n");
}

// ── Main ──

const sessionArg = process.argv[2];
if (!sessionArg) {
  console.error("usage: node packages/core/src/render-brief.mjs <sessionDir> [--out <path>]");
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
  console.error(`  transcribe first:  node packages/core/src/transcribe.mjs ${sessionArg}`);
  process.exit(1);
}

const events = loadEvents(dir);

const { words, cloud, degradedHolds } = JSON.parse(readFileSync(transcriptPath, "utf8"));
if (!words?.length) {
  console.error("✗ transcript.json has no words");
  process.exit(1);
}

/// Why this transcript is what it is. `transcribe.mjs` falls back silently and
/// by design (a spent trial, a spent month, the service's daily ceiling, an
/// unreachable relay or a failed chunk all keep the session working on Apple's
/// words), so the reason is surfaced here and the review window can name it
/// instead of the brief just reading worse. `degradedHolds` is a different
/// failure (the on-device clock was lost and the cloud text survived); both
/// travel, told apart.
const degradedReason = cloudDegradedReason({ cloud, degradedHolds });
const degraded = degradedReason != null;

const referents = loadSession(events).all();
const { bindings, unbound } = align(toCandidates(referents), words);
/// Keyed by `candidateId`, the referent's own id: how a screenshot finds the
/// sentence it was drawn during.
const bindingById = new Map(bindings.map((b) => [b.candidateId, b]));

// The developer's own correction of the narration, written by the review window
// before they press Good to go. Absent for a brief rendered straight from the
// command line.
const overridePath = join(dir, "narration.override.txt");
const narrationOverride = existsSync(overridePath)
  ? readFileSync(overridePath, "utf8").trim() || null
  : null;

// Screenshots the developer took out by hand in the review window, by basename.
// The whole referent goes, not just its `cropPath`: `lib/prompt.mjs` ships a
// referent's accessibility and OCR lines exactly when it has no screenshot and
// speech was bound to it, so nulling the path the way a withheld crop does
// would send the text of the image the developer just removed.
const excludedPath = join(dir, "crops.excluded.json");
let excludedCrops = new Set();
if (existsSync(excludedPath)) {
  try {
    excludedCrops = new Set(JSON.parse(readFileSync(excludedPath, "utf8")));
  } catch {
    // An unreadable exclusion list must not fail the render, but must not
    // silently ship what it was meant to hold back either: say so, and let the
    // developer see every crop in the review window before they send.
    console.error(`  ⚠ ${basename(excludedPath)} is unreadable — no screenshots excluded`);
  }
}

// The sidecar exists for one reason the markdown cannot serve: absolute crop
// paths. The brief names crops by basename so it stays readable and portable,
// but an agent needs a path it can open, and that path must never exist for a
// referent whose capture had a credential in it. Deciding that here, where the
// redaction rules live, keeps it from being re-derived elsewhere. A crop is
// released only if it was read (`ocrElapsedMs` is present exactly when Vision
// ran), because the secret test works on text, and text never extracted proves
// nothing about the pixels.
const probeByCrop = new Map(
  events.filter((e) => e.type === "probe" && e.crop?.path).map((e) => [e.crop.path, e]),
);
const cropWasRead = (r) =>
  r.cropPath != null && probeByCrop.get(r.cropPath)?.crop?.ocrElapsedMs != null;

function cropRelease(r) {
  if (!r.cropPath) return { path: null, reason: null };
  if (carriesSecret(r)) {
    // A screenshot of a credential is deleted, not just held back: kept, it
    // would sit in the session folder as the one unredacted copy of the key.
    // events.jsonl keeps its path and text, which keeps it withheld on every
    // re-render (scrubbing that text would let the next render release a
    // path). The raw OCR text stays there, on this Mac.
    rmSync(r.cropPath, { force: true });
    return { path: null, reason: "credential visible in this capture" };
  }
  if (!cropWasRead(r)) return { path: null, reason: "never OCR'd — contents unverified" };
  return { path: r.cropPath, reason: null };
}

// Built from the release decision, not from the raw referent: `cropRelease`
// settles "may this image be shared", and a path that failed it must never be
// written into a document. `said` is what makes a screenshot mean something:
// the sentence spoken while the referent was pointed at.
//
// A quote ships only if its words are still in what the developer approved.
// `said` is sliced from the raw transcript, while the review window promises
// that only the narration travels, so a client name edited out of the narration
// must not ship anyway in a label under a screenshot. The test is per quote:
// correct a typo elsewhere and every other label lives; delete a sentence and
// the label built from it goes with it. `labelsDropped` counts them so the
// window can say how many.
let labelsDropped = 0;
const kept = referents.filter((r) => !(r.cropPath && excludedCrops.has(basename(r.cropPath))));
const cropsRemoved = referents.length - kept.length;
const keptIds = new Set(kept.map((r) => r.id));
const keptBindings = bindings.filter((b) => keptIds.has(b.candidateId));
const released = kept.map((r) => {
  const { path, reason } = cropRelease(r);
  const utterance = bindingById.get(r.id)?.utterance ?? null;
  const survives = utterance != null
    && (narrationOverride == null || quoteSurvives(utterance, narrationOverride));
  // Counted only where a quote would have been a screenshot's caption, because
  // that is what the review window reports. A referent with no released crop
  // loses its quote too (which drops its screen text from the prompt, since
  // `lib/prompt.mjs` gates that on `said`), but counting those as
  // "screenshots" would not reconcile with what the user can see.
  if (path != null && utterance != null && !survives) labelsDropped++;

  // Two consequences hang off `said`, with different rules. On a referent with
  // a screenshot it is a caption, and per-quote survival is the right test. On
  // a referent without one it is the gate on that referent's screen text
  // reaching the prompt (see `lib/prompt.mjs`), and per-quote survival is too
  // weak there: overlap bindings are one to three words ("this one", "here")
  // that almost always still occur somewhere in a corrected narration, so
  // deleting the sentence that names a customer would keep the text of the very
  // window the developer was editing themselves out of. So captions get
  // per-quote survival, and screen text keeps the strict rule: any edit to the
  // narration drops it.
  const keepQuote = path != null ? survives : (narrationOverride == null && utterance != null);

  return {
    ...r,
    cropPath: path,
    cropWithheld: reason,
    said: keepQuote ? utterance : null,
  };
});

const narration = narrationOverride ?? utteranceText(words).replace(/\s*\n\s*/g, " ");
// The brief's labels, computed once: `manifest.summary` reuses them, and
// `related` below reads them to say why a linked task might be related.
const keys = briefKeys({ referents: kept, narration });

// Which persona this brief is written for, as an absolute path the app wrote
// beside the session (like `narration.override.txt` above). A brief rendered
// from the command line has no persona and no line about one.
const personaPointer = join(dir, "persona.txt");
const personaPath = existsSync(personaPointer)
  ? readFileSync(personaPointer, "utf8").trim() || null
  : null;

// The task this brief belongs to, as `classify.mjs` decided or the developer
// corrected. None (no relay, a fresh board, a command-line render, odds and
// ends) is its own task, and a task of one has nothing earlier to carry.
const contextPath = join(dir, "context.json");
let context = null;
if (existsSync(contextPath)) {
  try {
    context = JSON.parse(readFileSync(contextPath, "utf8"));
  } catch {
    console.error(`  ⚠ ${basename(contextPath)} is unreadable — rendering without its task`);
  }
}
const root = dirname(dir);
const myTask = context?.task ?? taskIdFor(basename(dir));
// Older briefs only, as `classify.mjs` reads the board: re-rendering an old
// brief must not hand its agent work that happened after it.
const groups = groupTasks(readBoard(root).filter((b) => b.id < basename(dir)));
const taskTitles = readTasks(root);
// Odds and ends carry on from nothing, whatever else claims their id.
const mates = context?.pile === "odds" ? [] : groups.get(myTask) ?? [];
// Every mate is older, so the oldest of them is the oldest brief of the task
// counting this one — the brief `writeTaskNotes` titles an untitled task by.
const myTitle = mates.length ? taskTitles.get(myTask) ?? titleFor(mates.at(-1)) : null;
// What the prompt carries about the task: see `taskMemory` in tasks.mjs.
const task = mates.length ? taskMemory({ root, id: myTask, title: myTitle, mates }) : null;
// On its own, but maybe: the tasks `classify.mjs` could not choose between.
// Only ids the board still has briefs for, which also makes a hand-edited id
// safe to put in a path. Not gated on `decidedBy`: placing the collection by
// hand leaves the task a guess, and the question stands. The app drops
// `candidates` when the task is placed by hand (`taskBy: "you"`), the one
// placement that answers it.
const maybe = !task && Array.isArray(context?.candidates) && context.candidates.length
  ? context.candidates.filter((id) => groups.has(id)).map((id) => {
    const bs = groups.get(id);
    const title = taskTitles.get(id) ?? titleFor(bs.at(-1));
    return {
      id,
      title,
      now: taskState(bs, title).now,
      // A task of one has no note unless it was corrected — see `historyPath`.
      notePath: historyPath(root, id, bs),
    };
  })
  : null;

// Related, not merged: the earlier task `classify.mjs` linked instead of
// joining. Only a task the board still has, and only while this brief is its
// own task. Why it might be related comes from the labels the two share.
const relatedId = !task && typeof context?.related === "string" && context.related !== myTask && groups.has(context.related)
  ? context.related : null;
const related = relatedId ? (() => {
  const bs = groups.get(relatedId);
  const theirs = (k) => new Set(bs.flatMap((b) => b.keys?.[k] ?? []).map((s) => String(s).toLowerCase()));
  const shares = (k) => (keys[k] ?? []).some((v) => theirs(k).has(String(v).toLowerCase()));
  return {
    id: relatedId,
    title: taskTitles.get(relatedId) ?? titleFor(bs.at(-1)),
    why: shares("pages") ? "same page" : shares("files") ? "same file" : shares("sites") ? "same site" : null,
    age: relativeAge(stampTime(basename(dir)) - stampTime(bs[0].id)),
    notePath: historyPath(root, relatedId, bs),
  };
})() : null;

const quickHint = wantsQuickHint(context, process.env.DEIKO_OPTIMIZE_COSTS === "1");
// The project's pinned rules (`rules` in collections.json), when it has any.
const rules = (() => {
  try {
    const list = JSON.parse(readFileSync(join(root, "collections.json"), "utf8"));
    const c = Array.isArray(list) ? list.find((x) => x?.id === context?.collection) : null;
    const lines = Array.isArray(c?.rules) ? c.rules.filter((l) => typeof l === "string" && l.trim()) : [];
    return lines.length ? { project: c.name, lines } : null;
  } catch {
    return null;
  }
})();
const outcomePath = join(dir, "outcome.md");

const { text, evidence } = buildPrompt({
  narration, referents: released, personaPath, task, maybe, related, outcomePath, quickHint, rules,
});

// The same message for a destination that cannot open a local path. A browser
// chat has no filesystem, so the paths in `text` are links it cannot follow and
// may claim to have followed; the handoff pastes the image bytes there instead
// and uses this variant, which numbers the screenshots by position. Both are
// rendered now because re-running the renderer when the developer chooses would
// put a Node spawn between letting go and the paste landing.
const attached = buildPrompt({
  narration, referents: released, attached: true, task, maybe, related, outcomePath, quickHint, rules,
});

// Fail closed on the captured content, not on the assembled prompt: `text`
// includes crop paths Deiko minted itself, and an absolute path is a
// 40-character run of `[A-Za-z0-9/_]` that trips the long-opaque-string rule.
// `evidence` is narration and screen text only, the only place a secret this
// renderer didn't put there could hide.
assertNoSecrets(evidence);
writeAtomic(outPath, text);
// The two variants differ only in how the screenshot section is written and
// are built from the same narration and referents, so their evidence is
// identical; guard it anyway rather than assume.
assertNoSecrets(attached.evidence);
writeAtomic(join(dir, "prompt-attached.txt"), attached.text);

/** The most frequent words read off the screen, redacted. Local only. */
function screenTerms(referents) {
  const counts = new Map();
  for (const r of referents) {
    // Redacted as one block, as `redactBlock`'s doc explains: a marker and the
    // value it announces can land on different OCR lines, so judging line by
    // line would let an unmarked credential fragment survive under the weaker
    // unmarked threshold.
    for (const line of redactBlock([...(r.text?.ax ?? []), ...(r.text?.ocr ?? [])])) {
      for (const w of tokens(line)) {
        if (w.length > 2 && !/^\d+$/.test(w)) counts.set(w, (counts.get(w) ?? 0) + 1);
      }
    }
  }
  return [...counts].sort((a, b) => b[1] - a[1]).slice(0, 60).map(([w]) => w);
}

const manifest = {
  sessionId: basename(dir),
  // The brief in short, for the review window to show before you send it.
  // Computed here rather than parsed back out of the markdown, so the window
  // and the brief cannot disagree about what is in the session. `narration` is
  // the session's context in the developer's own words; nothing summarises it,
  // since they already said what the task is, out loud.
  summary: {
    // Flowing, not pause-split. `utteranceText` breaks a line at every 700ms
    // gap in speech, which reads correctly as a blockquote in the brief but as
    // broken paragraphs in the review window's text box. Only the generated
    // text is collapsed: a developer's own correction keeps the line breaks
    // they typed.
    narration: narrationOverride ?? utteranceText(words).replace(/\s*\n\s*/g, " "),
    narrationEdited: narrationOverride != null,
    // `kept`, not `referents`: what the headline counts must be what ships, or
    // removing a screenshot would leave the window counting one that is gone.
    apps: [...new Set(kept.map((r) => r.app?.name).filter(Boolean))],
    repoHints: repoHints(kept.map((r) => r.window).filter(Boolean)),
    // What this brief was about, for matching it to a task later. Titles travel
    // to the classifier, redacted; `screenTerms` never leave the Mac
    // (`classify.mjs` scores with them locally and sends none). Only kept
    // referents: a removed screenshot's words are not evidence.
    windows: [...new Set(kept.map((r) => r.window).filter(Boolean).map(redact))].slice(0, 5),
    screenTerms: screenTerms(kept),
    // The brief's labels (page, site, address, file, project, document, error,
    // ticket), cleaned so the next visit to the same page matches. Kept
    // referents only. All but `components` may travel to the classifier,
    // redacted, as the window titles do.
    keys,
    referentCount: kept.length,
    wordCount: words.length,
    // Counted over `kept`, like `referentCount`. `align` runs over every
    // referent so the bindings do not shift when one is excluded, but the
    // counts shown beside each other must describe the same set.
    boundCount: keptBindings.length,
    unboundCount: unbound.filter((u) => keptIds.has(u.candidateId ?? u.id)).length,
    deicticCount: keptBindings.filter((b) => b.reason === "deictic").length,
    overlapCount: keptBindings.filter((b) => b.reason === "overlap").length,
    needsReviewCount: keptBindings.filter((b) => b.needsReview).length,
    durationMs:
      words.length ? Math.max(...words.map((w) => w.end)) - Math.min(...words.map((w) => w.start)) : 0,
    degraded,
    // Which degradation, so the window can name it instead of hedging. Null on
    // a clean session; see packages/core/src/lib/cloud.mjs for the values.
    degradedReason,
    // Who produced the words, and whether any of the audio reached them: the
    // line that says what left this Mac needs both, because a relay that was
    // never reached and one that refused what it received are different facts
    // about somebody's data.
    transcriber: cloud?.transcriber ?? null,
    uploadedChunks: cloud?.uploaded ?? null,
    // Quotes that did not survive the developer's own correction, and
    // screenshots they took out by hand: things the window has to account for
    // rather than leave as a silent shortfall.
    labelsDropped,
    cropsRemoved,
  },
  referents: released.map((r) => ({
    id: r.id,
    app: r.app?.name ?? null,
    kind: r.span ? "region" : "point",
    // null, never omitted: an absent key reads as "no crop was taken", which
    // is a different fact from "a crop exists and you may not have it".
    cropPath: r.cropPath,
    cropWithheld: r.cropWithheld,
    mark: r.mark ?? null,
    // The screenshot's caption — what was said while it was drawn — for the
    // board's brief view. Only on a released crop; the prompt already
    // carries it, so this puts nothing on disk the brief did not.
    said: r.cropPath ? r.said ?? null : null,
  })),
};
const withheld = manifest.referents.filter((r) => r.cropWithheld).length;
writeAtomic(join(dir, "brief.json"), JSON.stringify(manifest, null, 2) + "\n");
// After brief.json, so this brief is in its own task's note. One unwritable
// note (a full disk, a permissions error, `tasks` existing as a plain file)
// must not fail a render that already wrote prompt.txt and brief.json.
try {
  writeTaskNotes(root);
} catch (err) {
  console.error(`  ⚠ task notes not written — ${String(err?.message ?? err).slice(0, 80)}`);
}

// This brief's meaning, on this Mac only, for matching the briefs after it:
// from what was said and the window titles, never the screen's words. No model,
// or any failure, means no vector and words carry on alone. Checked before the
// model loads, so a re-render whose text did not change loads nothing. A first
// render that classify follows skips it too, since classify loads the model for
// its query anyway and embeds this brief once the summary line exists; with
// sorting off, no relay, or a brief placed by hand no classify load follows,
// and this one writes it.
const sorting = !/^(0|no|false)$/i.test(process.env.DEIKO_SORT_BRIEFS ?? "");
const classifyEmbeds = sorting && Boolean(process.env.DEIKO_CLASSIFY_URL || process.env.DEIKO_RELAY_URL)
  && !existsSync(join(dir, "review-summary.txt"))
  && context?.decidedBy !== "you";
try {
  const key = currentModel();
  const text = briefText(readBriefLine(dir));
  if (!classifyEmbeds && isReady(key) && text.trim() && !vectorIsCurrent(dir, key, text)) {
    const model = await loadModel(key);
    const vec = model ? await model.embed(text, "doc") : null;
    if (vec) writeVector(dir, key, vec, text);
  }
} catch (err) {
  console.error(`  ⚠ meaning vector not written — ${String(err?.message ?? err).slice(0, 80)}`);
}

const shots = manifest.referents.filter((r) => r.cropPath).length;
console.error(
  `✓ ${referents.length} referents (${bindings.length} bound, ${unbound.length} unbound), ` +
    `${shots} screenshot(s) → ${outPath}`,
);
if (withheld) {
  console.error(`  ${withheld} crop(s) withheld — see cropWithheld in brief.json`);
}
