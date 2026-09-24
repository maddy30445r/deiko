/**
 * FILING — the steps from a brief to where it goes, shared by `classify.mjs`,
 * which writes the answer, and `eval-filing.mjs`, which only scores it. Pure,
 * except `readCollections` and `sessionInputs`, which read.
 */

import { readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

import { COULD_NOT_TELL, decide, readBriefLine, unplaceable } from "./context.mjs";
import { groupTasks, readBoard, scoreTasks, stampTime, taskState, taskText, titleFor } from "./tasks.mjs";
import { loadEvents } from "./session-io.mjs";
import { KINDS } from "./labels.mjs";
import { redact } from "./redact.mjs";

/// Titles are the widest thing sent; thirty distinct ones cover any session.
export const MAX_TITLES = 30;

/// When a short brief's best local match is clear enough to join without
/// asking: at least `min`, at least `ratio` times the runner-up, and on a
/// window that task's briefs already had.
/// ponytail: eyeballed on one real 38-brief board, each brief scored with its
/// words dropped: min/ratio alone joined 3 of 16 briefs that opened a new
/// page to an older task in the same app, and no setting stopped that without
/// losing true joins; the shared window stopped all 3 and kept 13 of 14.
/// Upgrade: tune on real filing misses once odds and ends has some.
export const SHORT_JOIN = { min: 8, ratio: 2 };

/** Most frequent first; ties keep first-seen order, newest first for a task's briefs. */
function byCount(items) {
  const counts = new Map();
  for (const x of items) counts.set(x, (counts.get(x) ?? 0) + 1);
  return [...counts].sort((a, b) => b[1] - a[1]).map(([x]) => x);
}

/// Labels that may travel (labels.mjs): all but `components`.
const SENT_KEYS = KINDS.filter((k) => k !== "components");
/** The most frequent values first, redacted, capped. */
const topLabels = (lists, cap) => byCount(lists.flat().filter((s) => typeof s === "string" && s.trim())).slice(0, cap).map(redact);
const taskKeysOf = (briefs) => ({
  pages: [...new Set(briefs.flatMap((b) => b.keys?.pages ?? []))],
  files: [...new Set(briefs.flatMap((b) => b.keys?.files ?? []))],
  tickets: [...new Set(briefs.flatMap((b) => b.keys?.tickets ?? []))],
});

export function readCollections(root) {
  try {
    const list = JSON.parse(readFileSync(join(root, "collections.json"), "utf8"));
    return Array.isArray(list) ? list.filter((c) => c && typeof c.id === "string") : [];
  } catch {
    return [];
  }
}

export function sessionInputs(dir) {
  let summary;
  try {
    summary = JSON.parse(readFileSync(join(dir, "brief.json"), "utf8"))?.summary ?? {};
  } catch {
    return null;
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
  return { id: basename(dir), root: dirname(dir), summary, me: readBriefLine(dir), windowTitles };
}

export function olderBoard(root, id) {
  // Older only: a re-run over history must not see the future. And nothing
  // with nothing to place, or a mic test tops the shortlist as a task.
  return readBoard(root).filter((b) => b.id < id && !unplaceable(b));
}

export function prepare({ id, me, summary, windowTitles, board, taskTitles, collections }) {
  const groups = groupTasks(board);
  const now = stampTime(id);
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
      keys: Object.fromEntries(["pages", "sites", "files", "tickets"].map((k) => [k, topLabels(bs.map((b) => b.keys?.[k] ?? []), 3)])),
    };
  });

  const narration = (summary.narration ?? "").trim();
  const body = {
    narration: redact(narration),
    summary: me.summaryLine ? redact(me.summaryLine) : "",
    // REDACTED LIKE THE TITLES THEY COME FROM. `repoHints` is built by
    // splitting window titles (`render-brief.mjs`), so sending it raw put the
    // same screen-read string on the wire twice — once cleaned, once not.
    apps: (summary.apps ?? []).map(redact),
    repoHints: (summary.repoHints ?? []).map(redact),
    titles: windowTitles,
    // NEVER `components` — see labels.mjs.
    keys: Object.fromEntries(SENT_KEYS.map((k) => [k, (me.keys?.[k] ?? []).slice(0, 10).map(redact)])),
    collections: collections.map((c) => ({
      id: c.id, name: c.name, hint: c.hint ?? "",
      labels: topLabels(board.filter((b) => b.collection === c.id).map((b) => [...(b.keys?.repo ?? []), ...(b.keys?.sites ?? []), ...(b.keys?.pages ?? [])]), 5),
    })),
    tasks: shortlist,
    // NEVER screenTerms — they scored the shortlist above and stay here.
    // ROUTES THE RELAY TO THE V3 PATH — see services/relay/relay.mjs. A body
    // with no version (or below 3) reads as an unupdated 0.5.0 app.
    version: 3,
  };

  return { groups, scored, local: scored, shortlist, body };
}

export function decideLocally({ me, why, local, groups, collections }) {
  const [top, next] = local;
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
  return context;
}

export function place({ answer, id, me, summary, groups, shortlist, collections }) {
  const ids = shortlist.map((t) => t.id);
  return decide({
    answers: answer?.answers ?? {},
    second: answer?.second ?? {},
    collections,
    keys: me.keys ?? {},
    apps: summary.apps ?? [],
    shortlist: ids,
    taskKeys: Object.fromEntries(ids.map((t) => [t, taskKeysOf(groups.get(t))])),
    newest: Object.fromEntries(ids.map((t) => [t, stampTime(groups.get(t)[0].id)])),
    now: stampTime(id),
    // Each shortlisted task's latest collection, for a join nothing else placed.
    taskCollections: Object.fromEntries(ids.map((t) => [t, groups.get(t).find((b) => b.collection)?.collection ?? null])),
    sessionId: id,
    title: titleFor(me),
  });
}

export function requestClassify({ url, token, body }) {
  return fetch(`${url.replace(/\/+$/, "")}/v1/classify`, {
    method: "POST",
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15_000),
  });
}
