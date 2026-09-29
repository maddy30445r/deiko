#!/usr/bin/env node
/**
 * Scores how well a session grounded: whether each referent knows what it is.
 *
 *   node evals/grounding.mjs ~/Library/Application\ Support/Deiko/<id>
 *
 * A perfectly bound referent that resolved to `Caret Right Icon` tells a coding
 * agent nothing, so this counts how many referents carry something usable.
 */

import { resolve, basename } from "node:path";
import { loadEvents } from "@deiko/core/lib/session-io.mjs";

/**
 * Mirrors `groundsContent` in
 * apps/macos/Sources/DeikoGrounding/Grounding.swift; change both. Kept here so
 * the report can grade sessions recorded before the Swift rule existed.
 */
const PRESENTATIONAL = new Set(["AXImage", "AXDisclosureTriangle"]);

const present = (s) => typeof s === "string" && s.trim().length > 0;

function groundsContent(el) {
  if (present(el.value) || present(el.selectedText) || present(el.title)) return true;
  if (!present(el.elementDescription)) return false;
  return !PRESENTATIONAL.has(el.role);
}

/** Any non-empty string at all. */
function hasAnyText(el) {
  return [el.value, el.title, el.elementDescription, el.selectedText].some(present);
}

/**
 * Grades: content (accessibility named something the agent can act on),
 * ornament (accessibility answered with furniture such as a caret or icon
 * label), ocr-only (the pixels carried the meaning), nothing (the referent is
 * lost, the number that matters). Marks: ✓ accessibility did its job, ~ the
 * crop saved it, ✗ the referent is lost.
 */
const MARKS = {
  content: "✓",
  "ocr-only": "~",
  "ornament+ocr": "~",
  ornament: "✗",
  nothing: "✗",
};

function grade(probe) {
  const elements = probe?.snapshot?.elements ?? [];
  const ocr = (probe?.crop?.ocr ?? []).filter((o) => present(o.text));

  if (elements.some(groundsContent)) return "content";
  if (ocr.length) return elements.some(hasAnyText) ? "ornament+ocr" : "ocr-only";
  if (elements.some(hasAnyText)) return "ornament";
  return "nothing";
}

const arg = process.argv[2];
if (!arg) {
  console.error("usage: node evals/grounding.mjs <session-dir>");
  process.exit(2);
}
const dir = resolve(arg.replace(/^~/, process.env.HOME ?? "~"));

let events;
try {
  events = loadEvents(dir);
} catch (err) {
  console.error(`✗ ${err.message}`);
  process.exit(1);
}

const probes = events.filter((e) => e.type === "probe");
if (!probes.length) {
  console.error(`✗ no probe events in ${dir} — nothing was grounded`);
  process.exit(1);
}

console.log(`session: ${basename(dir)}`);
console.log(`referents: ${probes.length}\n`);

const counts = {};
const apps = new Set();
let missingApp = 0;
let missingCrop = 0;

for (const [i, probe] of probes.entries()) {
  const g = grade(probe);
  counts[g] = (counts[g] ?? 0) + 1;

  const app = probe.app?.name;
  if (app) apps.add(app);
  else missingApp += 1;
  if (!probe.crop?.path) missingCrop += 1;

  const elements = probe.snapshot?.elements ?? [];
  const lead = elements.find(groundsContent) ?? elements[0];
  const text =
    lead?.value || lead?.title || lead?.elementDescription || lead?.selectedText || "";
  const ocrCount = (probe.crop?.ocr ?? []).length;

  const mark = MARKS[g];
  console.log(
    `${mark} R${String(i + 1).padStart(2)} ${(probe.shape?.kind ?? "?").padEnd(6)} ` +
      `${(app ?? "?").padEnd(18).slice(0, 18)} ${g.padEnd(12)} ` +
      `els=${String(elements.length).padStart(2)} ocr=${String(ocrCount).padStart(2)} ` +
      `${(lead?.role ?? "-").padEnd(16).slice(0, 16)} ${JSON.stringify(text.slice(0, 46))}`
  );
}

const order = ["content", "ocr-only", "ornament+ocr", "ornament", "nothing"];
console.log("\ngrades:");
for (const g of order) {
  if (counts[g]) console.log(`  ${g.padEnd(13)} ${counts[g]}`);
}

const usable = (counts.content ?? 0) + (counts["ocr-only"] ?? 0) + (counts["ornament+ocr"] ?? 0);
const lost = (counts.nothing ?? 0) + (counts.ornament ?? 0);
console.log(
  `\ncarrying something usable: ${usable}/${probes.length}` +
    `  ·  accessibility named content: ${counts.content ?? 0}/${probes.length}`
);

// Checks that a session pointed across 3+ apps into a populated referent stack,
// with correct app/element/crop per referent.
console.log("\nM1 done-when:");
const checks = [
  [apps.size >= 3, `3+ apps in one session — ${apps.size} (${[...apps].join(", ") || "none"})`],
  [missingApp === 0, `every referent has an app identity — ${probes.length - missingApp}/${probes.length}`],
  [missingCrop === 0, `every referent has a crop — ${probes.length - missingCrop}/${probes.length}`],
  [lost === 0, `no referent grounded to nothing usable — ${lost} lost`],
];
for (const [ok, label] of checks) console.log(`  ${ok ? "✅" : "❌"} ${label}`);

process.exit(checks.every(([ok]) => ok) ? 0 : 1);
