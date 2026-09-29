#!/usr/bin/env node
/**
 * Where a brief belongs, and what it remembers.
 *
 *   node packages/core/src/classify.mjs ~/Library/Application\ Support/Deiko/<id>
 *
 * Scores every earlier task on this machine and sends the best twenty to the
 * classifier — Jev, through Deiko's relay — which answers, per task, whether
 * this brief is the same work, then takes a second look at the one or two
 * likeliest; also which collection it belongs to and how much work it looks
 * like. `decide` (lib/context.mjs) turns that into a join, a "Which one?", a
 * related link or a new task. The answers become `context.json` beside the
 * session, and a new task a row in `tasks.json`; `render-brief.mjs` reads
 * both and the board and review card show them.
 *
 * RUNS FOR OWN-KEY USERS TOO. Sorting is not transcription: somebody who
 * brought their own Groq key keeps their audio and its transcription off
 * Deiko's servers — both go straight to Groq — but what they said still
 * reaches the relay, redacted, to place the brief, so this reads
 * `DEIKO_CLASSIFY_URL`/`DEIKO_CLASSIFY_TOKEN` — its own pair, set whenever a
 * relay exists regardless of keys — falling back to `DEIKO_RELAY_URL`/
 * `DEIKO_RELAY_TOKEN` for a build or test that only sets those.
 *
 * AND IT CAN BE TURNED OFF. "Sort briefs into tasks" off in Settings arrives
 * as `DEIKO_SORT_BRIEFS=0`, and then nothing is sent whatever relay the
 * environment names — the `DEIKO_RELAY_URL` fallback too, which a keyless
 * install carries for its audio. What needs no relay is still decided below.
 *
 * WHAT LEAVES THIS MACHINE, redacted: what the developer said, the Groq
 * summary line, the app names, window and page titles, web addresses (host
 * and path only, never the part after "?"), open-document and file names,
 * code-project names and ticket ids — the labels (`labels.mjs`), all read
 * from titles and addresses — the collection names, hints and usual labels,
 * and for up to twenty shortlisted tasks their title, where they stand,
 * their decisions, window titles, apps, the files the agent listed, the last
 * outcome (at most 300 characters) and what their confirmed briefs asked.
 * Never a screenshot, never text read off a screen: the screen's words
 * (`screenTerms`, and the `components` and `errors` labels) shortlist tasks
 * locally and are never sent. Titles and addresses are the one addition to
 * the summary's rule (`summarize.mjs`), taken deliberately: a title names a
 * page, a file, a repo or a ticket, and that is what places a brief.
 *
 * NOTHING LEAVES FOR A BRIEF THERE IS NOTHING TO ASK ABOUT. Too little said,
 * or a summary that could not tell what was asked, is decided here, relay or
 * none: a short follow-up on a window its task already has joins that task,
 * and anything else goes to odds and ends (`pile: "odds"`, no task). Either
 * is `decidedBy: "local"`, sends no request and leaves no `classify.sent`.
 *
 * Failure is not fatal, ever. No relay, no network, a bad answer — the file
 * is simply absent and the brief ships as it always did. And a brief the
 * developer placed by hand (`decidedBy: "you"`) is never re-guessed; one
 * decided here or by Jev is, when there is more to go on.
 */

