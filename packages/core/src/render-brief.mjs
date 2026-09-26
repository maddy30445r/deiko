#!/usr/bin/env node
/**
 * Render a recorded session into the message the developer hands over.
 *
 *   node scripts/render-brief.mjs ~/Library/Application\ Support/Deiko/<id>
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

import { readFileSync, existsSync, rmSync } from "node:fs";
import { resolve, join, basename, dirname } from "node:path";

import { align, joinWords } from "../packages/alignment/dist/src/align.js";
import { loadSession } from "../packages/alignment/dist/src/referents/session.js";
import { toCandidates } from "../packages/alignment/dist/src/referents/candidates.js";
import { loadEvents, writeAtomic } from "./lib/session-io.mjs";
import { carriesSecret, assertNoSecrets, redact, redactBlock } from "./lib/redact.mjs";
import { briefKeys, repoHints } from "./lib/labels.mjs";
import { buildPrompt, quoteSurvives } from "./lib/prompt.mjs";
import { degradedReason as cloudDegradedReason } from "./lib/cloud.mjs";
import { briefDate, readBriefLine, relativeAge, wantsQuickHint } from "./lib/context.mjs";
import { briefText, currentModel, isReady, loadModel, vectorIsCurrent, writeVector } from "./lib/meaning.mjs";
import { firm, groupTasks, readBoard, readTasks, stampTime, taskIdFor, taskState, titleFor, tokens, writeTaskNotes } from "./lib/tasks.mjs";

// ── Rendering ───────────────────────────────────────────────────────────────

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

const { words, cloud, degradedHolds } = JSON.parse(readFileSync(transcriptPath, "utf8"));
if (!words?.length) {
  console.error("✗ transcript.json has no words");
  process.exit(1);
}

/// WHY this transcript is what it is.
///
/// `transcribe.mjs` falls back silently and by design — a spent trial, a spent
/// month, the service's daily ceiling, an unreachable relay or a failed chunk
/// all keep the session working on Apple's words rather than failing it. What
/// was missing is anybody being TOLD: the brief just read worse, and "the
/// transcription is bad" is what arrived in the inbox instead of "the relay
/// was down".
///
/// This used to read `source === "text-only"`, a field `transcribe.mjs` has
/// never written at the top level — so `degraded` was true only for
/// `degradedHolds`, which is a different failure entirely (the on-device CLOCK
/// was lost and the cloud text survived). Both now travel, told apart, so the
/// review window can name the one that happened.
const degradedReason = cloudDegradedReason({ cloud, degradedHolds });
const degraded = degradedReason != null;

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

// Screenshots the developer took out by hand in the review window, by basename.
//
// THE WHOLE REFERENT GOES, not just its `cropPath`. `lib/prompt.mjs` ships a
// referent's accessibility and OCR lines exactly when it has NO screenshot and
// speech was bound to it — so nulling the path the way a withheld crop does
// would send the text of the image the developer just removed, under a heading
// saying they pointed at it. Dropping the referent is the only form of "leave
// this out" that means what the × on the thumbnail says.
const excludedPath = join(dir, "crops.excluded.json");
let excludedCrops = new Set();
if (existsSync(excludedPath)) {
  try {
    excludedCrops = new Set(JSON.parse(readFileSync(excludedPath, "utf8")));
  } catch {
    // An unreadable exclusion list must not fail the render — but it must not
    // silently ship what it was meant to hold back either, so say so and let
    // the developer see every crop in the review window before they throw.
    console.error(`  ⚠ ${basename(excludedPath)} is unreadable — no screenshots excluded`);
  }
}

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
  if (carriesSecret(r)) {
    // A SCREENSHOT OF A CREDENTIAL IS DELETED, not just held back: kept, it
    // sat in the session folder forever, the one unredacted copy of the key.
    // events.jsonl keeps its path and text, which is what keeps it withheld
    // on every re-render — scrub that text and the next render would release
    // a path. ponytail: the raw OCR text stays in events.jsonl, on this Mac,
    // out of Time Machine; scrub it once the decision is stored in the probe.
    rmSync(r.cropPath, { force: true });
    return { path: null, reason: "credential visible in this capture" };
  }
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
// A QUOTE SHIPS ONLY IF ITS WORDS ARE STILL IN WHAT THE DEVELOPER APPROVED.
//
// `said` is sliced from the raw transcript. The review window shows the
// narration "verbatim and editable" and promises that only the narration
// travels — but it never shows these quotes, so a developer who edits a client
// name out of what they said would have had it ship anyway, in a label under a
// screenshot, with no way to see it going. The correction UI is a promise about
// what leaves the Mac; a quote it cannot reach breaks that promise silently.
//
// The first fix for that dropped EVERY quote the moment the narration was
// edited — which honoured the promise and cost the product the thing that makes
// a screenshot mean anything, on the one action the review window actively
// invites ("fix anything it misheard"). Fixing one misheard identifier
// unlabelled every image in the brief, under a footer reading "everything else
// goes as captured".
//
// So the test is per quote, and it is the same promise stated exactly: a label
// travels iff its words survive in the approved text. Correct a typo elsewhere
// and every other label lives; delete a sentence and the label built from it
// goes with it. `labelsDropped` is counted so the window can say how many did.
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
  // Counted only where a quote would have been a screenshot's CAPTION, because
  // that is what the review window reports. A referent with no released crop
  // loses its quote too — which drops its screen text from the prompt, since
  // `lib/prompt.mjs` gates that on `said` — but calling those "screenshots"
  // would be a count the user could not reconcile with what they can see.
  if (path != null && utterance != null && !survives) labelsDropped++;

  // TWO CONSEQUENCES HANG OFF `said`, AND THEY DESERVE DIFFERENT RULES.
  //
  // On a referent WITH a screenshot it is a caption, and per-quote survival is
  // the right test: correct a typo elsewhere and the other captions live.
  //
  // On a referent WITHOUT one it is the gate on that referent's screen text
  // reaching the prompt at all (`lib/prompt.mjs`: "a referent contributes text
  // only if it has no screenshot AND the aligner bound speech to it"). Per-quote
  // survival is too weak there. Overlap bindings are routinely one to three
  // words — "this one", "here", "the key" — which almost always still occur
  // somewhere in a corrected narration, so a developer who deletes the sentence
  // naming a customer would keep the referent's accessibility text: the very
  // contents of the window they were editing themselves out of. The old blanket
  // rule suppressed that, and losing it would be a privacy regression bought
  // with a captions feature.
  //
  // So: captions get the improvement, screen text keeps the old strictness.
  const keepQuote = path != null ? survives : (narrationOverride == null && utterance != null);

  return {
    ...r,
    cropPath: path,
    cropWithheld: reason,
    said: keepQuote ? utterance : null,
  };
});

const narration = narrationOverride ?? utteranceText(words).replace(/\s*\n\s*/g, " ");
// THE BRIEF'S LABELS, computed once — `manifest.summary` reuses this instead
// of calling `briefKeys` a second time, and `related` below reads it to say
// why a linked task might be related.
const keys = briefKeys({ referents: kept, narration });

