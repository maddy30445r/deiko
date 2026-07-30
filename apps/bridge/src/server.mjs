#!/usr/bin/env node
/**
 * THE BRIDGE — an MCP stdio server that hands a Fovea brief to Claude Code.
 *
 *   claude mcp add fovea --scope user -- node <repo>/apps/bridge/src/server.mjs
 *
 * Everything upstream of here produces one artifact: a markdown brief that
 * describes what the developer pointed at and said, with a protocol for
 * consuming it. This server's whole job is delivery — getting that document
 * into a live Claude Code session without a copy-paste, and getting the crop
 * paths there safely.
 *
 * WHAT THIS DELIBERATELY IS NOT
 *
 * `bridge-design.md` specified tools over a `FoveaPlan` — steps, citations,
 * `mark_plan_done`. There is no plan. The renderer's governing decision is that
 * it does not write the task: it emits evidence and asks the consuming agent to
 * state its reading back, because the one hand-written brief that phrased the
 * task as imperatives ("Push X to Y") presumed work that already existed. A
 * bridge that serves plans would need Fovea to start writing them again, purely
 * so this file could have a richer type. So it serves the brief.
 *
 * THE PAYLOAD TEACHES ITS OWN CONSUMPTION
 *
 * Nothing here explains Fovea to the agent. The brief does that itself, in the
 * repo it lands in, with no CLAUDE.md and no pre-shared spec — which is what
 * makes it work in a repo Fovea has never seen. This file adds only what the
 * markdown cannot carry: absolute crop paths, and the fact that some are
 * missing on purpose.
 */

import { readFileSync, readdirSync, existsSync, mkdirSync, renameSync } from "node:fs";
import { join, basename } from "node:path";
import { homedir } from "node:os";

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

// Relative to this file, not to the cwd — the bridge is installed by pointing
// `claude mcp add` at this path and runs from wherever Claude Code happens to
// be.
import { assertNoSecrets } from "../../../scripts/lib/redact.mjs";

const OUTBOX = join(homedir(), ".fovea", "outbox");
const DONE = join(OUTBOX, "done");

// ── Reading the outbox ──────────────────────────────────────────────────────

/**
 * The pending brief, or null.
 *
 * `send-brief.mjs` refuses to leave more than one, so "the oldest" is a
 * tiebreak that should never be needed — but a directory is not a database and
 * this must not throw at the moment the user is asking for their task.
 */
function pending() {
  if (!existsSync(OUTBOX)) return null;
  const ids = readdirSync(OUTBOX)
    .filter((f) => f.endsWith(".md"))
    .map((f) => basename(f, ".md"))
    .sort();
  if (!ids.length) return null;

  const id = ids[0];
  const markdown = readFileSync(join(OUTBOX, `${id}.md`), "utf8");

  // The manifest is optional on purpose. A brief hand-copied into the outbox
  // is still a usable brief; it just travels without crop paths.
  let referents = [];
  try {
    referents = JSON.parse(readFileSync(join(OUTBOX, `${id}.json`), "utf8")).referents ?? [];
  } catch {
    referents = [];
  }
  return { id, markdown, referents };
}

/**
 * The crop section, appended to the brief.
 *
 * It ANNOUNCES crops; it does not list paths. That distinction is the whole
 * point. A path costs about twenty tokens to send, so listing all of them looks
 * free — but an image costs 15–25k tokens the moment an agent opens one, and a
 * menu of twenty-seven paths is an invitation to open twenty-seven. The worst
 * case was half a million tokens for one task, and nothing in the brief argued
 * against it.
 *
 * So the agent asks for crops by id, one at a time, and every released crop
 * stays reachable — which is strictly more available than trimming the list
 * would have been, while nothing is dangled.
 *
 * A withheld crop is stated, not omitted. Silence would read as "no screenshot
 * exists"; the agent should know an image was captured, that it is being kept
 * back, and why — a credential was on screen, or Fovea never read the pixels and
 * will not vouch for them.
 */
