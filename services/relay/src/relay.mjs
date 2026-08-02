// ─────────────────────────────────────────────────────────────────────────────
// THE RELAY, WITHOUT A TRANSPORT
//
// So that a new user transcribes without holding an account anywhere. The app
// posts narration audio; this forwards it to Sarvam with Fovea's key and
// returns the text. Same for the orb's summary, via Groq.
//
// Deliberately knows nothing about `node:http` or Lambda. One function in
// (method, path, bearer, content-type, body) and one object out — so the
// version that runs in production and the version you can `curl` on localhost
// are the SAME CODE, and a bug found locally is a bug fixed in production.
// `server.mjs` and `lambda.mjs` are the two thin adapters.
//
// WHAT THIS SERVICE MUST NEVER DO, arranged so that breaking one takes an edit
// rather than an oversight:
//
//   • write audio or transcripts to disk — bodies are held in memory and
//     forwarded; there is no upload directory to forget to clean;
//   • log content — a line is a status, a duration and a token prefix, never a
//     word of what was said;
//   • see anything except narration — crops, OCR, window titles and
//     accessibility text never leave the user's Mac, and no route here accepts
//     them.
// ─────────────────────────────────────────────────────────────────────────────

const SARVAM_STT_URL = "https://api.sarvam.ai/speech-to-text";
const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";

/// Bigger than any chunk the client sends — `transcribe.mjs` splits at 25s of
/// 16kHz mono, which is 0.76MB — and small enough that a bad actor cannot make
/// us hold much memory. Also comfortably under Lambda's 6MB request cap.
export const MAX_BODY_BYTES = 12 * 1024 * 1024;

// ── Rate limiting ───────────────────────────────────────────────────────────
//
// In memory, and therefore per-process: one warm Lambda container, or one
// long-running server. A speed bump that catches a client stuck in a loop, NOT
// a quota — on Lambda especially, a determined caller gets a fresh container
// and a fresh counter. The real protections are the provider dashboard, the
// revocation list below, and reserved concurrency on the function.
//
// Said plainly here because a rate limiter that is quietly ineffective is
// worse than none: it invites you to stop watching the bill.

const WINDOW_MS = 60_000;
const MAX_REQUESTS_PER_WINDOW = 30;
const seen = new Map();

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

/// Tokens that have been abused. A plain comma-separated list because
/// revocation should be one obvious edit away at three in the morning.
function revoked() {
  return new Set((process.env.FOVEA_REVOKED_TOKENS ?? "").split(",").filter(Boolean));
}

// ── The one entry point ─────────────────────────────────────────────────────

/**
 * @param {object} request
 * @param {string} request.method
 * @param {string} request.path
 * @param {string|null} request.token     bearer, already extracted
 * @param {string} request.contentType    forwarded verbatim to the provider
 * @param {Buffer|Uint8Array|null} request.body
 * @returns {Promise<{status:number, body:string, contentType:string}>}
 */
export async function handle({ method, path, token, contentType, body }) {
  const sarvamKey = process.env.SARVAM_API_KEY;
  const groqKey = process.env.GROQ_API_KEY;

  const json = (status, obj) => ({
    status,
    body: JSON.stringify(obj),
    contentType: "application/json",
  });

  if (method === "GET" && path === "/health") {
    // `ok` alone is not enough to trust: a relay with no key answers happily
    // and then 503s every real request. Both flags travel so a deploy can be
    // checked with one curl.
    return json(200, {
      ok: true,
      transcription: Boolean(sarvamKey),
      summary: Boolean(groqKey),
    });
  }

  if (method !== "POST") return json(405, { error: "method not allowed" });
  if (!token) return json(401, { error: "missing token" });
  if (revoked().has(token)) return json(403, { error: "token revoked" });
  if (overRateLimit(token)) return json(429, { error: "rate limit exceeded" });
  if (body && body.length > MAX_BODY_BYTES) return json(413, { error: "body too large" });

  if (path === "/v1/transcribe") {
    if (!sarvamKey) return json(503, { error: "relay has no transcription key configured" });
    return await proxy(SARVAM_STT_URL, {
      // The client's own multipart body and boundary, forwarded verbatim.
      // Parsing and re-encoding it would mean touching the audio for no reason.
      "api-subscription-key": sarvamKey,
      "content-type": contentType || "multipart/form-data",
    }, body);
  }

  if (path === "/v1/summarize") {
    if (!groqKey) return json(503, { error: "relay has no summary key configured" });
    return await proxy(GROQ_URL, {
      authorization: `Bearer ${groqKey}`,
      "content-type": "application/json",
    }, body);
  }

  return json(404, { error: "no such endpoint" });
}

async function proxy(url, headers, body) {
  const upstream = await fetch(url, { method: "POST", headers, body });
  const text = await upstream.text();
  if (!upstream.ok) {
    // The provider's message is passed through so the app's failure taxonomy
    // can still classify it — TRUNCATED, because a provider that echoes its
    // input back in an error must not turn this into a content log.
    return {
      status: upstream.status,
      body: JSON.stringify({ error: text.slice(0, 200) }),
      contentType: "application/json",
    };
  }
  return { status: 200, body: text, contentType: "application/json" };
}

/// A token PREFIX, a path, a status and a duration. Never a body, never a
/// transcript, never a whole token — enough to find an abusive install and
/// nothing that would make these logs worth stealing.
export function logLine({ method, path, status, ms, token }) {
  return [
    new Date().toISOString(),
    method,
    path,
    status,
    `${ms}ms`,
    token ? `tok:${token.slice(0, 8)}` : "tok:none",
  ].join(" ");
}

export function bearerFrom(authorizationHeader) {
  const header = authorizationHeader ?? "";
  return header.startsWith("Bearer ") ? header.slice(7) : null;
}
