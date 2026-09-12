#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// THE RELAY, ON A PORT
//
// A thin adapter over `relay.mjs` for local development and for anywhere that
// runs a container. Production is `lambda.mjs`; every decision lives in
// `relay.mjs`, so what you test here is what runs there.
//
//   SARVAM_API_KEY=… GROQ_API_KEY=… node services/relay/server.mjs
//   DEIKO_RELAY_URL=http://localhost:8787 open build/Deiko.app
// ─────────────────────────────────────────────────────────────────────────────

import { createServer } from "node:http";
import { handle, bearerFrom, logLine, MAX_BODY_BYTES } from "./relay.mjs";

const PORT = Number(process.env.PORT ?? 8787);

/// Read the whole body into memory, refusing anything oversized.
///
/// In memory on purpose: a temp file is a copy of somebody's voice on a disk
/// this service does not own, and the promise is that no such copy is made.
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > MAX_BODY_BYTES) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

const server = createServer(async (req, res) => {
  const started = Date.now();
  const token = bearerFrom(req.headers.authorization);
  const path = (req.url ?? "/").split("?")[0];

  let result;
  try {
    const body = req.method === "POST" ? await readBody(req) : null;
    result = await handle({
      method: req.method ?? "GET",
      path,
      token,
      contentType: req.headers["content-type"] ?? "",
      body,
    });
  } catch (err) {
    // Same split as the Lambda adapter: the reason is logged, never returned.
    console.error(`unhandled: ${String(err?.stack ?? err?.message ?? err)}`);
    result = {
      status: 413,
      body: JSON.stringify({ error: "request could not be handled" }),
      contentType: "application/json",
    };
  }

  res.writeHead(result.status, {
    "content-type": result.contentType,
    "content-length": Buffer.byteLength(result.body),
  });
  res.end(result.body);

  console.log(logLine({
    method: req.method, path, status: result.status, ms: Date.now() - started, token,
  }));
});

server.listen(PORT, () => {
  console.log(`deiko relay on :${PORT}`);
  if (!process.env.SARVAM_API_KEY) console.log("  ⚠ SARVAM_API_KEY unset — /v1/transcribe will 503");
  if (!process.env.GROQ_API_KEY) console.log("  ⚠ GROQ_API_KEY unset — /v1/summarize will 503");
});
