/**
 * MEANING — a small embedding model on this Mac, so "the graph thing" finds
 * the chart work and "the drag thing" finds "moving cards". Run through
 * onnxruntime-node and @huggingface/tokenizers directly: not transformers.js,
 * which pulls in sharp/libvips and every platform's binaries, and not
 * node-llama-cpp, which lacks last-token pooling. The pooling is written here.
 *
 * FAILS SOFT, EVERYWHERE. No model, no runtime, a bad file, a throw inside
 * the runtime — `loadModel` answers null or `embed` answers null, and Deiko
 * matches on words. Vectors never leave this Mac.
 *
 * ponytail: the model loads per process (~0.6 s, ~70 ms per short text).
 * Keep a resident process if that is ever felt.
 */
import { createHash } from "node:crypto";
import { once } from "node:events";
import { createReadStream, createWriteStream, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const HF = "https://huggingface.co";
export const MODELS = {
  "harrier-oss-v1-270m": {
    name: "harrier-oss-v1-270m by Microsoft",
    licence: "MIT",
    onnx: "onnx/model_q4.onnx",
    dims: 640,
    query: "Instruct: Retrieve semantically similar text\nQuery: ",
    doc: "",
    files: [
      { path: "onnx/model_q4.onnx", bytes: 239762, sha256: "228dca2603b907d673dd99cf89c309c0ca68baeed127416a5e027a48e62b0f49", hf: `${HF}/onnx-community/harrier-oss-v1-270m-ONNX/resolve/main/onnx/model_q4.onnx` },
      { path: "onnx/model_q4.onnx_data", bytes: 205492736, sha256: "b5a15487360f5341659480ae4b5ad60028d5f865bd329196ec8d5708bbed3118", hf: `${HF}/onnx-community/harrier-oss-v1-270m-ONNX/resolve/main/onnx/model_q4.onnx_data` },
      { path: "tokenizer.json", bytes: 20323311, sha256: "ec95be298bea26f90370854faa650744c9fb0a04ca5e5ff95dd3913393ac5e45", hf: `${HF}/onnx-community/harrier-oss-v1-270m-ONNX/resolve/main/tokenizer.json` },
      { path: "tokenizer_config.json", bytes: 702, sha256: "135405f3479eaebc473e2e78593f2195c7598948a215ee748758def426b30f59", hf: `${HF}/onnx-community/harrier-oss-v1-270m-ONNX/resolve/main/tokenizer_config.json` },
      { path: "1_Pooling/config.json", bytes: 296, sha256: "8a7a9b2999b00da31538ae2c357182df15e23f8d77412bb97e727edf0ce495cc", hf: `${HF}/microsoft/harrier-oss-v1-270m/resolve/main/1_Pooling/config.json` },
    ],
  },
  "embeddinggemma-300m": {
    name: "EmbeddingGemma by Google",
    licence: "Gemma Terms of Use",
    onnx: "onnx/model_q4.onnx",
    dims: 256,
    query: "task: search result | query: ",
    doc: "title: none | text: ",
    files: [
      { path: "onnx/model_q4.onnx", bytes: 519322, sha256: "ad1dfee81a70f7944b9b9d1cc6e48075b832881cf33fab2f2b248be78f3f0043", hf: `${HF}/onnx-community/embeddinggemma-300m-ONNX/resolve/main/onnx/model_q4.onnx` },
      { path: "onnx/model_q4.onnx_data", bytes: 196725760, sha256: "599962c3143b040de2dd05e5975be3e9091dd067cacc6a8f7186e3203bab9e02", hf: `${HF}/onnx-community/embeddinggemma-300m-ONNX/resolve/main/onnx/model_q4.onnx_data` },
      { path: "tokenizer.json", bytes: 20323312, sha256: "4dda02faaf32bc91031dc8c88457ac272b00c1016cc679757d1c441b248b9c47", hf: `${HF}/onnx-community/embeddinggemma-300m-ONNX/resolve/main/tokenizer.json` },
      { path: "tokenizer_config.json", bytes: 1156830, sha256: "3ca953eea6c3c9fcda9cf3df22949ff18b216f7c74bd6459230f3f1013953f3a", hf: `${HF}/onnx-community/embeddinggemma-300m-ONNX/resolve/main/tokenizer_config.json` },
    ],
  },
};
/// The bake-off (eval-filing --model) decides whether the challenger replaces it.
export const DEFAULT_MODEL = "harrier-oss-v1-270m";
/// Our own storage: the controller mirrors each model's files here, same paths.
export const MODEL_BASE_URL = "https://deiko.app/download/models";
const MAX_TOKENS = 512;

export function currentModel() {
  const want = process.env.DEIKO_MEANING_MODEL ?? DEFAULT_MODEL;
  return Object.hasOwn(MODELS, want) ? want : null;
}

export function modelDir(key) {
  const root = process.env.DEIKO_MODEL_DIR ?? join(homedir(), "Library", "Application Support", "Deiko", "models");
  return join(root, key);
}

export function isReady(key) {
  return Boolean(key) && existsSync(join(modelDir(key), ".complete"));
}

export function pool(hidden, seq, dim, mask, mode) {
  const out = new Float32Array(dim);
  if (mode === "cls") {
    out.set(hidden.subarray(0, dim));
    return out;
  }
  if (mode === "lasttoken") {
    let last = 0;
    for (let i = 0; i < seq; i++) if (mask[i]) last = i;
    out.set(hidden.subarray(last * dim, last * dim + dim));
    return out;
  }
  let n = 0;
  for (let i = 0; i < seq; i++) {
    if (!mask[i]) continue;
    n += 1;
    for (let j = 0; j < dim; j++) out[j] += hidden[i * dim + j];
  }
  for (let j = 0; j < dim; j++) out[j] /= n || 1;
  return out;
}

const normalise = (v) => {
  let s = 0;
  for (const x of v) s += x * x;
  s = Math.sqrt(s) || 1;
  return v.map((x) => x / s);
};
export function finish(vec, dims) {
  return normalise(normalise(Float32Array.from(vec)).slice(0, dims));
}

/** How the model's own config says to pool; mean when it says nothing. */
function poolingMode(dir) {
  try {
    const cfg = JSON.parse(readFileSync(join(dir, "1_Pooling", "config.json"), "utf8"));
    return cfg.pooling_mode_lasttoken ? "lasttoken" : cfg.pooling_mode_cls_token ? "cls" : "mean";
  } catch {
    return "mean";
  }
}

export async function loadModel(key = currentModel()) {
  if (!key || !isReady(key)) return null;
  try {
    const ort = await import("onnxruntime-node");
    const { Tokenizer } = await import("@huggingface/tokenizers");
    const InferenceSession = ort.InferenceSession ?? ort.default?.InferenceSession;
    const Tensor = ort.Tensor ?? ort.default?.Tensor;
    const spec = MODELS[key];
    const dir = modelDir(key);
    const json = (p) => JSON.parse(readFileSync(join(dir, p), "utf8"));
    const tokenizer = new Tokenizer(json("tokenizer.json"), json("tokenizer_config.json"));
    const session = await InferenceSession.create(join(dir, spec.onnx));
    const mode = poolingMode(dir);
    const int64 = (xs) => new Tensor("int64", BigInt64Array.from(xs, (x) => BigInt(x)), [1, xs.length]);
    return {
      key,
      dims: spec.dims,
      async embed(text, as = "doc") {
        try {
          let ids = tokenizer.encode(`${as === "query" ? spec.query : spec.doc}${text}`).ids;
          // Keep the final token: last-token pooling reads it.
          if (ids.length > MAX_TOKENS) ids = [...ids.slice(0, MAX_TOKENS - 1), ids.at(-1)];
          const feeds = {};
          for (const name of session.inputNames) {
            if (name === "input_ids") feeds[name] = int64(ids);
            else if (name === "attention_mask") feeds[name] = int64(ids.map(() => 1));
            else if (name === "position_ids") feeds[name] = int64(ids.map((_, i) => i));
            else if (name === "token_type_ids") feeds[name] = int64(ids.map(() => 0));
          }
          const out = await session.run(feeds);
          const hidden = out.sentence_embedding ?? out[session.outputNames[0]];
          const vec = out.sentence_embedding
            ? hidden.data
            : pool(hidden.data, ids.length, hidden.dims.at(-1), ids.map(() => 1), mode);
          return finish(vec, spec.dims);
        } catch {
          return null;
        }
      },
    };
  } catch {
    return null;
  }
}

/** What a brief means, in its own words: the summary line, the narration and
 *  its window titles. Never the screen's words — they would drag every vector
 *  towards whatever app was open. */
export function briefText(me) {
  return [me?.summaryLine, me?.narration, ...(me?.windows ?? [])].filter(Boolean).join("\n").slice(0, 4000);
}

const digest = (text) => createHash("sha256").update(String(text)).digest("hex").slice(0, 16);
const readMeta = (dir) => {
  try {
    return JSON.parse(readFileSync(join(dir, "meaning.json"), "utf8"));
  } catch {
    return null;
  }
};

export function readVector(sessionDir, key) {
  const meta = readMeta(sessionDir);
  if (!meta || meta.model !== key) return null;
  try {
    const buf = readFileSync(join(sessionDir, "meaning.f32"));
    // Copied out: a small Buffer can sit at an offset no Float32Array accepts.
    const vec = new Float32Array(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength));
    return vec.length === meta.dims ? vec : null;
  } catch {
    return null;
  }
}

