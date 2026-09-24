import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync } from "node:fs";
import http from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  DEFAULT_MODEL, MODELS, briefText, currentModel, download, finish, isReady, loadModel,
  readVector, vectorIsCurrent, writeVector,
} from "../lib/meaning.mjs";
import { cosine } from "../lib/tasks.mjs";

const close = (a, b) => a.length === b.length && [...a].every((x, i) => Math.abs(x - b[i]) < 1e-6);

test("finish normalises, truncates and normalises again", () => {
  const v = finish(Float32Array.from([3, 4, 12]), 2);
  assert.equal(v.length, 2);
  assert.ok(close(v, [0.6, 0.8]));
  assert.ok(close(finish(Float32Array.from([0, 5]), 2), [0, 1]));
});

test("the model is chosen by DEIKO_MEANING_MODEL, and off means none", () => {
  const was = process.env.DEIKO_MEANING_MODEL;
  try {
    delete process.env.DEIKO_MEANING_MODEL;
    assert.equal(currentModel(), DEFAULT_MODEL);
    process.env.DEIKO_MEANING_MODEL = "embeddinggemma-300m";
    assert.equal(currentModel(), "embeddinggemma-300m");
    for (const off of ["off", "nonsense"]) {
      process.env.DEIKO_MEANING_MODEL = off;
      assert.equal(currentModel(), null);
    }
  } finally {
    if (was === undefined) delete process.env.DEIKO_MEANING_MODEL; else process.env.DEIKO_MEANING_MODEL = was;
  }
  assert.equal(DEFAULT_MODEL, "harrier-oss-v1-270m");
  assert.equal(MODELS[DEFAULT_MODEL].dims, 640);
  assert.equal(MODELS["embeddinggemma-300m"].dims, 256);
});

test("a brief's text for meaning is what was said, never the screen's words", () => {
  const text = briefText({ summaryLine: "Fix the chart.", narration: "the graph drops", windows: ["Signups — build"], screenTerms: ["secretword"] });
  assert.equal(text, "Fix the chart.\nthe graph drops\nSignups — build");
});

test("a vector round-trips beside its brief, and a stale or foreign one is not used", () => {
  const dir = mkdtempSync(join(tmpdir(), "deiko-meaning-"));
  const vec = finish(Float32Array.from([1, 2, 3]), 3);
  writeVector(dir, "harrier-oss-v1-270m", vec, "the graph drops");
  assert.ok(close(readVector(dir, "harrier-oss-v1-270m"), vec));
  assert.equal(readVector(dir, "embeddinggemma-300m"), null, "another model's numbers mean nothing here");
  assert.equal(vectorIsCurrent(dir, "harrier-oss-v1-270m", "the graph drops"), true);
  assert.equal(vectorIsCurrent(dir, "harrier-oss-v1-270m", "the graph drops, edited"), false);
  assert.equal(readVector(mkdtempSync(join(tmpdir(), "deiko-meaning-")), "harrier-oss-v1-270m"), null);
});

test("no model on this Mac is no model, not an error", async () => {
  const was = process.env.DEIKO_MODEL_DIR;
  process.env.DEIKO_MODEL_DIR = mkdtempSync(join(tmpdir(), "deiko-models-"));
  try {
    assert.equal(isReady(DEFAULT_MODEL), false);
    assert.equal(await loadModel(DEFAULT_MODEL), null);
    assert.equal(await loadModel(null), null);
  } finally {
    if (was === undefined) delete process.env.DEIKO_MODEL_DIR; else process.env.DEIKO_MODEL_DIR = was;
  }
});

async function serve(files) {
  const server = http.createServer((req, res) => {
    const body = files[req.url];
    if (!body) { res.writeHead(404); res.end(); return; }
    res.writeHead(200); res.end(body);
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  server.unref();
  return { url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((r) => server.close(r)) };
}

test("a download is checked against its SHA-256 and marked complete only when every file is", async () => {
  const was = process.env.DEIKO_MODEL_DIR;
  process.env.DEIKO_MODEL_DIR = mkdtempSync(join(tmpdir(), "deiko-models-"));
  const a = Buffer.from("model bytes"), b = Buffer.from("tokenizer bytes");
  const sha = (x) => createHash("sha256").update(x).digest("hex");
  const good = { files: [{ path: "onnx/a.onnx", bytes: a.length, sha256: sha(a) }, { path: "t.json", bytes: b.length, sha256: sha(b) }] };
  const site = await serve({ "/fake/onnx/a.onnx": a, "/fake/t.json": b, "/worse/onnx/a.onnx": a });
  try {
    const seen = [];
    await download({ key: "fake", spec: good, baseUrl: site.url, onProgress: (done, total) => seen.push([done, total]) });
    assert.equal(existsSync(join(process.env.DEIKO_MODEL_DIR, "fake", ".complete")), true);
    assert.deepEqual(seen.at(-1), [a.length + b.length, a.length + b.length]);

    const bad = { files: [{ path: "onnx/a.onnx", bytes: a.length, sha256: "0".repeat(64) }] };
    await assert.rejects(download({ key: "worse", spec: bad, baseUrl: site.url }), /checksum/);
    const dir = join(process.env.DEIKO_MODEL_DIR, "worse");
    assert.equal(existsSync(join(dir, ".complete")), false);
    assert.deepEqual(readdirSync(join(dir, "onnx")), [], "no partial file left behind");
  } finally {
    await site.close();
    if (was === undefined) delete process.env.DEIKO_MODEL_DIR; else process.env.DEIKO_MODEL_DIR = was;
  }
});

test("the real model puts a graph near a chart", { skip: !isReady(DEFAULT_MODEL) && "model not downloaded on this Mac" }, async () => {
  const model = await loadModel(DEFAULT_MODEL);
  assert.ok(model);
  const q = await model.embed("why did the graph drop in week 32", "query");
  const chart = await model.embed("The signup chart shows a drop in week 32.", "doc");
  const price = await model.embed("Fix the rounding of the price at checkout.", "doc");
  assert.equal(q.length, 640);
  assert.ok(cosine(q, chart) > cosine(q, price), `${cosine(q, chart)} vs ${cosine(q, price)}`);
});
