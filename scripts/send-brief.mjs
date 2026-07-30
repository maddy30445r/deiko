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

import { copyFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
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
const pending = readdirSync(OUTBOX).filter((f) => f.endsWith(".md") && !f.startsWith(id));
if (pending.length) {
  console.error(`✗ ${pending.length} brief(s) already pending: ${pending.join(", ")}`);
  console.error(`  finish or clear them first:  rm ${join(OUTBOX, "*.md")}`);
  process.exit(1);
}

copyFileSync(md, join(OUTBOX, `${id}.md`));
copyFileSync(manifest, join(OUTBOX, `${id}.json`));

console.error(`✓ ${id} → ${OUTBOX}`);
console.error(`  in Claude Code:  /mcp__fovea__brief`);