export function vectorIsCurrent(sessionDir, key, text) {
  const meta = readMeta(sessionDir);
  return meta?.model === key && meta?.text === digest(text);
}

export function writeVector(sessionDir, key, vec, text) {
  writeFileSync(join(sessionDir, "meaning.f32"), Buffer.from(vec.buffer, vec.byteOffset, vec.byteLength));
  writeFileSync(join(sessionDir, "meaning.json"), JSON.stringify({ model: key, dims: vec.length, text: digest(text) }) + "\n");
}

async function sha256File(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

export async function download({
  key = currentModel(), spec = MODELS[key], baseUrl = process.env.DEIKO_MODEL_BASE_URL ?? MODEL_BASE_URL,
  fromHF = false, onProgress = () => {}, fetchImpl = fetch,
} = {}) {
  if (!spec) throw new Error(`unknown model ${key}`);
  const dir = modelDir(key);
  rmSync(join(dir, ".complete"), { force: true });
  const total = spec.files.reduce((s, f) => s + f.bytes, 0);
  let done = 0;
  for (const f of spec.files) {
    const dest = join(dir, f.path);
    if (existsSync(dest) && (await sha256File(dest)) === f.sha256) {
      done += f.bytes;
      onProgress(done, total);
      continue;
    }
    mkdirSync(dirname(dest), { recursive: true });
    const res = await fetchImpl(fromHF ? f.hf : `${baseUrl.replace(/\/+$/, "")}/${key}/${f.path}`);
    if (!res.ok || !res.body) throw new Error(`${f.path}: HTTP ${res.status}`);
    const part = `${dest}.part`;
    const hash = createHash("sha256");
    const out = createWriteStream(part);
    try {
      for await (const chunk of res.body) {
        hash.update(chunk);
        if (!out.write(chunk)) await once(out, "drain");
        done += chunk.length;
        onProgress(done, total);
      }
      await new Promise((resolve, reject) => out.end((err) => (err ? reject(err) : resolve())));
    } catch (err) {
      out.destroy();
      rmSync(part, { force: true });
      throw err;
    }
    if (hash.digest("hex") !== f.sha256) {
      rmSync(part, { force: true });
      throw new Error(`${f.path}: checksum mismatch`);
    }
    renameSync(part, dest);
  }
  writeFileSync(join(dir, ".complete"), JSON.stringify({ model: key, at: new Date().toISOString() }) + "\n");
}
