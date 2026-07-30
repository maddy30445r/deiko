#!/usr/bin/env node
/**
 * Drive the bridge over raw JSON-RPC, with no Claude Code involved.
 *
 *   node scripts/bridge-smoke.mjs
 *
 * The live test needs a real editor session, a real repo, and a human reading
 * the result — so it is slow, and it will be run rarely. This covers the part
 * that must not be allowed to rot in between: that the server speaks MCP, that
 * the prompt and both tools exist and answer, that an empty outbox says so
 * rather than throwing, and that a withheld crop path is genuinely absent from
 * what goes over the wire.
 */

import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import {
  existsSync, readdirSync, readFileSync, writeFileSync, rmSync, mkdirSync, mkdtempSync,
} from "node:fs";

import { connect } from "./lib/mcp-client.mjs";

const OUTBOX = join(homedir(), ".fovea", "outbox");

const { init, call, close } = await connect();

let failures = 0;
function check(label, ok, detail = "") {
  console.log(`${ok ? "✓" : "✗"} ${label}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures += 1;
}

check("initialize", init?.serverInfo?.name === "fovea", init?.serverInfo?.name);

const tools = (await call("tools/list")).tools.map((t) => t.name).sort();
check("tools", tools.join(",") === "get_brief,get_crop,mark_brief_done", tools.join(", "));

const prompts = (await call("prompts/list")).prompts.map((p) => p.name);
check("prompt", prompts.includes("brief"), prompts.join(", "));

const pendingIds = existsSync(OUTBOX)
  ? readdirSync(OUTBOX).filter((f) => f.endsWith(".md"))
  : [];

const got = await call("tools/call", { name: "get_brief", arguments: {} });
const text = got.content[0].text;

if (pendingIds.length) {
  check("get_brief returns the brief", text.includes("# Task brief"), `${text.length} chars`);

  // The properties worth asserting mechanically. Every other claim in this file
  // is about plumbing; these are about a credential reaching a model, and about
  // not handing an agent a menu of images to work through.
  const manifest = JSON.parse(
    readFileSync(join(OUTBOX, readdirSync(OUTBOX).find((f) => f.endsWith(".json"))), "utf8"),
  );
  const withheld = manifest.referents.filter((r) => r.cropWithheld);
  const released = manifest.referents.filter((r) => r.cropPath);

  const anyPath = manifest.referents.find((r) => r.cropPath && text.includes(r.cropPath));
  check(
    `no crop paths in the brief (${released.length} released, ${withheld.length} withheld)`,
    anyPath === undefined,
    anyPath ? `${anyPath.id} path is inlined` : "",
  );

  if (released.length) {
    const img = await call("tools/call", { name: "get_crop", arguments: { id: released[0].id } });
    check(
      `get_crop(${released[0].id}) returns an image`,
      img.content?.[0]?.type === "image" && img.content[0].data?.length > 1000,
      img.content?.[0]?.type,
    );
  }
  if (withheld.length) {
    const no = await call("tools/call", { name: "get_crop", arguments: { id: withheld[0].id } });
    const body = no.content?.[0]?.text ?? "";
    check(
      `get_crop(${withheld[0].id}) refuses a withheld crop`,
      no.isError === true && no.content[0].type === "text" && body.includes("withheld"),
      body.slice(0, 40),
    );
  }

  const unknown = await call("tools/call", { name: "get_crop", arguments: { id: "r99999" } });
  check("get_crop on an unknown id is an error, not a crash", unknown.isError === true);

  if (released.length) {
    // Drain the budget. The 9th release must be refused — that bound is the
    // difference between an agent opening two images and opening twenty-seven.
    let refused = null;
    for (let i = 0; i < 12 && refused === null; i++) {
      const r = released[i % released.length];
      const res = await call("tools/call", { name: "get_crop", arguments: { id: r.id } });
      if (res.isError && (res.content?.[0]?.text ?? "").includes("more than a task")) refused = i;
    }
    check("the crop budget is enforced", refused !== null, refused === null ? "never refused" : `refused after ${refused + 1} more`);
  }
} else {
  check("empty outbox explains itself", text.includes("No Fovea brief is pending"));
  const done = await call("tools/call", {
    name: "mark_brief_done",
    arguments: { id: "does-not-exist", outcome: "abandoned" },
  });
  check("mark_brief_done on a missing id is an error, not a crash", done.isError === true);
}

const prompt = await call("prompts/get", { name: "brief", arguments: {} });
check("prompt returns one user message", prompt.messages?.[0]?.role === "user");

// The guard, proved rather than asserted. A brief that somehow arrives in the
// outbox carrying a credential — hand-copied, or rendered by a version whose
// redaction had a hole — must be refused, not delivered. Written to a scratch
// outbox entry and removed immediately whatever happens.
{
  const poisoned = join(OUTBOX, "0000-guard-check.md");
  writeFileSync(
    poisoned,
    "# Task brief — guard check\n\n```\naccount key: " + "A".repeat(44) + "==\n```\n",
  );
  try {
    const res = await call("tools/call", { name: "get_brief", arguments: {} });
    const out = res.content?.[0]?.text ?? "";
    check(
      "a credential-bearing brief is refused, not delivered",
      res.isError === true || !out.includes("A".repeat(44)),
      res.isError ? "refused" : "DELIVERED THE SECRET",
    );
  } catch (err) {
    // An MCP-level error is also a refusal — the payload did not go out.
    check("a credential-bearing brief is refused, not delivered", true, "refused");
  } finally {
    rmSync(poisoned, { force: true });
  }
}

// The review window's summary is the only interpreted text Fovea produces, and
// the whole design depends on it stopping at the developer's screen: the agent
// is asked to state its own reading back, which it cannot honestly do if a
// reading is already sitting in the brief.
//
// `send-brief.mjs` copies `brief.md` and `brief.json` and nothing else, so the
// guarantee is structural — but "structural" is a claim about code that someone
// will edit. Prove it instead, in a scratch HOME so the real outbox is untouched.
{
  const home = mkdtempSync(join(tmpdir(), "fovea-send-"));
  const session = join(home, "20990101-000000");
  const sentinel = "SUMMARY-MUST-NOT-TRAVEL-8f3a2c";
  mkdirSync(session, { recursive: true });
  writeFileSync(join(session, "brief.md"), "# Task brief — send check\n\nEvidence only.\n");
  writeFileSync(join(session, "brief.json"), JSON.stringify({ sessionId: "x", referents: [] }));
  writeFileSync(join(session, "review-summary.txt"), `${sentinel}\n`);

  try {
    execFileSync(process.execPath, [new URL("./send-brief.mjs", import.meta.url).pathname, session], {
      env: { ...process.env, HOME: home },
      stdio: "pipe",
    });
    const outbox = join(home, ".fovea", "outbox");
    const delivered = readdirSync(outbox).filter((f) => !f.startsWith("."));
    const leaked = delivered
      .filter((f) => f.endsWith(".md") || f.endsWith(".json"))
      .some((f) => readFileSync(join(outbox, f), "utf8").includes(sentinel));

    check(
      "the review summary is not delivered to the agent",
      !leaked && !delivered.some((f) => f.includes("summary")),
      leaked ? "SENT THE SUMMARY" : delivered.join(", "),
    );
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

close();
console.log(failures ? `\n${failures} check(s) failed` : "\nall checks passed");
process.exit(failures ? 1 : 0);