// Which persona this brief is being written for, as an absolute path the app
// wrote beside the session — the same arrangement as `narration.override.txt`
// above, and for the same reason: a brief rendered from the command line is
// the document it always was, with no persona and no line about one.
const personaPointer = join(dir, "persona.txt");
const personaPath = existsSync(personaPointer)
  ? readFileSync(personaPointer, "utf8").trim() || null
  : null;

// THE TASK THIS BRIEF BELONGS TO, as `classify.mjs` decided or the developer
// corrected. None — no relay, a fresh board, a command-line render, odds and
// ends — is its own task, and a task of one has nothing earlier to carry.
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
// OLDER BRIEFS ONLY, as `classify.mjs` reads the board: re-rendering an old
// brief must not hand its agent work that happened after it.
const groups = groupTasks(readBoard(root).filter((b) => b.id < basename(dir)));
const taskTitles = readTasks(root);
// Odds and ends carry on from nothing, whatever else claims their id.
const mates = context?.pile === "odds" ? [] : groups.get(myTask) ?? [];
// Every mate is older, so the oldest of them is the oldest brief of the task
// counting this one — the brief `writeTaskNotes` titles an untitled task by.
const myTitle = mates.length ? taskTitles.get(myTask) ?? titleFor(mates.at(-1)) : null;
// RECENT BRIEFS, WHERE IT STANDS AND LAST TIME, for the prompt: firm ones
// only (`firm` in tasks.mjs) — the founder, a hand placement, or a sure v3
// join — so a join Jev only guessed at never shows up dressed as this task's
// own history. Newest three, oldest first, dated. A task with no firm brief
// at all falls back to every mate, as its face does in `prepare`.
const firmMates = mates.filter((b) => firm(b, myTask));
const task = mates.length
  ? (({ now, ...state }) => ({
    title: myTitle,
    count: mates.length,
    id: myTask,
    ...state,
    // "Last asked" already says the newest ask; the recent briefs below say
    // that themselves, dated, so it would only repeat.
    now: now.filter((l) => !l.startsWith("Last asked: ")),
    recent: firmMates.slice(0, 3).reverse().map((b) => ({ date: briefDate(b.id), line: b.line })),
    notePath: join(root, "tasks", `${myTask}.md`),
  }))(taskState(firmMates.length ? firmMates : mates, myTitle))
  : null;