function cropSection(referents) {
  const released = referents.filter((r) => r.cropPath);
  const withheld = referents.filter((r) => r.cropWithheld);
  if (!released.length && !withheld.length) return "";

  const lines = ["", "---", "", "## Crops", ""];
  if (released.length) {
    lines.push(
      `${released.length} screenshot(s) of what was indicated are available through`,
      "the `get_crop` tool — pass a referent id such as `r3`.",
      "",
      "**Ask for one only when the text left something genuinely ambiguous.** The",
      "accessibility text in this brief is the literal string the app rendered; a",
      "crop is corroboration, and each one you open costs more than this entire",
      "brief did. Most tasks need none.",
      "",
    );
  }
  if (withheld.length) {
    lines.push(`**${withheld.length} crop(s) are withheld.** These exist and cannot be shared:`, "");
    for (const r of withheld) lines.push(`- ${r.id} — ${r.cropWithheld}`);
    lines.push(
      "",
      "Do not ask the user to paste them. If a withheld referent is load-bearing,",
      "say which one and what you needed from it.",
      "",
    );
  }
  return lines.join("\n");
}

/**
 * The delivered payload — and the last place it can still be stopped.
 *
 * The renderer guards `brief.md` before writing it, but a brief can reach this
 * outbox without ever having been through the renderer (hand-copied, or written
 * by an older version whose redaction had a hole). Fail-closed has to mean the
 * thing that crosses the wire.
 *
 * Guarded BEFORE the crop section is appended, deliberately. The guard's subject
 * is captured screen content; the crop section is text this file generates from
 * paths Fovea minted itself. Running it over both rejected every real brief —
 * an absolute POSIX path is a 40-character run of `[A-Za-z0-9/_]` and trips the
 * long-opaque-string rule. Widening the rule to admit paths would blunt it for
 * the content it exists to police, so the boundary sits here instead.
 */
function briefText(brief) {
  assertNoSecrets(brief.markdown);
  return brief.markdown + cropSection(brief.referents);
}

const NOTHING_PENDING =
  "No Fovea brief is pending.\n\n" +
  "A brief reaches this server only when the developer sends one:\n" +
  "  make brief SESSION=~/Documents/Fovea/<id>\n" +
  "  make send  SESSION=~/Documents/Fovea/<id>\n\n" +
  "Nothing is queued, so there is no task to start. Tell the user that rather " +
  "than looking for work to do.";

// ── The server ──────────────────────────────────────────────────────────────

const server = new McpServer({ name: "fovea", version: "0.1.0" });

server.registerTool(
  "get_brief",
  {
    title: "Get the pending Fovea brief",
    description:
      "Fetch the task brief the developer captured by pointing at things on screen " +
      "while narrating. Returns evidence — what was said, what was indicated, in " +
      "order — plus a protocol for grounding it in this repo. Call this when the " +
      "user refers to something they just recorded, showed, or pointed at.",
    inputSchema: {},
  },
  async () => {
    const brief = pending();
    return {
      content: [{ type: "text", text: brief ? briefText(brief) : NOTHING_PENDING }],
    };
  },
);

/**
 * How many crops one run will hand over before it starts pushing back.
 *
 * Not a hard limit on anything important — it is the difference between an agent
 * fetching the two images it needs and an agent working through all twenty-seven
 * at 20k tokens each. Eight is well past what any task here has needed, and it
 * caps the worst case near 200k instead of 500k. Reset when a brief is retired,
 * because the budget belongs to the task, not to the process.
 */
const CROP_BUDGET = 8;
let cropsServed = 0;

