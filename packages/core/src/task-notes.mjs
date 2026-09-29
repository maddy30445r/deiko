#!/usr/bin/env node
// Rebuild every task note under a board root now, not at the next brief:
// the app runs this after "Forget" or "Edit" on a task's notes, so the note
// an agent may already be reading stops quoting what was taken back.
//
//   node packages/core/src/task-notes.mjs <board root>
import { resolve } from "node:path";
import { writeTaskNotes } from "./lib/tasks.mjs";

if (!process.argv[2]) {
  console.error("usage: task-notes.mjs <board root>");
  process.exit(2);
}
writeTaskNotes(resolve(process.argv[2]));
