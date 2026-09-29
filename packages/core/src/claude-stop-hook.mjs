#!/usr/bin/env node
// Claude Code Stop hook: before the agent finishes a Deiko brief, make sure it
// saved its report. Reads the hook's JSON on stdin and, when the prompt this
// turn answers is a brief with no outcome written since it arrived, blocks the
// stop once with a reason that asks for one. Any failure lets the agent stop.
import { readFileSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MARKER = /save_outcome tool if it is connected \(brief (\d{8}-\d{6})\), or else by rewriting (\S.*?\/outcome\.md) under four headings/;

function text(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b?.type === "text").map((b) => b.text).join("\n");
}

/**
 * The Deiko brief this turn answers: the latest prompt the person sent, when
 * that prompt is a brief. A brief pasted earlier, then talked about, is not
 * this turn's work, so later turns are left alone. Tool results, meta entries
 * and the hook's own feedback are not prompts.
 */
export function latestBrief(transcript) {
  let latest = null;
  for (const line of transcript.split("\n")) {
    if (!line.includes('"user"')) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    if (entry.type !== "user" || entry.isMeta) continue;
    const body = text(entry.message?.content);
    if (!body || body.startsWith("Stop hook feedback")) continue;
    const m = MARKER.exec(body);
    latest = m ? { id: m[1], outcome: m[2], at: Date.parse(entry.timestamp) || 0 } : null;
  }
  return latest;
}

/** The hook's answer for one Stop event, or null to let the agent stop. */
export function decide(input, { read = (p) => readFileSync(p, "utf8"), mtime = (p) => statSync(p).mtimeMs } = {}) {
  if (!input || input.stop_hook_active || !input.transcript_path) return null;
  let transcript;
  try { transcript = read(input.transcript_path); } catch { return null; }
  const brief = latestBrief(transcript);
  if (!brief) return null;
  let saved = 0;
  try { saved = mtime(brief.outcome); } catch { /* not written yet */ }
  if (saved >= brief.at) return null;
  return {
    decision: "block",
    reason: `Before you finish: save what you did for Deiko brief ${brief.id} with the deiko-memory save_outcome tool (Did, Decided, Open, Files), or write ${brief.outcome} under those headings. Then stop.`,
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let raw = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => { raw += chunk; });
  process.stdin.on("end", () => {
    try {
      const answer = decide(JSON.parse(raw));
      if (answer) process.stdout.write(JSON.stringify(answer));
    } catch { /* never stand in the agent's way */ }
    process.exit(0);
  });
}