server.registerTool(
  "get_crop",
  {
    title: "Look at one captured screenshot",
    description:
      "Return the screenshot for one referent, by id (e.g. 'r3'). Use this only " +
      "when the brief's accessibility and OCR text left something genuinely " +
      "ambiguous — the text is authoritative and an image costs far more than the " +
      "whole brief. Most tasks need no crops at all.",
    inputSchema: {
      id: z.string().describe("Referent id from the brief, such as 'r3'."),
    },
  },
  async ({ id }) => {
    const brief = pending();
    const say = (text, isError = false) => ({ content: [{ type: "text", text }], isError });

    if (!brief) return say(NOTHING_PENDING, true);

    const referent = brief.referents.find((r) => r.id === id);
    if (!referent) {
      const ids = brief.referents.map((r) => r.id).join(", ");
      return say(`No referent ${id} in this brief. Available: ${ids || "none"}.`, true);
    }
    // The redaction gate decided this at render time and it is not re-litigated
    // here — a second implementation of "is this image safe" is a second chance
    // to get it wrong.
    if (referent.cropWithheld) {
      return say(`Crop for ${id} is withheld — ${referent.cropWithheld}.`, true);
    }
    if (!referent.cropPath) return say(`No crop was captured for ${id}.`, true);
    if (!existsSync(referent.cropPath)) {
      // Session directories are the user's; they get moved and deleted.
      return say(`Crop for ${id} is no longer on disk. The brief's text still stands.`, true);
    }
    if (cropsServed >= CROP_BUDGET) {
      return say(
        `Already served ${CROP_BUDGET} crops for this brief, which is more than a task ` +
          `normally needs. The accessibility text is authoritative — say which referent ` +
          `you are stuck on and what you were hoping to see in it.`,
        true,
      );
    }

    cropsServed += 1;
    return {
      content: [
        {
          type: "image",
          data: readFileSync(referent.cropPath).toString("base64"),
          mimeType: "image/png",
        },
      ],
    };
  },
);

server.registerTool(
  "mark_brief_done",
  {
    title: "Retire the pending Fovea brief",
    description:
      "Move the brief out of the outbox once its task is finished or abandoned. " +
      "Call this only after the work is done or the user has dropped it — an " +
      "unretired brief is how the developer knows something is still open.",
    inputSchema: {
      id: z.string().describe("Session id, as given at the top of the brief."),
      outcome: z
        .enum(["completed", "abandoned"])
        .describe("Whether the task was carried out or dropped."),
    },
  },
  async ({ id, outcome }) => {
    const md = join(OUTBOX, `${id}.md`);
    if (!existsSync(md)) {
      return {
        content: [{ type: "text", text: `No pending brief with id ${id}.` }],
        isError: true,
      };
    }
    mkdirSync(DONE, { recursive: true });
    // Moved, not deleted. The brief is the only record of what was asked for,
    // and "what did Fovea actually hand over" is the first question when a
    // grounded plan turns out to have been wrong.
    for (const ext of [".md", ".json"]) {
      const from = join(OUTBOX, `${id}${ext}`);
      if (existsSync(from)) renameSync(from, join(DONE, `${id}-${outcome}${ext}`));
    }
    cropsServed = 0;
    return { content: [{ type: "text", text: `${id} retired as ${outcome}.` }] };
  },
);

// The slash command: `/mcp__fovea__brief`. A prompt rather than only a tool
// because starting a captured task is something the USER decides, and a tool
// the model may or may not elect to call is not a way to hand over a task.
server.registerPrompt(
  "brief",
  {
    title: "Start the captured Fovea task",
    description: "Load the brief captured by pointing and narrating, and ground it in this repo.",
    argsSchema: {},
  },
  async () => {
    const brief = pending();
    return {
      messages: [
        {
          role: "user",
          content: {
            type: "text",
            // No framing added. The brief states its own protocol — repo
            // identification, provenance tagging, grounding before planning,
            // the branch question — and anything said here would be a second,
            // competing set of instructions for the same document.
            text: brief ? briefText(brief) : NOTHING_PENDING,
          },
        },
      ],
    };
  },
);

await server.connect(new StdioServerTransport());
