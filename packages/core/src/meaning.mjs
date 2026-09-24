#!/usr/bin/env node
/**
 * The meaning model, from the command line and from the app.
 *
 *   node scripts/meaning.mjs status            → "ready <model>" | "missing <model>" | "off"
 *   node scripts/meaning.mjs download [--hf]   → "progress <done> <total>" lines, then "ready <model>";
 *                                                "failed <why>" and exit 1 on any failure
 *   node scripts/meaning.mjs backfill [<root>] → "backfilled <n>"; "failed <why>" and exit 1 with no model
 *
 * The model is DEIKO_MEANING_MODEL (default harrier-oss-v1-270m; "off" turns
 * meaning off), kept under DEIKO_MODEL_DIR (default
 * ~/Library/Application Support/Deiko/models). Downloads come from Deiko's
 * own storage (DEIKO_MODEL_BASE_URL overrides it), or from Hugging Face with
 * --hf; every file is SHA-256 checked either way.
 *
 * BACKFILL WRITES INTO THE BOARD (<session>/meaning.f32). Only the app, once
 * after a download, and the controller (`make meaning-backfill`) run it.
 */
import { readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

import { STAMP, readBriefLine } from "./lib/context.mjs";
import { briefText, currentModel, download, isReady, loadModel, vectorIsCurrent, writeVector } from "./lib/meaning.mjs";

const [command, arg] = process.argv.slice(2);
const key = currentModel();

if (command === "status") {
  console.log(!key ? "off" : isReady(key) ? `ready ${key}` : `missing ${key}`);
} else if (command === "download") {
  if (!key) {
    console.log("off");
    process.exit(0);
  }
  let last = 0;
  try {
    await download({
      key,
      fromHF: arg === "--hf",
      onProgress: (done, total) => {
        const now = Date.now();
        if (now - last < 500 && done < total) return;
        last = now;
        console.log(`progress ${done} ${total}`);
      },
    });
    console.log(`ready ${key}`);
  } catch (err) {
    console.log(`failed ${String(err?.message ?? err).replace(/\s+/g, " ").slice(0, 120)}`);
    process.exit(1);
  }
} else if (command === "backfill") {
  const root = resolve((arg ?? "~/Documents/Deiko").replace(/^~/, homedir()));
  const model = await loadModel(key);
  if (!model) {
    console.log("failed no meaning model on this Mac");
    process.exit(1);
  }
  let n = 0;
  for (const name of readdirSync(root).filter((x) => STAMP.test(x)).sort()) {
    const dir = join(root, name);
    const me = readBriefLine(dir);
    if (me.narration == null) continue;
    const text = briefText(me);
    if (!text.trim() || vectorIsCurrent(dir, model.key, text)) continue;
    const vec = await model.embed(text, "doc");
    if (!vec) continue;
    writeVector(dir, model.key, vec, text);
    n += 1;
  }
  console.log(`backfilled ${n}`);
} else {
  console.error("usage: node scripts/meaning.mjs status | download [--hf] | backfill [<root>]");
  process.exit(2);
}
