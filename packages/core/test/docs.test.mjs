// EVERY FILE THE DOCS POINT AT MUST EXIST.
//
// This folder was cleaned up because eight of thirteen documents made false
// claims, and the worst of them sent readers to files deleted two releases ago:
// "set `defaultRelayURL` in Credentials.swift", "the fix is one string in
// Handoff.command(for:)", a components table marking `apps/bridge/src/server.mjs`
// as built. Prose rots quietly; a path that no longer resolves is the one kind
// of rot a machine can catch.
//
// PATHS ONLY, NOT LINE NUMBERS. Line references drift on every edit and would
// fail constantly for no benefit — the signal would be trained away within a
// week. A missing *file* is unambiguous.
//
// `archive/` is exempt: those documents describe deleted designs, and naming the
// files that were deleted is the whole point of keeping them.
//
// A live doc can legitimately name a deleted file too — "`apps/bridge/` was
// removed" is the correct sentence, not rot. Those go in KNOWN_GONE below, one
// line each with a reason, rather than being waved through by a heuristic. An
// explicit list fails loudly when it needs updating; a clever rule about
// "mentioned near the word deleted" would quietly stop catching things.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

/** Every markdown file we hold to this standard. */
function docs() {
  const found = ["README.md"];
  const walk = (rel) => {
    for (const entry of readdirSync(join(repo, rel))) {
      const here = `${rel}/${entry}`;
      if (statSync(join(repo, here)).isDirectory()) {
        if (entry === "archive") continue; // exempt, deliberately — see header
        walk(here);
      } else if (entry.endsWith(".md")) {
        found.push(here.replace(/^\//, ""));
      }
    }
  };
  walk("mddocs");
  found.push("services/relay/README.md");
  return found;
}

/**
 * Repo paths a reader would actually try to open: markdown link targets, and
 * backticked strings that look like a path into a directory we own.
 *
 * Deliberately narrow. Matching every backticked token would drag in shell
 * snippets, JSON keys and prose, and a check that cries wolf is a check nobody
 * runs.
 */
const OURS = /^(apps|scripts|services|packages|mddocs|build)\//;

/**
 * Paths a live document names *because they are gone*. Each is correct prose.
 * Add here only when the doc's point is that the file no longer exists.
 */
const KNOWN_GONE = new Map([
  ["packages/protocol", "STATE.md records that it was deleted, unimported"],
  ["packages/protocol/src/plan.ts", "same — named as obsolete"],
  ["apps/bridge", "the handoff spec's Deleted list; removing it in 0.3.0 is the spec's subject"],
  [
    "scripts/generate_session_summary_backfill.py",
    "a path in ANOTHER repo, quoted verbatim inside a captured agent transcript",
  ],
  ["site/two-languages.html", "a page of the old site, retired when the new site shipped on 2026-09-24"],
]);

function referencedPaths(text, fromDir) {
  const out = new Set();

  for (const [, target] of text.matchAll(/\]\(([^)]+)\)/g)) {
    if (/^(https?:|#|mailto:)/.test(target)) continue;
    out.add(resolve(repo, fromDir, target.split("#")[0]));
  }

  for (const [, token] of text.matchAll(/`([^`\n]+)`/g)) {
    const path = token.trim();
    if (!OURS.test(path)) continue;
    if (/[ *?<>|]/.test(path)) continue; // globs and prose
    out.add(resolve(repo, path));
  }

  return [...out];
}

for (const doc of docs()) {
  test(`${doc} points only at files that exist`, () => {
    const text = readFileSync(join(repo, doc), "utf8");
    const missing = referencedPaths(text, dirname(doc))
      .filter((p) => !existsSync(p))
      .map((p) => p.slice(repo.length + 1))
      // Build outputs exist after a build and not in a clean checkout, so they
      // are neither stale nor gone — whether they exist says nothing about a doc.
      .filter((p) => !p.startsWith("build/"))
      .filter((p) => !KNOWN_GONE.has(p));

    assert.deepEqual(
      missing, [],
      `${doc} references ${missing.length} path(s) that do not exist:\n  ${missing.join("\n  ")}\n`
        + "Either the path is stale, or the doc is describing something that was deleted —\n"
        + "in which case say so, or move the document to mddocs/archive/.",
    );
  });
}

test("KNOWN_GONE only lists files that are actually gone", () => {
  // Otherwise the exemption list becomes its own quiet source of rot: a file
  // that comes back would stay permanently unchecked.
  const resurrected = [...KNOWN_GONE.keys()].filter((p) => existsSync(join(repo, p)));
  assert.deepEqual(resurrected, [], `these exist again — remove them from KNOWN_GONE: ${resurrected}`);
});

test("the docs index exists and is the entry point", () => {
  // BUILD_PLAN.md used to send every new session to the two most stale files in
  // the repo. mddocs/README.md replaced it; if it ever goes missing, that
  // pointer problem comes straight back.
  assert.ok(existsSync(join(repo, "mddocs/README.md")), "mddocs/README.md is the index");
});
