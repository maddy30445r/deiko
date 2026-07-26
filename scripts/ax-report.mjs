#!/usr/bin/env node
// Turns raw ax-probe JSON Lines into the T0.1 gate table.
//
//   node scripts/ax-report.mjs sessions/ax-native.jsonl [sessions/ax-poked.jsonl]
//
// Two questions decide the gate, and they are different questions:
//   1. Does AX resolve a usable element at a point?        → grounding works
//   2. Does a circled region resolve to MANY elements?     → grounding is
//      granular enough to be worth pointing at
// An app that answers yes to (1) and no to (2) supports AX but cannot ground a
// region — that distinction is invisible from point probing alone.

import { readFileSync } from "node:fs";

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("usage: node scripts/ax-report.mjs <probes.jsonl> [...]");
  process.exit(2);
}

/** An element is "usable" if it carries text we could ground a referent on. */
function usable(el) {
  const text = el.value ?? el.title ?? el.elementDescription ?? el.selectedText;
  if (text && text.trim().length > 0) return true;
  // A role-only hit on a real control still tells the model something.
  const inert = new Set(["AXUnknown", "AXGroup", "AXWindow", "AXScrollArea", "AXSplitGroup", undefined]);
  return !inert.has(el.role);
}

const apps = new Map();

for (const file of files) {
  let raw;
  try {
    raw = readFileSync(file, "utf8");
  } catch (err) {
    console.error(`✗ cannot read ${file}: ${err.message}`);
    process.exit(1);
  }

  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue; // stderr logs mixed in; skip quietly
    }
    if (event.type !== "probe") continue;

    const name = event.app?.name ?? "(unresolved)";
    if (!apps.has(name)) {
      apps.set(name, {
        bundleId: event.app?.bundleId,
        points: 0, pointsUsable: 0,
        regions: 0, regionSamples: 0, regionElements: 0,
        poked: 0, elapsed: [], roles: new Map(), errors: new Map(),
      });
    }
    const a = apps.get(name);
    const snap = event.snapshot;

    a.elapsed.push(snap.elapsedMs);
    if (snap.manualAccessibilityApplied) a.poked += 1;
    if (snap.error) a.errors.set(snap.error, (a.errors.get(snap.error) ?? 0) + 1);

    for (const el of snap.elements) {
      if (el.role) a.roles.set(el.role, (a.roles.get(el.role) ?? 0) + 1);
    }

    if (event.shape.kind === "region") {
      a.regions += 1;
      a.regionSamples += snap.samplesTested ?? 0;
      a.regionElements += snap.uniqueElements ?? 0;
    } else {
      a.points += 1;
      if (snap.elements.some(usable)) a.pointsUsable += 1;
    }
  }
}

if (apps.size === 0) {
  console.error("✗ no probe events found. Did you pipe ax-probe's STDOUT to the file?");
  console.error("  e.g. fovea-capture ax-probe --watch --verbose > sessions/ax.jsonl");
  process.exit(1);
}

const pct = (n, d) => (d === 0 ? "—" : `${Math.round((n / d) * 100)}%`);
const median = (xs) => {
  if (xs.length === 0) return 0;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
};

const rows = [...apps.entries()]
  .sort((a, b) => b[1].points + b[1].regions - (a[1].points + a[1].regions))
  .map(([name, a]) => ({
    App: name,
    Points: a.points,
    Usable: pct(a.pointsUsable, a.points),
    Regions: a.regions,
    // The granularity ratio. ~1.0 elements per region = a single flat container
    // came back; the app supports AX but cannot ground a circled area.
    "Elems/region": a.regions ? (a.regionElements / a.regions).toFixed(1) : "—",
    "Samples/elem":
      a.regionElements > 0 ? (a.regionSamples / a.regionElements).toFixed(1) : "—",
    Poked: a.poked,
    "p50 ms": median(a.elapsed).toFixed(0),
    "Top roles": [...a.roles.entries()]
      .sort((x, y) => y[1] - x[1])
      .slice(0, 3)
      .map(([r]) => r)
      .join(", ") || "—",
  }));

console.table(rows);

// ── Gate call ───────────────────────────────────────────────────────────────
// PASS: usable elements in ≥4 of 6 target apps, including ≥2 Electron apps.

const ELECTRON = /cursor|code|compass|postman|slack|discord|notion|figma/i;
const passing = [...apps.entries()].filter(
  ([name, a]) => name !== "(unresolved)" && a.points > 0 && a.pointsUsable / a.points >= 0.5,
);
const electronPassing = passing.filter(([name]) => ELECTRON.test(name));

console.log("");
console.log(`apps with usable point grounding: ${passing.length} — ${passing.map(([n]) => n).join(", ") || "none"}`);
console.log(`  of which Electron: ${electronPassing.length} — ${electronPassing.map(([n]) => n).join(", ") || "none"}`);

const pass = passing.length >= 4 && electronPassing.length >= 2;
console.log("");
console.log(pass
  ? "GATE: PASS — AX grounding holds. Proceed to M1 as specced."
  : "GATE: FAIL — vision+OCR becomes the primary grounding path. Re-plan T1.2 before building further.");

const coarse = [...apps.entries()].filter(
  ([, a]) => a.regions >= 3 && a.regionElements / a.regions < 2,
);
if (coarse.length > 0) {
  console.log("");
  console.log(`⚠ region grounding too coarse in: ${coarse.map(([n]) => n).join(", ")}`);
  console.log("  (a circled area collapses to ~1 element — freehand capture there needs OCR on the crop)");
}