// ON ITS OWN, BUT MAYBE NOT: the tasks `classify.mjs` could not choose
// between. Only ids the board still has briefs for — which is also what makes
// a hand-edited id safe to put in a path.
// Not gated on `decidedBy`: placing the COLLECTION by hand leaves the task a
// guess, and the question stands. The app drops `candidates` when the TASK is
// placed by hand (`taskBy: "you"`), which is the one placement that answers it.
const maybe = !task && Array.isArray(context?.candidates) && context.candidates.length
  ? context.candidates.filter((id) => groups.has(id)).map((id) => {
    const bs = groups.get(id);
    const title = taskTitles.get(id) ?? titleFor(bs.at(-1));
    return {
      id,
      title,
      now: taskState(bs, title).now,
      // A task of one has no note (`writeTaskNotes` skips it), so its history
      // is that brief's own file — by name, never the folder.
      notePath: bs.length > 1
        ? join(root, "tasks", `${id}.md`)
        : join(bs[0].dir, bs[0].outcome ? "outcome.md" : "prompt.txt"),
    };
  })
  : null;

// RELATED, NOT MERGED: the earlier task `classify.mjs` linked instead of
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
    notePath: bs.length > 1
      ? join(root, "tasks", `${relatedId}.md`)
      : join(bs[0].dir, bs[0].outcome ? "outcome.md" : "prompt.txt"),
  };
})() : null;

const quickHint = wantsQuickHint(context, process.env.DEIKO_OPTIMIZE_COSTS === "1");
const outcomePath = join(dir, "outcome.md");

const { text, evidence } = buildPrompt({
  narration, referents: released, personaPath, task, maybe, related, outcomePath, quickHint,
});

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
const attached = buildPrompt({
  narration, referents: released, attached: true, task, maybe, related, outcomePath, quickHint,
});

// Fail closed on the captured content, not on the assembled prompt. `text`
// includes crop paths Deiko minted itself — an absolute POSIX path is a
// 40-character run of `[A-Za-z0-9/_]` and trips the long-opaque-string rule
// on sight, so running the guard over `text` rejected every real prompt.
// `evidence` is narration and screen text only, which is the only place a
// secret this renderer didn't put there could hide.
assertNoSecrets(evidence);
writeAtomic(outPath, text);
// One assertion covers both: the two variants differ only in how the SCREENSHOT
// SECTION is written — Deiko's own words either way — and are built from the
// same narration and the same referents, so their evidence is identical. Guard
// it anyway rather than assume: the cost is microseconds and the assumption is
// exactly the kind that quietly stops being true.
assertNoSecrets(attached.evidence);
writeAtomic(join(dir, "prompt-attached.txt"), attached.text);

