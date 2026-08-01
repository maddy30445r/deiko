#!/usr/bin/env node
/**
 * Put a rendered brief where Claude Code can fetch it.
 *
 *   node scripts/send-brief.mjs ~/Documents/Fovea/<id>
 *
 * THIS IS THE APPROVAL STEP. `bridge-design.md` sketched a separate
 * `approve-plan.mjs` standing in for the review UI, on the assumption that
 * Fovea would produce a plan somebody signs off. It does not — the renderer
 * deliberately refuses to write the task and emits evidence instead. So what is
 * left to approve is simply *which session goes*, and that is a copy.
 *
 * Deliberately not automatic on session end. A tool that injects itself into
 * your editor the moment you stop talking is a tool you stop trusting; the
 * outbox is empty until you say so.
 */

import { copyFileSync, existsSync, mkdirSync, readdirSync, renameSync } from "node:fs";
import { resolve, join, basename } from "node:path";
import { homedir } from "node:os";

export const OUTBOX = join(homedir(), ".fovea", "outbox");
export const DONE = join(OUTBOX, "done");

const arg = process.argv[2];
if (!arg) {
  console.error("usage: node scripts/send-brief.mjs <session-dir>");
  console.error("  render it first:  make brief SESSION=<session-dir>");
  process.exit(2);
}

const dir = resolve(arg.replace(/^~/, homedir()));
const id = basename(dir);

const md = join(dir, "brief.md");
const manifest = join(dir, "brief.json");
if (!existsSync(md) || !existsSync(manifest)) {
  console.error(`✗ no rendered brief in ${dir}`);
  console.error(`  render it first:  make brief SESSION=${arg}`);
  process.exit(1);
}

mkdirSync(OUTBOX, { recursive: true });

// One at a time. Two pending briefs means the agent has to choose, and the
// answer to "which task am I doing" should never come from a directory listing.
//
// Anything already pending is SUPERSEDED, not a reason to refuse. This used to
// exit non-zero and tell you to clear the outbox by hand, which sounds careful
// and isn't: a brief only leaves the outbox when the consuming agent calls
// `mark_brief_done`, and an agent that read a brief and then wandered off never
// does. One un-marked brief from last week jammed every send after it, with the
// error surfacing in the review window as a small orange line.
//
// The invariant that check protects — exactly one brief pending — still holds.
// What changes is which one wins: the developer pressing send now, rather than
// whichever file happened to be left behind.
const pending = readdirSync(OUTBOX).filter(
  (f) => (f.endsWith(".md") || f.endsWith(".json")) && !f.startsWith(id),
);
if (pending.length) {
  mkdirSync(DONE, { recursive: true });
  for (const file of pending) {
    const dot = file.lastIndexOf(".");
    const superseded = `${file.slice(0, dot)}-superseded${file.slice(dot)}`;
    renameSync(join(OUTBOX, file), join(DONE, superseded));
  }
  // Said out loud, never silently. Superseding is the right default and still a
  // thing the developer should be able to notice they did.
  const names = [...new Set(pending.map((f) => f.replace(/\.(md|json)$/, "")))];
  console.error(`  superseded ${names.join(", ")} → ${DONE}`);
}

copyFileSync(md, join(OUTBOX, `${id}.md`));
copyFileSync(manifest, join(OUTBOX, `${id}.json`));

console.error(`✓ ${id} → ${OUTBOX}`);
// The command name DIFFERS BY HOST and getting it wrong is silent: Claude Code
// will not submit an unresolved slash command, so the wrong form sits typed in
// the input looking like a broken keystroke. Both are printed rather than
// guessing which one the reader is in front of.
console.error(`  in Claude Code:  /fovea:brief        (VS Code extension)`);
console.error(`                   /mcp__fovea__brief  (CLI)`);