import { readFileSync, rmSync, statSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { homedir } from "node:os";

import { CLASSIFIER, unplaceable } from "./lib/context.mjs";
import { briefText, loadModel, readVector, vectorIsCurrent, writeVector } from "./lib/meaning.mjs";
import { readTasks, titleFor } from "./lib/tasks.mjs";
import { readListToRewrite, withBoardLock, writeAtomic, writeList } from "./lib/session-io.mjs";
import {
  decideLocally, olderBoard, place, prepare, rankLocally, readCollections, requestClassify, sessionInputs,
} from "./lib/filing.mjs";

/// Failures that happen before a connection exists, so nothing was sent.
const NEVER_CONNECTED = new Set(["ENOTFOUND", "ECONNREFUSED", "EHOSTUNREACH", "ENETUNREACH", "EAI_AGAIN"]);

/**
 * Leave the queue marker for a brief that could not be filed (see `main`).
 * At module level so the last-resort catch below can use it too.
 */
function markPendingIn(dir, reason) {
  const path = join(dir, "filing.pending");
  let since = new Date().toISOString(), tries = 0;
  try {
    ({ since, tries = 0 } = JSON.parse(readFileSync(path, "utf8")));
  } catch {
    // first time
  }
  writeAtomic(path, JSON.stringify({ since, reason, tries: tries + 1 }) + "\n");
}

/** `tasks.json` as rows to rewrite: `null` when it exists but won't parse (see `readListToRewrite`). */
const readTaskRows = (root) => readListToRewrite(join(root, "tasks.json"));
const unreadable = (file) => console.error(`classify: ${file} is unreadable; left as it is rather than rewritten`);

async function main() {
  const sessionArg = process.argv[2];
  if (!sessionArg) {
    console.error("usage: node packages/core/src/classify.mjs <session-dir>");
    process.exit(2);
  }
  // "0" from the app; "NO" or "false" as `defaults read` prints one written
  // by hand (`make classify`) — the app reads those as off too.
  const sorting = !/^(0|no|false)$/i.test(process.env.DEIKO_SORT_BRIEFS ?? "");
  const relay = sorting && (process.env.DEIKO_CLASSIFY_URL || process.env.DEIKO_RELAY_URL);

  const dir = resolve(sessionArg.replace(/^~/, homedir()));
  const id = basename(dir);
  const root = dirname(dir);
  const contextPath = join(dir, "context.json");
  // WRITTEN BEFORE THE REQUEST, NOT AFTER THE ANSWER. `context.json` alone
  // cannot say "the words left this Mac to be sorted" — it might never get
  // written (two 5xx in a row, a timeout, a network error) or might get
  // overwritten by a hand placement that races the answer back
  // (`decidedBy: "you"`, `model: null`), in either case while the POST below
  // already carried the narration and window titles out. `SessionClaims`
  // exists precisely so a card never understates what left; this marker is
  // its input for the classifier the same way `uploadedChunks` is for audio.
  // Read by the app as `filed` — see `ClassifyRequest.sentSummary` in
  // `Context.swift`. It carries no content: when it went, and whether a
  // summary went with it — the card can show a summary that landed after the
  // request left without one. `at` also tells this run whether a newer
  // request for the same brief has gone out since — see below.
  const sentMarker = join(dir, "classify.sent");
  const sentAt = () => {
    try {
      return JSON.parse(readFileSync(sentMarker, "utf8"))?.at ?? null;
    } catch {
      return null; // none, or a bare timestamp from before `at`
    }
  };

  // THE QUEUE. A brief that could not be filed (offline, the filing service
  // busy or refusing) keeps a `filing.pending` marker, and the app files it
  // again when it can: on reconnect, on launch, after the next brief that
  // files. Its own file, not a field in `context.json` — a context without
  // `decidedBy` reads as placed by hand in the app, and would never be filed.
  // Cleared by anything that settles where the brief goes.
  const pendingPath = join(dir, "filing.pending");
  const settled = () => rmSync(pendingPath, { force: true });
  // Placed by hand while the request was out: nothing waits any more.
  const markPending = (reason) => (current()?.decidedBy === "you" ? settled() : markPendingIn(dir, reason));

  /** `context.json` as it is now. Missing or unreadable is none: not "decided", and rewritten below. */
  const current = () => {
    try {
      return JSON.parse(readFileSync(contextPath, "utf8"));
    } catch {
      return null;
    }
  };

  if (current()?.decidedBy === "you") {
    settled();
    console.error("· placed by hand — leaving it");
    return;
  }

  const inputs = sessionInputs(dir);
  if (!inputs) {
    console.error(`· no readable brief.json in ${dir} — skipping the classification`);
    return;
  }
  const { summary, me, windowTitles } = inputs;
  const why = unplaceable(me);
  // Only a relay needs the rest; a brief with nothing to ask decides without one.
  if (!why && !relay) {
    settled(); // nothing will ever file it: not waiting, just not sorted
    console.error(`· ${sorting ? "no relay configured" : "sorting is off"} — skipping the classification`);
    return;
  }

  const collections = readCollections(root);
  const board = olderBoard(root, id);
  const taskTitles = readTasks(root);

  if (why) {
    const { groups, local } = rankLocally({ me, summary, windowTitles, board, taskTitles });
    const context = decideLocally({ me, local, groups, collections });
    // CHECKED AGAIN, as before the answer's write below: the board walk above
    // reads every brief on the Mac, and a "Move to task" can land meanwhile.
    if (current()?.decidedBy === "you") {
      settled();
      console.error("· placed by hand while we were looking — leaving it");
      return;
    }
    writeAtomic(contextPath, JSON.stringify(context, null, 2) + "\n");
    settled();
    console.error(context.task ? `✓ context → joins ${context.task} here (${why})` : `· ${why} — odds and ends`);
    return;
  }

  // MEANING, WHEN THE MODEL IS HERE: this brief as a query, earlier briefs by
  // the vectors their renders wrote — read only for the tasks' faces, which
  // are all `prepare` asks for. Absent — words alone, as always.
  let vectors = null;
  const model = await loadModel();
  const text = briefText(me);
  const query = model ? await model.embed(text, "query") : null;
  if (query) {
    vectors = { query, byBrief: { get: (bid) => readVector(join(root, bid), model.key) } };
    // THIS BRIEF'S OWN VECTOR while the model is loaded (~30 ms), so the
    // re-render after filing finds it current and never loads the model.
    try {
      if (!vectorIsCurrent(dir, model.key, text)) {
        const vec = await model.embed(text, "doc");
        if (vec) writeVector(dir, model.key, vec, text);
      }
    } catch {
      // The render writes it instead.
    }
  }

  const { groups, shortlist, body } = prepare({
    id, me, summary, windowTitles, board, taskTitles, collections, vectors,
  });

  const debug = process.env.DEIKO_CLASSIFY_DEBUG === "1";
  if (debug) console.error(`· debug request ${JSON.stringify(body)}`);
  const post = () => requestClassify({
    url: relay, token: process.env.DEIKO_CLASSIFY_TOKEN || process.env.DEIKO_RELAY_TOKEN || null, body,
  });

  // What an earlier request for this brief left. Put back if this one never
  // connects — its words did leave — and a summary it carried stays said:
  // the marker answers what went for this brief, not for this request alone.
  let previous = null;
  try {
    previous = readFileSync(sentMarker, "utf8");
  } catch {
    // None yet.
  }
  const summaryWentBefore = previous !== null && (() => {
    try {
      return JSON.parse(previous)?.summary !== false;
    } catch {
      return true; // a bare timestamp from before `summary`: assume it went
    }
  })();
  const mine = { at: new Date().toISOString(), summary: Boolean(me.summaryLine) || summaryWentBefore };
  let answer;
  let answered = false;
  try {
    // Before the network call, not after: everything below can fail or
    // never resolve, and by the time any of them do, the body — narration,
    // summary, window titles — has already gone out.
    writeAtomic(sentMarker, JSON.stringify(mine) + "\n");
    let response = await post();
    answered = true;
    // ONE RETRY, ON A 5XX ONLY. Measured live: about one call in ten came
    // back 503 from the model's side while its neighbours succeeded, and a
    // brief that loses its task's memory to a hiccup is the feature not
    // working. The relay refunds its meter on an upstream 5xx, so this costs
    // nothing extra; a 4xx is a real answer and is not retried.
    if (response.status >= 500) {
      await new Promise((r) => setTimeout(r, 1000));
      response = await post();
    }
    if (!response.ok) {
      // THE REASON TRAVELS WITH THE STATUS. A bare "503" was all this printed
      // while one call in three was failing, and the relay's body — which
      // names whether it was the meter, the key or the model — went in the
      // bin. Truncated, because a gateway that echoes its input back in an
      // error must not turn a log line into a content log.
      const why = (await response.text().catch(() => "")).replace(/\s+/g, " ").slice(0, 160);
      console.error(`· deiko relay ${response.status}${why ? ` — ${why}` : ""} — queued to file later`);
      markPending(response.status === 429 || response.status >= 500 ? "busy" : "refused");
      return;
    }
    answer = await response.json();
    if (debug) console.error(`· debug answer ${JSON.stringify(answer)}`);
  } catch (err) {
    // NOTHING LEFT IF NOTHING CONNECTED: no DNS, nothing listening, no route.
    // A timeout or a reset may have carried the body out, so those keep it.
    // Only this run's marker: a newer request's is that one's to keep.
    if (!answered && NEVER_CONNECTED.has(err?.cause?.code) && sentAt() === mine.at) {
      if (previous === null) rmSync(sentMarker, { force: true });
      else writeAtomic(sentMarker, previous);
    }
    console.error(`· classification failed (${err.message.slice(0, 80)}) — queued to file later`);
    markPending(!answered && NEVER_CONNECTED.has(err?.cause?.code) ? "offline" : "unreachable");
    return;
  }

  // A NEWER REQUEST FOR THIS BRIEF WENT OUT while this one waited: "Point at
  // more" added words and the app asked again. Its answer is the one to keep,
  // whichever lands last — and nothing below awaits, so this holds through
  // every write.
  if (sentAt() !== mine.at) {
    console.error("· asked again since — leaving it to the newer answer");
    return;
  }

  // CHECKED AGAIN, NOW. The check at the top of this script happened before a
  // network round trip that can take fifteen seconds, and the board's "Move
  // to" can file this very session in the meantime. Writing then would undo a
  // choice somebody had already made, which is the one thing `decidedBy` is
  // for. Before any write — a project or task row made for an answer that is
  // then left would outlive it.
  const placed = current();
  if (placed?.decidedBy === "you") {
    settled();
    console.error("· placed by hand while we were asking — leaving it");
    return;
  }
  // DECIDED ON THIS MAC SINCE WE ASKED: the words changed while this request
  // was out, and a newer run placed the brief here. A local decision leaves no
  // marker for the check above to see, so its file's time says it is newer.
  if (placed?.decidedBy === "local"
    && (statSync(contextPath, { throwIfNoEntry: false })?.mtimeMs ?? 0) > Date.parse(mine.at)) {
    console.error("· decided here since we asked — leaving it");
    return;
  }

  const decision = place({ answer, id, me, summary, groups, shortlist, collections });
  if (decision.pile !== "odds") {
    if (decision.newCollection) {
      // RE-READ, AND CHECK THE ID. Two things happen between the read at the
      // top of this script and here: a network call, and a user who may have
      // made a collection from the review card while it was in flight. Writing
      // the list we read minutes ago would drop theirs.
      //
      // The id check mirrors `Collections.add` in the app, which has always had
      // it. Without it `decide` — which dedupes on NAME — creates a second
      // `acme-portal` when the list already holds one called `Acme Portal`, and
      // two rows with one id give the board two identical chips, a rename that
      // moves one of them and a delete that takes both.
      withBoardLock(root, () => {
        const listed = readListToRewrite(join(root, "collections.json"));
        if (!listed) unreadable("collections.json");
        else if (!listed.some((c) => c?.id === decision.newCollection.id)) {
          listed.push({ ...decision.newCollection, hint: "" });
          writeList(join(root, "collections.json"), JSON.stringify(listed, null, 2) + "\n");
        } else {
          decision.collection = decision.newCollection.id;
        }
      });
    }
    if (decision.newTask) {
      // RE-READ, AND CHECK THE ID. The id is this brief's own stamp, so a
      // re-classify racing the first ("Forgot something?") finds the row the
      // first one wrote and leaves it.
      // `from` says what the title was made from, so a narration title can
      // give way to the first summary line that joins its task (below).
      withBoardLock(root, () => {
        const list = readTaskRows(root);
        if (!list) unreadable("tasks.json");
        else if (!list.some((t) => t?.id === decision.newTask.id)) {
          list.push({ ...decision.newTask, from: me.summaryLine ? "summary" : "narration" });
          writeList(join(root, "tasks.json"), JSON.stringify(list, null, 2) + "\n");
        }
      });
    }

    // A TITLE MADE FROM WHAT WAS SAID gives way to the first summary line that
    // joins its task. Only a row written from narration: one somebody typed
    // (`from: "you"`), or one with no `from` at all, is left as it is.
    if (!decision.newTask && decision.task && me.summaryLine) {
      withBoardLock(root, () => {
        const list = readTaskRows(root);
        const row = list?.find((t) => t?.id === decision.task);
        if (row?.from === "narration") {
          Object.assign(row, { title: titleFor(me), from: "summary" });
          writeList(join(root, "tasks.json"), JSON.stringify(list, null, 2) + "\n");
        }
      });
    }
  }

  const stamp = { decidedBy: "jev", model: typeof answer?.model === "string" ? answer.model : null, classifier: CLASSIFIER };
  const context = decision.pile === "odds"
    ? { pile: "odds", ...stamp, confidence: decision.confidence, jev: decision.jev }
    : {
      collection: decision.collection,
      task: decision.task,
      tier: decision.tier,
      confidence: decision.confidence,
      ...stamp,
      // "Which one?" — only when there are some. The app clears this on any hand placement.
      ...(decision.candidates && { candidates: decision.candidates }),
      // "Related to …" — linked, never merged.
      ...(decision.related && { related: decision.related }),
      // Joined because the brief pointed back at this work ("in that task"):
      // the card says so beside its "Same work?".
      ...(decision.why === "join-reference" && { because: "reference" }),
      // Every probability, and the shortlist in the order sent, for tuning.
      jev: decision.jev,
    };
  writeAtomic(contextPath, JSON.stringify(context, null, 2) + "\n");
  settled();
  console.error(decision.pile === "odds"
    ? `✓ context → odds and ends (not a request, ${decision.jev.gate})`
    : `✓ context → ${context.collection ?? "unsorted"} · ${decision.newTask ? "new task" : `joins ${context.task}`}`
      + `${context.candidates ? ` (maybe ${context.candidates.join(", ")})` : ""}`
      + `${context.related ? ` (related ${context.related})` : ""} · ${decision.why} · ${context.tier ?? "?"}`);
}

// Even an unexpected throw must not fail the pipeline that called us.
main().catch((err) => {
  console.error(`· classification failed (${err.message.slice(0, 80)}) — queued to file later`);
  // A throw is a brief that did not get filed: queued, never silently lost.
  try {
    if (process.argv[2]) markPendingIn(resolve(process.argv[2]), "error");
  } catch {
    // the folder itself is gone
  }
});
