// Every repo path a document links to or names in backticks must exist.
// Paths only, not line numbers: line references drift on every edit.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

function docs() {
  const found = ["README.md", "services/relay/README.md"].filter((f) => existsSync(join(repo, f)));
  const walk = (rel) => {
    if (!existsSync(join(repo, rel))) return;
    for (const entry of readdirSync(join(repo, rel))) {
      const here = `${rel}/${entry}`;
      if (statSync(join(repo, here)).isDirectory()) walk(here);
      else if (entry.endsWith(".md")) found.push(here);
    }
  };
  walk("docs");
  for (const f of ["CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md"]) if (existsSync(join(repo, f))) found.push(f);
  return found;
}

// Backticked tokens count only when they start with a directory we own, so
// shell snippets and JSON keys are not mistaken for paths.
const OURS = /^(apps|scripts|services|packages|evals|docs|build)\//;

function referencedPaths(text, fromDir) {
  const out = new Set();
  for (const [, target] of text.matchAll(/\]\(([^)]+)\)/g)) {
    if (/^(https?:|#|mailto:)/.test(target)) continue;
    out.add(resolve(repo, fromDir, target.split("#")[0]));
  }
  for (const [, token] of text.matchAll(/`([^`\n]+)`/g)) {
    const path = token.trim();
    if (!OURS.test(path) || /[ *?<>|]/.test(path)) continue;
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
      .filter((p) => !p.startsWith("build/")); // build outputs are absent in a clean checkout
    assert.deepEqual(missing, [], `${doc} references missing path(s):\n  ${missing.join("\n  ")}`);
  });
}
