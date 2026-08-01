// ─────────────────────────────────────────────────────────────────────────────
// THE FOVEA RELAY
//
// So that a new user transcribes without holding an account anywhere. The app
// posts narration audio here; this forwards it to Sarvam with Fovea's key and
// returns the text. Same for the orb's three-line summary, via Groq.
//
// WHAT THIS SERVICE MUST NEVER DO, and what the code below is arranged to make
// difficult rather than merely discouraged:
//
//   • write audio or transcripts to disk — nothing is buffered to a file, and
//     there is no upload directory to forget to clean;
//   • log content — request logging prints a token prefix, a byte count and a
//     status, never a word of what was said;
//   • see anything except narration — crops, OCR, window titles and
//     accessibility text never leave the user's Mac, and no endpoint here
//     accepts them.
//
// NOT DEPLOYED BY THE REPO. Hosting, the domain and the provider keys are live
// infrastructure. See README.md beside this file.
// ─────────────────────────────────────────────────────────────────────────────

import { createServer } from "node:http";

const PORT = Number(process.env.PORT ?? 8787);
const SARVAM_KEY = process.env.SARVAM_API_KEY;
const GROQ_KEY = process.env.GROQ_API_KEY;

const SARVAM_STT_URL = "https://api.sarvam.ai/speech-to-text";
const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";

/// Bigger than any single chunk the client sends (`CHUNK_SECONDS` of 16kHz
/// mono), small enough that a bad actor cannot make us hold a lot of memory.
const MAX_BODY_BYTES = 12 * 1024 * 1024;

// ── Rate limiting ───────────────────────────────────────────────────────────
//
// In memory, and therefore per-instance: this is a speed bump, not a quota
// system. Anything serious wants a shared store — but a shared store is a
// deployment decision, and a speed bump that exists beats a perfect one that
// does not.

const WINDOW_MS = 60_000;
const MAX_REQUESTS_PER_WINDOW = 30;
const seen = new Map(); // token → { count, resetAt }

function overRateLimit(token) {
  const now = Date.now();
  const entry = seen.get(token);
  if (!entry || now > entry.resetAt) {
    seen.set(token, { count: 1, resetAt: now + WINDOW_MS });
    return false;
  }
  entry.count += 1;
  return entry.count > MAX_REQUESTS_PER_WINDOW;
}

/// Tokens that have been abused. A plain list because revocation should be one
/// obvious edit away at three in the morning.
const revoked = new Set((process.env.FOVEA_REVOKED_TOKENS ?? "").split(",").filter(Boolean));

// ── Plumbing ────────────────────────────────────────────────────────────────

function bearer(req) {
  const header = req.headers.authorization ?? "";
  return header.startsWith("Bearer ") ? header.slice(7) : null;
}

function send(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

/// Read the whole body into memory, refusing anything oversized.
///
/// In memory on purpose: a temp file is a copy of somebody's voice on a disk
/// this service does not own, and the promise above is that no such copy is
/// ever made.
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

// ── Handlers ────────────────────────────────────────────────────────────────

/// Narration audio in, text out. The multipart body the app already builds for
/// Sarvam is forwarded verbatim — this service does not parse it, which is one
/// fewer place for the audio to be touched.
async function transcribe(req, res) {
  if (!SARVAM_KEY) return send(res, 503, { error: "relay has no transcription key configured" });

  const body = await readBody(req);
  const upstream = await fetch(SARVAM_STT_URL, {
    method: "POST",
    headers: {
      "api-subscription-key": SARVAM_KEY,
      // The client's own multipart boundary. Rewriting the body would mean
      // parsing and re-encoding the audio for no reason.
      "content-type": req.headers["content-type"] ?? "multipart/form-data",
    },
    body,
  });

  const text = await upstream.text();
  if (!upstream.ok) {
    // The provider's message is passed through so the app's failure taxonomy
    // can still classify it — but truncated, because a provider that echoes
    // input in an error must not turn this into a content log.
    return send(res, upstream.status, { error: text.slice(0, 200) });
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end(text);
}

/// The orb's three-line reading. Narration text in, three lines out.
async function summarize(req, res) {
  if (!GROQ_KEY) return send(res, 503, { error: "relay has no summary key configured" });

  const body = await readBody(req);
  const upstream = await fetch(GROQ_URL, {
    method: "POST",
    headers: { authorization: `Bearer ${GROQ_KEY}`, "content-type": "application/json" },
    body,
  });

  const text = await upstream.text();
  if (!upstream.ok) return send(res, upstream.status, { error: text.slice(0, 200) });
  res.writeHead(200, { "content-type": "application/json" });
  res.end(text);
}

// ── The server ──────────────────────────────────────────────────────────────

const server = createServer(async (req, res) => {
  const started = Date.now();
  const token = bearer(req);

  try {
    if (req.method === "GET" && req.url === "/health") {
      return send(res, 200, {
        ok: true,
        transcription: Boolean(SARVAM_KEY),
        summary: Boolean(GROQ_KEY),
      });
    }
    if (req.method !== "POST") return send(res, 405, { error: "method not allowed" });
    if (!token) return send(res, 401, { error: "missing token" });
    if (revoked.has(token)) return send(res, 403, { error: "token revoked" });
    if (overRateLimit(token)) return send(res, 429, { error: "rate limit exceeded" });

    if (req.url === "/v1/transcribe") return await transcribe(req, res);
    if (req.url === "/v1/summarize") return await summarize(req, res);
    return send(res, 404, { error: "no such endpoint" });
  } catch (err) {
    return send(res, 500, { error: String(err.message).slice(0, 200) });
  } finally {
    // A token PREFIX, a path, a status and a duration. Never a body, never a
    // transcript, never a full token — enough to find an abusive install and
    // nothing that would make these logs worth stealing.
    console.log(
      [
        new Date().toISOString(),
        req.method,
        req.url,
        res.statusCode,
        `${Date.now() - started}ms`,
        token ? `tok:${token.slice(0, 8)}` : "tok:none",
      ].join(" "),
    );
  }
});

server.listen(PORT, () => {
  console.log(`fovea relay on :${PORT}`);
  if (!SARVAM_KEY) console.log("  ⚠ SARVAM_API_KEY unset — /v1/transcribe will 503");
  if (!GROQ_KEY) console.log("  ⚠ GROQ_API_KEY unset — /v1/summarize will 503");
});
