/**
 * Reading a recorded session off disk. Every script that touches a session
 * needs the same first step; it lives here so there is one copy.
 */

import { copyFileSync, readFileSync, existsSync, mkdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

/**
 * Write a board file so it is either the old version or the new one, never half.
 *
 * `writeFileSync` empties the file and then writes it: a quit, a crash or a full
 * disk in between leaves it empty or cut off, and the next reader takes that for
 * the truth. Writing a temp file beside it and renaming it over the original is
 * one step the filesystem does all at once.
 */
export function writeAtomic(path, data) {
  const tmp = `${path}.tmp-${process.pid}-${Date.now()}`;
  try {
    writeFileSync(tmp, data);
    renameSync(tmp, path);
  } catch (e) {
    rmSync(tmp, { force: true });
    throw e;
  }
}

/** A task or project list: the version it replaces stays beside it as
 *  `<name>.prev`, one step back when an edit goes wrong. */
export function writeList(path, data) {
  if (existsSync(path)) copyFileSync(path, `${path}.prev`);
  writeAtomic(path, data);
}

/** A file's identity for "changed since?": inode (a rename-into-place moves
 *  it), size and mtime in ns. "-" when there is no such file. */
export function fileStamp(path) {
  const s = statSync(path, { bigint: true, throwIfNoEntry: false });
  return s ? `${s.ino}:${s.size}:${s.mtimeNs}` : "-";
}

/**
 * One writer at a time for the board's shared lists (`tasks.json`,
 * `collections.json`). The app renames a task while a filing adds one: both
 * read, both write, and one change is lost. A lock folder beside them, taken
 * the same way by `BoardLock` in the app. Waits up to `waitMs`, then goes
 * ahead anyway (a filing must never fail over this); a lock older than
 * `staleMs` was left by a crash and is broken.
 *
 * Two writers breaking the same crashed lock in the same instant can both get
 * in (the break doesn't check whose lock it removes), and one edit is lost.
 * That needs a crash inside a lock held for milliseconds and two writers right
 * after.
 */
export function withBoardLock(root, fn, { waitMs = 3000, staleMs = 15000 } = {}) {
  const lock = join(root, ".lists.lock");
  const until = Date.now() + waitMs;
  let held = false;
  while (!held) {
    try {
      mkdirSync(lock);
      held = true;
    } catch (e) {
      if (e?.code !== "EEXIST") break;
      const age = Date.now() - (statSync(lock, { throwIfNoEntry: false })?.mtimeMs ?? Date.now());
      if (age > staleMs) { rmSync(lock, { recursive: true, force: true }); continue; }
      if (Date.now() > until) break;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
    }
  }
  try {
    return fn();
  } finally {
    if (held) rmSync(lock, { recursive: true, force: true });
  }
}

/**
 * A JSON list that is about to be rewritten (`tasks.json`, `collections.json`).
 *
 * `[]` when the file does not exist yet, or is empty (a crash already lost it;
 * refusing would block every write from then on). A file with text that will
 * not parse (half-written by a crash mid-save, or edited by hand) is `null`,
 * and the caller must skip its write: treating it as empty and appending one
 * row would replace every task title, or every project, with that single row.
 * Readers that never write can stay forgiving; this one cannot.
 */
export function readListToRewrite(path) {
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (e) {
    return e?.code === "ENOENT" ? [] : null;
  }
  // Nothing left to lose: an empty file is a fresh list, or it would refuse every write from now on.
  if (!text.trim()) return [];
  try {
    const list = JSON.parse(text);
    return Array.isArray(list) ? list : null;
  } catch {
    return null;
  }
}

/**
 * Parse `events.jsonl` into an array of events.
 *
 * Malformed lines are skipped rather than fatal: the recorder appends from
 * detached tasks while the session runs, so a file read at the wrong moment
 * can end mid-line, and losing the tail beats refusing to read the good
 * events before it.
 */
export function loadEvents(sessionDir) {
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

/** A named file from a session directory, with a message that says which. */
export function loadFile(sessionDir, file) {
  const path = join(sessionDir, file);
  if (!existsSync(path)) throw new Error(`missing ${file} in ${sessionDir}`);
  return readFileSync(path, "utf8");
}

/** Written by the app beside a session's WAVs once its on-device recognition
 *  has finished, whether or not every hold got a timing file. */
export const TIMINGS_DONE = "timings.done";

/**
 * A hold's timing file, which the app is recognising while this script uploads.
 * Resolves with the path once it is there; null once the app has finished
 * without it (or the deadline passes), so the caller takes its own path.
 */
export async function awaitPrecomputed(out, { deadline }) {
  const done = join(dirname(out), TIMINGS_DONE);
  while (Date.now() < deadline) {
    if (existsSync(out)) return out;
    if (existsSync(done)) return existsSync(out) ? out : null;
    await sleep(100);
  }
  return null;
}
