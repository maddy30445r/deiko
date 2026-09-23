#!/usr/bin/env node
/**
 * Where a brief belongs, and what it remembers.
 *
 *   node scripts/classify.mjs ~/Documents/Deiko/<id>
 *
 * Asks the classifier — Jev, through Deiko's relay — three things about a
 * brief in one call: which collection it belongs to, which earlier brief it
 * continues, and whether each of the newest earlier briefs is useful
 * background for it; plus how much work it looks like. The answers become
 * `context.json` beside the session, which `render-brief.mjs` reads and the
 * board and review card show.
 *
 * WHAT LEAVES THIS MACHINE: what the developer said, the app names, the repo
 * hints, the window titles, the collection names and hints, and one line per
 * earlier brief — its narration and the first line of its outcome. Never a
 * screenshot, never the text read off a screen. Window titles are the one
 * addition to the summary's rule (`summarize.mjs`), taken deliberately: a
 * title names a file, a repo or a ticket, and that is what places a brief.
 *
 * Failure is not fatal, ever. No relay, no network, a bad answer — the file
 * is simply absent and the brief ships as it always did. And a brief the
 * developer placed by hand (`decidedBy: "you"`) is never re-guessed.
 */

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { homedir } from "node:os";

import { loadEvents } from "./lib/session-io.mjs";
import { redact } from "./lib/redact.mjs";
import {
  CANDIDATE_LIMIT, MIN_NARRATION, STAMP, decide, pickCandidates, readBriefLine,
} from "./lib/context.mjs";

/// Titles are the widest thing sent; thirty distinct ones cover any session.
const MAX_TITLES = 30;

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
  const relay = process.env.DEIKO_RELAY_URL;
  if (!relay) {
    console.error("· no relay configured — skipping the classification");
    return;
  }

  const dir = resolve(sessionArg.replace(/^~/, homedir()));
  const id = basename(dir);
  const root = dirname(dir);
  const contextPath = join(dir, "context.json");

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
  if (narration.length < MIN_NARRATION) {
    console.error("· narration too short to place — skipping");
    return;
  }

  let titles = [];
  try {
    titles = [...new Set(
      loadEvents(dir)
        .filter((e) => e.type === "probe" && typeof e.windowTitle === "string" && e.windowTitle.trim())
        .map((e) => redact(e.windowTitle).trim()),
    )].slice(0, MAX_TITLES);
  } catch {
    titles = [];
  }

  const collections = readCollections(root);

  // The newest earlier briefs, read until the window is full. Names sort as
  // stamps, so the walk stops early on a big board rather than reading it all.
  const sessions = [];
  const names = readdirSync(root).filter((n) => STAMP.test(n) && n !== id).sort().reverse();
  for (const name of names) {
    if (sessions.length >= CANDIDATE_LIMIT) break;
    const line = readBriefLine(join(root, name));
    if ((line.narration ?? "").trim().length >= MIN_NARRATION) sessions.push(line);
  }
  const candidates = pickCandidates(sessions, { exclude: id, collections });

  const body = {
    narration: redact(narration),
    // REDACTED LIKE THE TITLES THEY COME FROM. `repoHints` is built by
    // splitting window titles (`render-brief.mjs`), so sending it raw put the
    // same screen-read string on the wire twice — once cleaned, once not.
    apps: (summary.apps ?? []).map(redact),
    repoHints: (summary.repoHints ?? []).map(redact),
    titles,
    collections: collections.map(({ id: cid, name, hint }) => ({ id: cid, name, hint: hint ?? "" })),
    candidates,
  };

  let answer;
  try {
    const response = await fetch(`${relay.replace(/\/+$/, "")}/v1/classify`, {
      method: "POST",
      headers: {
        ...(process.env.DEIKO_RELAY_TOKEN
          ? { Authorization: `Bearer ${process.env.DEIKO_RELAY_TOKEN}` }
          : {}),
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
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
    console.error(`· classification failed (${err.message.slice(0, 80)}) — skipping`);
    return;
  }

  const decision = decide({
    answers: answer?.answers ?? {},
    collections,
    repoHints: summary.repoHints ?? [],
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

  const context = {
    collection: decision.collection,
    continues: decision.continues,
    related: decision.related,
    tier: decision.tier,
    confidence: decision.confidence,
    decidedBy: "jev",
    model: typeof answer?.model === "string" ? answer.model : null,
  };
  writeFileSync(contextPath, JSON.stringify(context, null, 2) + "\n");
  console.error(
    `✓ context → ${context.collection ?? "unsorted"} · `
      + `${context.continues ? `continues ${context.continues}` : "stands alone"} · `
      + `${context.related.length} related · ${context.tier ?? "?"}`,
  );
}

// Even an unexpected throw must not fail the pipeline that called us.
main().catch((err) => {
  console.error(`· classification failed (${err.message.slice(0, 80)}) — skipping`);
});
