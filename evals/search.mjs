#!/usr/bin/env node
/**
 * How well the board's search (and agents' search_briefs) finds past work,
 * against a hand-made set of queries. READ-ONLY.
 *
 *   node scripts/eval-search.mjs [--board ~/Library/Application\ Support/Deiko]
 *     [--queries ~/Documents/Deiko-eval/search-queries.json] [--model <key>|off] [--all]
 *
 * Each query is `{ kind, q, want: [task ids] }`; a hit is any brief of a
 * wanted task. Runs the shipped ranking itself (`searchBriefs` in
 * memory-mcp.mjs), so what this scores is what people get. Kinds, as the set
 * was written on 27 Sep 2026: paraphrase, vague, matching, exact, garbled,
 * hinglish. --all lists every query that missed #1.
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const args = process.argv.slice(2);
const value = (name, fallback) => { const i = args.indexOf(name); return i > -1 && args[i + 1] ? args[i + 1] : fallback; };
const home = (p) => resolve(String(p).replace(/^~/, homedir()));
process.env.DEIKO_ROOT = home(value("--board", join(homedir(), "Library", "Application Support", "Deiko")));
const model = value("--model");
if (model) process.env.DEIKO_MEANING_MODEL = model;
const queries = JSON.parse(readFileSync(home(value("--queries", join(homedir(), "Documents", "Deiko-eval", "search-queries.json"))), "utf8"));

const { searchBriefs } = await import("./memory-mcp.mjs");
const rows = [];
for (const { kind, q, want } of queries) {
  const found = await searchBriefs({ query: q, limit: 20 });
  const at = found.findIndex((r) => want.includes(r.task)) + 1;
  rows.push({ kind, q, at });
}
const tally = (xs) => ({
  n: xs.length,
  hit1: xs.filter((r) => r.at === 1).length,
  hit3: xs.filter((r) => r.at >= 1 && r.at <= 3).length,
  mrr: (xs.reduce((a, r) => a + (r.at ? 1 / r.at : 0), 0) / (xs.length || 1)).toFixed(2),
});
const all = tally(rows);
console.log(`model: ${process.env.DEIKO_MEANING_MODEL ?? "default"} · ${all.n} queries`);
console.log(`right at #1 ${all.hit1}/${all.n} · in top 3 ${all.hit3}/${all.n} · MRR ${all.mrr}`);
for (const kind of [...new Set(rows.map((r) => r.kind))]) {
  const t = tally(rows.filter((r) => r.kind === kind));
  console.log(`  ${kind.padEnd(11)} #1 ${t.hit1}/${t.n}  top 3 ${t.hit3}/${t.n}`);
}
if (args.includes("--all")) for (const r of rows.filter((x) => x.at !== 1)) console.log(`✗ ${r.kind.padEnd(11)} ${r.q}  → ${r.at ? `#${r.at}` : "not found"}`);
