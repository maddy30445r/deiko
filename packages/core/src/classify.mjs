#!/usr/bin/env node
/**
 * Where a brief belongs, and what it remembers.
 *
 *   node scripts/classify.mjs ~/Documents/Deiko/<id>
 *
 * Scores every earlier task on this machine, sends the best eight to the
 * classifier — Jev, through Deiko's relay — and asks in one call which
 * collection the brief belongs to, which of those tasks it joins (or none, and
 * it starts a new one), and how much work it looks like. The answers become
 * `context.json` beside the session, and a new task a row in `tasks.json`;
 * `render-brief.mjs` reads both and the board and review card show them.
 *
 * RUNS FOR OWN-KEY USERS TOO. Sorting is not transcription: somebody who
 * brought their own Groq key keeps their audio and its transcription off
 * Deiko's servers — both go straight to Groq — but what they said still
 * reaches the relay, redacted, to place the brief, so this reads
 * `DEIKO_CLASSIFY_URL`/`DEIKO_CLASSIFY_TOKEN` — its own pair, set whenever a
 * relay exists regardless of keys — falling back to `DEIKO_RELAY_URL`/
 * `DEIKO_RELAY_TOKEN` for a build or test that only sets those.
 *
 * WHAT LEAVES THIS MACHINE: what the developer said, the Groq summary line,
 * the app names, the repo hints, the window titles, the collection names and
 * hints, and for up to eight shortlisted tasks their title, where they stand,
 * their decisions, window titles, apps, the files the agent listed and the
 * last outcome (at most 600 characters). Never a screenshot, never text read
 * off a screen: the screen's words shortlist tasks locally and are never
 * sent. Window titles are the one addition to the summary's rule
 * (`summarize.mjs`), taken deliberately: a title names a file, a repo or a
 * ticket, and that is what places a brief.
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

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { homedir } from "node:os";

import { loadEvents } from "./lib/session-io.mjs";
import { redact } from "./lib/redact.mjs";
import { COULD_NOT_TELL, decide, readBriefLine, unplaceable } from "./lib/context.mjs";
import {
  groupTasks, readBoard, readTasks, scoreTasks, stampTime, taskState, taskText, titleFor,
} from "./lib/tasks.mjs";

/// Titles are the widest thing sent; thirty distinct ones cover any session.
const MAX_TITLES = 30;

/// When a short brief's best local match is clear enough to join without
/// asking: at least `min`, at least `ratio` times the runner-up, and on a
/// window that task's briefs already had.
/// ponytail: eyeballed on one real 38-brief board, each brief scored with its
/// words dropped: min/ratio alone joined 3 of 16 briefs that opened a new
/// page to an older task in the same app, and no setting stopped that without
/// losing true joins; the shared window stopped all 3 and kept 13 of 14.
/// Upgrade: tune on real filing misses once odds and ends has some.
const SHORT_JOIN = { min: 8, ratio: 2 };

/// Failures that happen before a connection exists, so nothing was sent.
const NEVER_CONNECTED = new Set(["ENOTFOUND", "ECONNREFUSED", "EHOSTUNREACH", "ENETUNREACH", "EAI_AGAIN"]);

/** `tasks.json` as rows. Missing or unreadable is none. */
function readTaskRows(root) {
  try {
    const list = JSON.parse(readFileSync(join(root, "tasks.json"), "utf8"));
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

/** Most frequent first; ties keep first-seen order, newest first for a task's briefs. */
function byCount(items) {
  const counts = new Map();
  for (const x of items) counts.set(x, (counts.get(x) ?? 0) + 1);
  return [...counts].sort((a, b) => b[1] - a[1]).map(([x]) => x);
}

function readCollections(root) {
  try {
    const list = JSON.parse(readFileSync(join(root, "collections.json"), "utf8"));
    return Array.isArray(list) ? list.filter((c) => c && typeof c.id === "string") : [];
  } catch {
    return [];
  }
}

async function main() {
  const sessionArg = process.argv[2];
  if (!sessionArg) {
    console.error("usage: node scripts/classify.mjs <session-dir>");
    process.exit(2);
  }
  const relay = process.env.DEIKO_CLASSIFY_URL || process.env.DEIKO_RELAY_URL;

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

  if (existsSync(contextPath)) {
    try {
      if (JSON.parse(readFileSync(contextPath, "utf8"))?.decidedBy === "you") {
        console.error("· placed by hand — leaving it");
        return;
      }
    } catch {
      // Unreadable is not "decided"; it is rewritten below.
    }
  }

  let summary;
  try {
    summary = JSON.parse(readFileSync(join(dir, "brief.json"), "utf8"))?.summary;
  } catch {
    console.error(`· no readable brief.json in ${dir} — skipping the classification`);
    return;
  }
  const narration = (summary?.narration ?? "").trim();
  const me = readBriefLine(dir);
  const why = unplaceable(me);
  // Only a relay needs the rest; a brief with nothing to ask decides without one.
  if (!why && !relay) {
    console.error("· no relay configured — skipping the classification");
    return;
  }

  let windowTitles = [];
  try {
    windowTitles = [...new Set(
      loadEvents(dir)
        .filter((e) => e.type === "probe" && typeof e.windowTitle === "string" && e.windowTitle.trim())
        .map((e) => redact(e.windowTitle).trim()),
    )].slice(0, MAX_TITLES);
  } catch {
    windowTitles = [];
  }

  const collections = readCollections(root);

  // Older only: a re-run over history must not see the future. And nothing
  // with nothing to place, or a mic test tops the shortlist as a task.
  const board = readBoard(root).filter((b) => b.id < id && !unplaceable(b));
  const taskTitles = readTasks(root);
  const groups = groupTasks(board);
  const now = stampTime(id);
  const ago = (ms) => {
    const m = Math.round((now - ms) / 60e3);
    return m < 60 ? `${m} min ago` : m < 48 * 60 ? `${Math.round(m / 60)} h ago` : `${Math.round(m / 1440)} days ago`;
  };
  const scored = scoreTasks({
    query: [me.summaryLine, me.narration, ...windowTitles, ...(summary.repoHints ?? []), ...me.screenTerms].join(" "),
    tasks: [...groups].map(([tid, bs]) => ({
      id: tid,
      text: taskText(taskTitles.get(tid) ?? titleFor(bs.at(-1)), bs),
      lastActive: stampTime(bs[0].id),
      repoHints: bs.flatMap((b) => b.repoHints),
    })),
    repoHints: summary.repoHints ?? [],
    now,
  });

  if (why) {
    const [top, next] = scored;
    const mine = new Set(me.windows);
    const joins = !COULD_NOT_TELL.test(me.summaryLine ?? "") && top
      && top.score >= SHORT_JOIN.min && top.score >= SHORT_JOIN.ratio * (next?.score ?? 0)
      && groups.get(top.id).some((b) => b.windows.some((w) => mine.has(w)));
    const inherited = joins && groups.get(top.id).find((b) => b.collection)?.collection;
    const context = joins
      ? {
        collection: collections.some((c) => c.id === inherited) ? inherited : null,
        task: top.id,
        tier: null,
        confidence: { task: null },
        decidedBy: "local",
        model: null,
      }
      : { pile: "odds", decidedBy: "local" };
    writeFileSync(contextPath, JSON.stringify(context, null, 2) + "\n");
    console.error(joins ? `✓ context → joins ${top.id} here (${why})` : `· ${why} — odds and ends`);
    return;
  }

  const shortlist = scored.map((s) => {
    const bs = groups.get(s.id);
    const last = bs.find((b) => b.outcome)?.outcome;
    const title = taskTitles.get(s.id) ?? titleFor(bs.at(-1));
    return {
      id: s.id,
      title: redact(title),
      // The newest ask LAST here, unlike a prompt: the relay describes a
      // task by this field's first line, and the newest brief is the one
      // most likely filed here by mistake. What is open, or was done, says
      // what the task is. A stable sort keeps the rest in order.
      now: [...taskState(bs, title).now]
        .sort((a, b) => a.startsWith("Last asked: ") - b.startsWith("Last asked: "))
        .join("\n"),
      decided: bs.flatMap((b) => b.outcome?.decided ?? []).slice(0, 5).map(redact).join("\n"),
      // Its most frequent windows, not its newest: one brief filed here by
      // mistake must not become the face the classifier matches against.
      windows: byCount(bs.flatMap((b) => b.windows)).slice(0, 5).map(redact),
      apps: [...new Set(bs.flatMap((b) => b.apps))].slice(0, 5).map(redact),
      files: [...new Set(bs.flatMap((b) => b.outcome?.files ?? []))].slice(0, 10).map(redact),
      outcome: last ? redact([...last.did, ...last.open].join(" ")).slice(0, 600) : "",
      lastActive: ago(stampTime(bs[0].id)),
      sameRepo: s.sameRepo,
    };
  });

  const body = {
    narration: redact(narration),
    summary: me.summaryLine ? redact(me.summaryLine) : "",
    // REDACTED LIKE THE TITLES THEY COME FROM. `repoHints` is built by
    // splitting window titles (`render-brief.mjs`), so sending it raw put the
    // same screen-read string on the wire twice — once cleaned, once not.
    apps: (summary.apps ?? []).map(redact),
    repoHints: (summary.repoHints ?? []).map(redact),
    titles: windowTitles,
    collections: collections.map((c) => ({ id: c.id, name: c.name, hint: c.hint ?? "" })),
    tasks: shortlist,
    // NEVER screenTerms — they scored the shortlist above and stay here.
  };

  const post = () => fetch(`${relay.replace(/\/+$/, "")}/v1/classify`, {
    method: "POST",
    headers: {
      ...(process.env.DEIKO_CLASSIFY_TOKEN || process.env.DEIKO_RELAY_TOKEN
        ? { Authorization: `Bearer ${process.env.DEIKO_CLASSIFY_TOKEN || process.env.DEIKO_RELAY_TOKEN}` }
        : {}),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
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
    writeFileSync(sentMarker, JSON.stringify(mine) + "\n");
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
      console.error(`· deiko relay ${response.status}${why ? ` — ${why}` : ""} — skipping the classification`);
      return;
    }
    answer = await response.json();
  } catch (err) {
    // NOTHING LEFT IF NOTHING CONNECTED: no DNS, nothing listening, no route.
    // A timeout or a reset may have carried the body out, so those keep it.
    // Only this run's marker: a newer request's is that one's to keep.
    if (!answered && NEVER_CONNECTED.has(err?.cause?.code) && sentAt() === mine.at) {
      if (previous === null) rmSync(sentMarker, { force: true });
      else writeFileSync(sentMarker, previous);
    }
    console.error(`· classification failed (${err.message.slice(0, 80)}) — skipping`);
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

  const decision = decide({
    answers: answer?.answers ?? {},
    collections,
    repoHints: summary.repoHints ?? [],
    shortlist: shortlist.map((t) => t.id),
    scores: scored.map((s) => s.score),
    // Each shortlisted task's latest collection, for a join nothing else placed.
    taskCollections: Object.fromEntries(scored.map((s) => [s.id, groups.get(s.id).find((b) => b.collection)?.collection ?? null])),
    sessionId: id,
    title: titleFor(me),
  });
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
    const current = readCollections(root);
    if (!current.some((c) => c.id === decision.newCollection.id)) {
      current.push({ ...decision.newCollection, hint: "" });
      writeFileSync(join(root, "collections.json"), JSON.stringify(current, null, 2) + "\n");
    } else {
      decision.collection = decision.newCollection.id;
    }
  }
  if (decision.newTask) {
    // RE-READ, AND CHECK THE ID. The id is this brief's own stamp, so a
    // re-classify racing the first ("Forgot something?") finds the row the
    // first one wrote and leaves it.
    // `from` says what the title was made from, so a narration title can
    // give way to the first summary line that joins its task (below).
    const list = readTaskRows(root);
    if (!list.some((t) => t?.id === decision.newTask.id)) {
      list.push({ ...decision.newTask, from: me.summaryLine ? "summary" : "narration" });
      writeFileSync(join(root, "tasks.json"), JSON.stringify(list, null, 2) + "\n");
    }
  }

  // CHECKED AGAIN, NOW. The check at the top of this script happened before a
  // network round trip that can take fifteen seconds, and the board's "Move
  // to" can file this very session in the meantime. Writing then would undo a
  // choice somebody had already made, which is the one thing `decidedBy` is
  // for.
  if (existsSync(contextPath)) {
    try {
      if (JSON.parse(readFileSync(contextPath, "utf8"))?.decidedBy === "you") {
        console.error("· placed by hand while we were asking — leaving it");
        return;
      }
    } catch {
      // Unreadable is not "decided"; it is replaced below.
    }
  }

  // A TITLE MADE FROM WHAT WAS SAID gives way to the first summary line that
  // joins its task. Only a row written from narration: one somebody typed
  // (`from: "you"`), or one with no `from` at all, is left as it is.
  if (!decision.newTask && decision.task && me.summaryLine) {
    const list = readTaskRows(root);
    const row = list.find((t) => t?.id === decision.task);
    if (row?.from === "narration") {
      Object.assign(row, { title: titleFor(me), from: "summary" });
      writeFileSync(join(root, "tasks.json"), JSON.stringify(list, null, 2) + "\n");
    }
  }

  const context = {
    collection: decision.collection,
    task: decision.task,
    tier: decision.tier,
    confidence: decision.confidence,
    decidedBy: "jev",
    model: typeof answer?.model === "string" ? answer.model : null,
    // The tasks it might carry on, when it could not tell — only when there
    // are some. The app clears this on any hand placement.
    ...(decision.candidates && { candidates: decision.candidates }),
  };
  writeFileSync(contextPath, JSON.stringify(context, null, 2) + "\n");
  console.error(`✓ context → ${context.collection ?? "unsorted"} · `
    + `${decision.newTask ? "new task" : `joins ${context.task}`}`
    + `${context.candidates ? ` (maybe ${context.candidates.join(", ")})` : ""} · ${context.tier ?? "?"}`);
}

// Even an unexpected throw must not fail the pipeline that called us.
main().catch((err) => {
  console.error(`· classification failed (${err.message.slice(0, 80)}) — skipping`);
});
