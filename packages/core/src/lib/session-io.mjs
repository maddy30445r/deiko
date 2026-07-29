/**
 * Reading a recorded session off disk.
 *
 * Every script that touches a session needs the same first step, and by the
 * fourth one there were three slightly different copies of it — one that threw
 * a different message, one that skipped the existence check. Nothing was broken
 * yet; this is here so nothing has to be.
 */

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

/**
 * Parse `events.jsonl` into an array of events.
 *
 * Malformed lines are skipped rather than fatal. The recorder appends from
 * detached tasks while the session runs, so a file read at the wrong moment can
 * end mid-line — losing the tail of a crash is very different from refusing to
 * read the 400 good events before it.
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