/** The most frequent words read off the screen, redacted. Local only. */
function screenTerms(referents) {
  const counts = new Map();
  for (const r of referents) {
    // Redacted as ONE block, like `redactBlock`'s own doc explains: a marker
    // and the value it announces can land on different OCR lines, so judging
    // "suspect" line by line let an unmarked credential fragment (no marker
    // on ITS line) survive under the weaker unmarked threshold.
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
    // `kept`, not `referents`: what the headline counts must be what actually
    // ships, or removing a screenshot leaves the window saying "6 things
    // pointed at" over five of them.
    apps: [...new Set(kept.map((r) => r.app?.name).filter(Boolean))],
    repoHints: repoHints(kept.map((r) => r.window).filter(Boolean)),
    // What this brief was ABOUT, for matching it to a task later. Titles
    // travel to the classifier, redacted, as they already did; `screenTerms`
    // NEVER leave the Mac — `classify.mjs` scores with them locally and sends
    // none. Only kept referents: a removed screenshot's words are not evidence.
    windows: [...new Set(kept.map((r) => r.window).filter(Boolean).map(redact))].slice(0, 5),
    screenTerms: screenTerms(kept),
    // THE BRIEF'S LABELS — page, site, address, file, project, document,
    // error, ticket — cleaned so the next visit to the same page matches.
    // Kept referents only, like everything here. All but `components` may
    // travel to the classifier, redacted, as the window titles do.
    keys,
    referentCount: kept.length,
    wordCount: words.length,
    // COUNTED OVER `kept`, like `referentCount`. `align` runs over every
    // referent so the bindings do not shift when one is excluded — but the
    // counts shown beside each other must describe the same set, or excluding
    // one bound screenshot from a six-referent session left the panel reading
    // "6 of 5 bound to what you said".
    boundCount: keptBindings.length,
    unboundCount: unbound.filter((u) => keptIds.has(u.candidateId ?? u.id)).length,
    deicticCount: keptBindings.filter((b) => b.reason === "deictic").length,
    overlapCount: keptBindings.filter((b) => b.reason === "overlap").length,
    needsReviewCount: keptBindings.filter((b) => b.needsReview).length,
    durationMs:
      words.length ? Math.max(...words.map((w) => w.end)) - Math.min(...words.map((w) => w.start)) : 0,
    degraded,
    // Which degradation, so the window can name it instead of hedging. Null on
    // a clean session; see scripts/lib/cloud.mjs for the five it can be.
    degradedReason,
    // Who produced the words, and whether any of the audio actually reached
    // them — the line that says what left this Mac needs both, because a relay
    // that was never reached and one that refused what it received are
    // different facts about somebody's data.
    transcriber: cloud?.transcriber ?? null,
    uploadedChunks: cloud?.uploaded ?? null,
    // Quotes that did not survive the developer's own correction, and
    // screenshots they took out by hand. Both are things the window has to be
    // able to account for out loud rather than leaving as a silent shortfall.
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

// THIS BRIEF'S MEANING, ON THIS MAC ONLY, for matching the briefs after it.
// From what was said and the window titles — never the screen's words. No
// model, or any failure, and there is simply no vector: words carry on alone.
// CHECKED BEFORE THE MODEL LOADS (~0.6 s, ~500 MB): a re-render whose text
// did not change, and one after `classify.mjs` already wrote it, load nothing.
// Nor does a first render that classify follows: classify loads the model for
// its query anyway and embeds this brief once the summary line exists, so a
// vector written here was replaced minutes later. Sorting off, no relay, or a
// brief placed by hand — no classify load follows, and this one writes it.
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
