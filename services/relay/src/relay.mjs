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

import { audioSeconds, capFor, decide, subjectFrom } from "./quota.mjs";
import { USAGE_TABLE, meteringHealthy, peek, record, tierFor } from "./usage.mjs";

const SARVAM_STT_URL = "https://api.sarvam.ai/speech-to-text";
const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";

/// Bigger than any chunk the client sends — `transcribe.mjs` splits at 25s of
/// 16kHz mono, which is 0.76MB — and small enough that a bad actor cannot make
/// us hold much memory. Also comfortably under Lambda's 6MB request cap.
export const MAX_BODY_BYTES = 12 * 1024 * 1024;

// ── Burst limiting ──────────────────────────────────────────────────────────
//
// In memory, and therefore per-process: one warm Lambda container, or one
// long-running server. A speed bump that catches a client stuck in a loop, NOT
// a quota — on Lambda especially, a determined caller gets a fresh container
// and a fresh counter.
//
// It used to be the ONLY limit, and this comment used to say so at length,
// because a rate limiter that is quietly ineffective invites you to stop
// watching the bill. There is now a real one: `quota.mjs` decides and
// `usage.mjs` counts, in DynamoDB, across every container. This stays in front
// of it as the cheap check — a client in a tight loop is refused here without
// spending a write.

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
    // and then 503s every real request. Every flag travels so a deploy can be
    // checked with one curl — including metering, because a relay that cannot
    // count must not be quietly buying audio for anyone who asks.
    //
    // `metering` is a real DescribeTable, not a check on whether the table's
    // NAME is configured. The name always has a default, so the cheap version
    // reports healthy on precisely the deploy where the table is missing or the
    // role has no policy.
    return json(200, {
      ok: true,
      transcription: Boolean(sarvamKey),
      summary: Boolean(groqKey),
      metering: await meteringHealthy(),
      table: USAGE_TABLE,
    });
  }

  if (method !== "POST" && !(method === "GET" && path === "/v1/quota")) {
    return json(405, { error: "method not allowed" });
  }
  if (!token) return json(401, { error: "missing token" });
  if (revoked().has(token)) return json(403, { error: "token revoked" });

  const subject = subjectFrom(token);
  if (!subject) return json(401, { error: "malformed token" });

  // WHAT AM I, AND WHAT IS LEFT. Read-only, and the only route the app itself
  // calls rather than the pipeline. Settings asks the instant a licence key is
  // pasted, because "Pro · 5 hours a month" is the confirmation that the key
  // worked — and the app must be able to say that before a session has ever
  // run. A quota that could only be learned by spending some would be useless
  // at exactly the moment somebody has just paid.
  if (path === "/v1/quota") {
    try {
      const tier = await tierFor(subject);
      const usedSeconds = await peek(subject);
      const capSeconds = capFor(tier);
      return json(200, {
        tier,
        usedSeconds: Math.round(usedSeconds),
        capSeconds,
        remainingSeconds: Math.max(0, Math.round(capSeconds - usedSeconds)),
      });
    } catch (err) {
      return json(503, {
        error: `usage service unavailable: ${String(err?.message ?? err).slice(0, 120)}`,
      });
    }
  }

  if (overRateLimit(token)) return json(429, { error: "rate limit exceeded" });
  if (body && body.length > MAX_BODY_BYTES) return json(413, { error: "body too large" });

  if (path === "/v1/transcribe") {
    if (!sarvamKey) return json(503, { error: "relay has no transcription key configured" });

    // METERED BEFORE IT IS SPENT. The counter is incremented and then judged,
    // so two chunks arriving together cannot both see room that only one of
    // them has. Being over by one chunk costs a few paise; a race that lets a
    // cap be exceeded by however many containers are warm does not.
    let verdict;
    try {
      const tier = await tierFor(subject);
      const seconds = audioSeconds(body?.length ?? 0);
      const { usedSeconds, globalUsedSeconds } = await record({ subject, seconds });
      verdict = decide({ tier, usedSeconds, globalUsedSeconds });
    } catch (err) {
      // FAILING CLOSED, DELIBERATELY. If the usage table cannot be reached we
      // do not know what anybody has spent, and the honest answer is to stop
      // buying audio rather than to buy an unbounded amount and find out
      // later. The client keeps working on Apple's on-device words.
      return json(503, {
        error: `usage service unavailable: ${String(err?.message ?? err).slice(0, 120)}`,
      });
    }

    if (!verdict.allowed) return json(verdict.status, { error: verdict.error });

    return await proxy(SARVAM_STT_URL, {
      // The client's own multipart body and boundary, forwarded verbatim.
      // Parsing and re-encoding it would mean touching the audio for no reason.
      "api-subscription-key": sarvamKey,
      "content-type": contentType || "multipart/form-data",
    }, body);
  }

  if (path === "/v1/summarize") {
    if (!groqKey) return json(503, { error: "relay has no summary key configured" });
    // NOT METERED. Groq's three-line reading is a couple of thousand tokens —
    // a rounding error beside the audio — and somebody who has used up their
    // trial should still get the sentence that tells them what Fovea heard.
    // Charging for it would cost more in explanation than it does in tokens.
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
