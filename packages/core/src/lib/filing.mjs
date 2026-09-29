/**
 * The steps from a brief to where it goes, shared by `classify.mjs`, which
 * writes the answer, and `evals/filing.mjs`, which only scores it. Pure,
 * except `readCollections` and `sessionInputs`, which read.
 */

import { readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

import { CLASSIFIER, COULD_NOT_TELL, REFERENCE, decide, readBriefLine, saysNothing, unplaceable } from "./context.mjs";
import {
  bm25, cosine, firm, groupTasks, readBoard, shortlist as rankTasks, stampTime, taskLabels, taskState, taskText, timeWindow,
  titleFor, tokens,
} from "./tasks.mjs";
import { loadEvents } from "./session-io.mjs";
import { KINDS } from "./labels.mjs";
import { redact, redactNote } from "./redact.mjs";

/// Titles are the widest thing sent; thirty distinct ones cover any session.
export const MAX_TITLES = 30;

/// When a short brief's best local match is clear enough to join without
/// asking: at least `min`, at least `ratio` times the runner-up, and on a
/// window that task's briefs already had. The shared window is what stops a
/// brief that opens a new page in the same app from joining an older task.
export const SHORT_JOIN = { min: 8, ratio: 2 };

/** Most frequent first; ties keep first-seen order, newest first for a task's briefs. */
function byCount(items) {
  const counts = new Map();
  for (const x of items) counts.set(x, (counts.get(x) ?? 0) + 1);
  return [...counts].sort((a, b) => b[1] - a[1]).map(([x]) => x);
}

/// Labels that may travel (labels.mjs): all but `components` and `errors`,
/// which are screen text.
const SENT_KEYS = KINDS.filter((k) => k !== "components" && k !== "errors");
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

const queryOf = (me, summary, windowTitles) =>
  [me.summaryText ?? me.summaryLine, me.narration, ...windowTitles, ...(summary.repoHints ?? []), ...me.screenTerms].join(" ");
const titler = (groups, taskTitles) => (tid) => taskTitles.get(tid) ?? titleFor(groups.get(tid).at(-1));

/** The short-brief path: word BM25 over every member of every task, best first. */
export function rankLocally({ me, summary, windowTitles, board, taskTitles }) {
  const groups = groupTasks(board);
  const titleOf = titler(groups, taskTitles);
  const all = [...groups];
  const wordScores = bm25(tokens(queryOf(me, summary, windowTitles)), all.map(([tid, bs]) => tokens(taskText(titleOf(tid), bs))));
  const local = all.map(([tid], i) => ({ id: tid, score: wordScores[i] })).sort((a, b) => b.score - a.score);
  return { groups, local };
}

/// How alike two tasks' briefs must mean (cosine of their averages) to count as
/// look-alikes. null = off; `DEIKO_LOOKALIKE` switches it on for a run.
export const LOOKALIKE = process.env.DEIKO_LOOKALIKE ? Number(process.env.DEIKO_LOOKALIKE) : null;

export function prepare({ id, me, summary, windowTitles, board, taskTitles, collections, vectors = null, aggregate, lookalike = LOOKALIKE }) {
  const groups = groupTasks(board);
  // A task's face: its firm briefs only. One guessed join must never become
  // what the task is matched against, or what Jev is told it is.
  const faces = new Map([...groups].map(([tid, bs]) => {
    const f = bs.filter((b) => firm(b, tid));
    return [tid, f.length ? f : [bs.at(-1)]];
  }));
  const titleOf = titler(groups, taskTitles);
  const scored = rankTasks({
    query: queryOf(me, summary, windowTitles),
    queryKeys: me.keys ?? {},
    // Time words seat tasks; they never reach `decide`.
    window: timeWindow([me.narration, me.summaryLine].join(" "), stampTime(id)),
    queryVec: vectors?.query ?? null,
    aggregate,
    tasks: [...groups].map(([tid, bs]) => ({
      id: tid,
      text: taskText(titleOf(tid), faces.get(tid)),
      texts: faces.get(tid).map((b) => taskText(titleOf(tid), [b])),
      labels: taskLabels(bs),
      times: bs.map((b) => stampTime(b.id)),
      lastActive: stampTime(bs[0].id),
      vecs: vectors ? faces.get(tid).map((b) => vectors.byBrief.get(b.id)).filter(Boolean) : [],
    })),
  });

  const shortlist = scored.map((s) => {
    const face = faces.get(s.id);
    const last = face.find((b) => b.outcome)?.outcome;
    const title = titleOf(s.id);
    return {
      id: s.id,
      // Local search's own score and seat, for `decide`; stripped before the
      // body goes to the relay (below), which never sees them.
      score: s.score,
      seat: s.seat,
      title: redact(title),
      // The newest ask is dropped here, unlike a prompt: the relay describes
      // a task by this field, and the newest brief is the one most likely
      // filed here by mistake. What is open, or was done, says what the task
      // is. Cut to the relay's own limits (`CLASSIFY_LIMITS` there): it checks
      // the body's size before it cuts, so a board of long outcome lines 413s.
      now: taskState(face, title).now.filter((l) => !l.startsWith("Last asked: ")).join("\n").slice(0, 400),
      decided: face.flatMap((b) => redactNote(b.outcome?.decided ?? [])).slice(0, 5).join("\n").slice(0, 300),
      // Its face's windows, not every member's: one brief filed here by
      // mistake must not become the face the classifier matches against.
      windows: byCount(face.flatMap((b) => b.windows)).slice(0, 3).map(redact),
      apps: [...new Set(face.flatMap((b) => b.apps))].slice(0, 5).map(redact),
      files: [...new Set(face.flatMap((b) => b.outcome?.files ?? []))].slice(0, 5).map(redact),
      outcome: last ? redact([...last.did, ...last.open].join(" ")).slice(0, 300) : "",
      keys: Object.fromEntries(["pages", "sites", "files", "tickets"].map((k) => [k, topLabels(face.map((b) => b.keys?.[k] ?? []), 3)])),
      // What its firm briefs asked, newest first. A board without agent
      // outcomes has nothing else to say what a task became after its first
      // brief.
      recent: face.slice(0, 3).map((b) => redact(b.summaryText || b.narration || "").slice(0, 400)).filter(Boolean),
    };
  });

  const narration = (summary.narration ?? "").trim();
  const body = {
    narration: redact(narration),
    summary: me.summaryText ? redact(me.summaryText) : "",
    // Redacted like the titles they come from: `repoHints` is built by
    // splitting window titles (`render-brief.mjs`), so sending it raw would put
    // the same screen-read string on the wire twice, once cleaned, once not.
    apps: (summary.apps ?? []).map(redact),
    repoHints: (summary.repoHints ?? []).map(redact),
    titles: windowTitles,
    // Never `components` or `errors` (see labels.mjs).
    keys: Object.fromEntries(SENT_KEYS.map((k) => [k, (me.keys?.[k] ?? []).slice(0, 10).map(redact)])),
    collections: collections.map((c) => ({
      id: c.id, name: c.name, hint: c.hint ?? "",
      labels: topLabels(board.filter((b) => b.collection === c.id).map((b) => [...(b.keys?.repo ?? []), ...(b.keys?.sites ?? []), ...(b.keys?.pages ?? [])]), 5),
    })),
    tasks: shortlist.map(({ score, seat, ...t }) => t),
    // Never screenTerms: they scored the shortlist above and stay here.
    // Routes the relay to the v3 path (services/relay/src/relay.mjs); a body
    // with no version, or below 3, reads as an old app.
    version: 3,
  };

  // Look-alikes: for the tasks a brief could point back at (the top few),
  // every other task whose briefs mean nearly the same (two apps' "price
  // bug"). A point-back join to one of them asks instead (`decide`). Only with
  // vectors, and only when switched on.
  const lookalikes = {};
  if (vectors && lookalike) {
    const centre = new Map([...faces].map(([tid, face]) => {
      const vs = face.map((b) => vectors.byBrief.get(b.id)).filter(Boolean);
      if (!vs.length) return [tid, null];
      const c = new Float32Array(vs[0].length);
      for (const v of vs) for (let k = 0; k < c.length; k++) c[k] += v[k] / vs.length;
      return [tid, c];
    }));
    for (const t of shortlist.slice(0, REFERENCE.candidates)) {
      const mine = centre.get(t.id);
      if (!mine) continue;
      const near = [...centre].filter(([other, c]) => other !== t.id && c && cosine(mine, c) >= lookalike).map(([other]) => other);
      if (near.length) lookalikes[t.id] = near;
    }
  }

  return { groups, shortlist, body, lookalikes };
}

export function decideLocally({ me, local, groups, collections }) {
  const [top, next] = local;
  const mine = new Set(me.windows);
  const joins = !COULD_NOT_TELL.test(me.summaryLine ?? "") && !saysNothing(me.narration) && top
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
      classifier: CLASSIFIER,
    }
    : { pile: "odds", decidedBy: "local", classifier: CLASSIFIER };
  return context;
}

export function place({ answer, id, me, summary, groups, shortlist, collections, rules, lookalikes = {} }) {
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
    rules,
    lookalikes,
    // Local search's own view, best first: what "the Mac is sure" means.
    local: shortlist.map((t) => ({ id: t.id, score: t.score, seat: t.seat })),
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
