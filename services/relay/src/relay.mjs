// ─────────────────────────────────────────────────────────────────────────────
// THE RELAY, WITHOUT A TRANSPORT
//
// So that a new user transcribes without holding an account anywhere. The app
// posts narration audio; this forwards it to Sarvam with Deiko's key and
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

import { createHash } from "node:crypto";

import { SUMMARIES_PER_DAY, audioSeconds, capFor, decide, subjectFrom } from "./quota.mjs";
import {
  USAGE_TABLE,
  meteringHealthy,
  peek,
  record,
  recordSummary,
  refund,
  refundSummary,
  tierFor,
  unavailable,
} from "./usage.mjs";

const SARVAM_STT_URL = "https://api.sarvam.ai/speech-to-text";
const GROQ_URL = "https://api.groq.com/openai/v1/chat/completions";

/// Bigger than any chunk the client sends — `transcribe.mjs` splits at 25s of
/// 16kHz mono, which is 0.76MB — and small enough that a bad actor cannot make
/// us hold much memory. Also comfortably under Lambda's 6MB request cap.
///
/// 2MB rather than 12: the ceiling is a blast radius, not a courtesy. Audio is
/// metered by LENGTH (`quota.mjs`'s `audioSeconds`), so an oversized body is
/// counted as the audio it pretends to be, and a 12MB one counted as 375
/// seconds meant ~39 junk requests could exhaust the whole service's daily
/// ceiling and lock out every paying customer until UTC midnight. The real
/// chunk is 0.76MB; 2MB is headroom, not a limit anybody honest will meet.
export const MAX_BODY_BYTES = 2 * 1024 * 1024;

/// The summary is JSON, not audio: a transcript and a system prompt, a few kB.
/// It gets its own cap because sharing the audio one would let a caller post
/// two megabytes of prompt to a model we pay for.
export const MAX_SUMMARY_BYTES = 64 * 1024;

// ── What a summary is allowed to be ─────────────────────────────────────────
//
// These MIRROR `scripts/summarize.mjs` — the same model, the same temperature,
// the same 200-token answer. They are pinned HERE as well because the client
// choosing them is the client choosing our bill: this route forwards to Groq
// with Deiko's key, so an arbitrary caller with any bearer string could
// otherwise name an expensive model and a large completion and bill it to us.
// The caller's `messages` still travel (the system prompt lives on the client,
// where the product's voice belongs); nothing else the caller sends does.
// `llama-3.3-70b-versatile` until Groq retired it — a pinned model can
// disappear out from under a deployed relay, and the failure is a 404 the
// client silently degrades over. Mirrors MODEL in scripts/summarize.mjs.
const SUMMARY_MODEL = "openai/gpt-oss-20b";
const SUMMARY_TEMPERATURE = 0.2;
const SUMMARY_MAX_COMPLETION_TOKENS = 200;

/// The joined length of everything we will hand the model. A narration long
/// enough to exceed this is already past the point where three lines help.
const SUMMARY_MAX_CONTENT_CHARS = 8_000;

/// How many message envelopes may reach the model. The client sends two — a
/// system line and the narration — so this is sixteen times the honest need.
const MAX_SUMMARY_MESSAGES = 32;

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

/// ponytail: clear-all rather than an LRU. `seen` is keyed by token and a
/// caller who rotates tokens is not rate-limited by it anyway, so the only
/// thing eviction has to prevent is unbounded memory in a warm container.
/// Dropping every window early under a flood of unique tokens costs the
/// honest caller one reset; upgrade to an LRU only if that is ever measured
/// to matter.
const MAX_TRACKED_TOKENS = 5_000;

function overRateLimit(token) {
  const now = Date.now();
  if (seen.size > MAX_TRACKED_TOKENS) seen.clear();
  const entry = seen.get(token);
  if (!entry || now > entry.resetAt) {
    seen.set(token, { count: 1, resetAt: now + WINDOW_MS });
    return false;
  }
  entry.count += 1;
  return entry.count > MAX_REQUESTS_PER_WINDOW;
}

/// The identifier that appears in the logs, and the one you revoke by.
///
/// NOT the token itself: a bearer in CloudWatch is a credential in CloudWatch.
/// A hash prefix is safe to write down, safe to paste into a ticket, and long
/// enough not to collide across any user count this will ever have.
export function tokenFingerprint(token) {
  return createHash("sha256").update(token).digest("hex").slice(0, 12);
}

/// Tokens that have been abused. A plain comma-separated list because
/// revocation should be one obvious edit away at three in the morning.
///
/// Matches EITHER the raw token or its fingerprint, and that is the whole
/// point: the logs only ever carry the fingerprint, so before this the string
/// you could find was never the string you could revoke. Now what you read in
/// CloudWatch is what you paste into DEIKO_REVOKED_TOKENS.
function revoked(token) {
  const list = new Set((process.env.DEIKO_REVOKED_TOKENS ?? "").split(",").filter(Boolean));
  return list.has(token) || list.has(tokenFingerprint(token));
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
  if (revoked(token)) return json(403, { error: "token revoked" });

  const subject = subjectFrom(token);
  if (!subject) return json(401, { error: "malformed token" });

  // BEFORE the quota branch, not after it. /v1/quota does a DynamoDB read, a
  // conditional write and — for an unseen licence — an outbound Polar
  // call, so leaving it above the limiter made it the cheapest way to amplify
  // writes against a 25-WCU table. Throttled writes there do not fail the
  // attacker's request, they fail /v1/transcribe for whoever is paying.
  if (overRateLimit(token)) return json(429, { error: "rate limit exceeded" });

  // WHAT AM I, AND WHAT IS LEFT. Read-only, and the only route the app itself
  // calls rather than the pipeline. Settings asks the instant a licence key is
  // pasted, because "Pro · 10 hours a month" is the confirmation that the key
  // worked — and the app must be able to say that before a session has ever
  // run. A quota that could only be learned by spending some would be useless
  // at exactly the moment somebody has just paid.
  if (path === "/v1/quota") {
    try {
      const tier = await tierFor(subject);
      const usedSeconds = await peek(subject, tier);
      const capSeconds = capFor(tier);
      return json(200, {
        tier,
        usedSeconds: Math.round(usedSeconds),
        capSeconds,
        remainingSeconds: Math.max(0, Math.round(capSeconds - usedSeconds)),
      });
    } catch (err) {
      return json(503, { error: unavailable(err) });
    }
  }

  if (body && body.length > MAX_BODY_BYTES) return json(413, { error: "body too large" });

  if (path === "/v1/transcribe") {
    if (!sarvamKey) return json(503, { error: "relay has no transcription key configured" });

    // METERED BEFORE IT IS SPENT. The counter is incremented and then judged,
    // so two chunks arriving together cannot both see room that only one of
    // them has. Being over by one chunk costs a few paise; a race that lets a
    // cap be exceeded by however many containers are warm does not.
    let verdict, seconds, tier;
    try {
      tier = await tierFor(subject);
      seconds = audioSeconds(body?.length ?? 0);
      const { usedSeconds, globalUsedSeconds } = await record({ subject, seconds, tier });
      verdict = decide({ tier, usedSeconds, globalUsedSeconds });
    } catch (err) {
      // FAILING CLOSED, DELIBERATELY. If the usage table cannot be reached we
      // do not know what anybody has spent, and the honest answer is to stop
      // buying audio rather than to buy an unbounded amount and find out
      // later. The client keeps working on Apple's on-device words.
      return json(503, { error: unavailable(err) });
    }

    if (!verdict.allowed) {
      // A REFUSED REQUEST GIVES ITS SECONDS BACK. Without this, refusals were
      // the weapon: a spent trial token looping through one warm container
      // added 30 × 40 = 1,200 metered seconds a minute to the GLOBAL row —
      // requests that would never be transcribed walked the whole service to
      // its daily ceiling in twelve minutes and 429'd every paying customer.
      // Best-effort: a failed refund just restores the old over-counting.
      await refund({ subject, seconds, tier }).catch(() => {});
      return json(verdict.status, { error: verdict.error });
    }

    const out = await proxy(SARVAM_STT_URL, {
      // The client's own multipart body and boundary, forwarded verbatim.
      // Parsing and re-encoding it would mean touching the audio for no reason.
      "api-subscription-key": sarvamKey,
      "content-type": contentType || "multipart/form-data",
    }, body);
    // A provider outage is not the caller's spend. A trial is LIFETIME, so an
    // hour of Sarvam 5xx would otherwise eat it for nothing. 4xx stays billed:
    // that is the caller's own malformed audio, and refunding it would let
    // junk bodies probe Sarvam off the meter.
    if (out.status >= 500) await refund({ subject, seconds, tier }).catch(() => {});
    return out;
  }

  if (path === "/v1/summarize") {
    if (!groqKey) return json(503, { error: "relay has no summary key configured" });
    if (body && body.length > MAX_SUMMARY_BYTES) {
      return json(413, { error: "body too large" });
    }

    // THE BODY IS REBUILT, NEVER FORWARDED.
    //
    // This route spends Deiko's Groq key, and it will accept any bearer string
    // — that is what makes it usable by somebody whose trial has run out, and
    // it is also what made forwarding the caller's JSON verbatim a mistake: it
    // let anyone who found the URL name their own model and completion budget
    // and bill it here. So we take the one field that carries the user's words
    // and pin everything that costs money.
    let messages;
    try {
      const sent = JSON.parse(Buffer.from(body ?? "").toString("utf8"));
      messages = Array.isArray(sent?.messages) ? sent.messages : null;
    } catch {
      messages = null;
    }
    if (!messages?.length) return json(400, { error: "expected { messages: [...] }" });

    // The COUNT is pinned like everything else that costs money. The char
    // budget caps the content but not the number of envelopes: a 60KB body of
    // empty `{}`s became twenty thousand chat messages, each billing Groq its
    // per-message token overhead for no content at all. The client sends two.
    let budget = SUMMARY_MAX_CONTENT_CHARS;
    const trimmed = messages.slice(0, MAX_SUMMARY_MESSAGES).map((m) => {
      const content = String(m?.content ?? "").slice(0, Math.max(0, budget));
      budget -= content.length;
      return { role: m?.role === "system" ? "system" : "user", content };
    });

    // METERED AGAINST ITS OWN DAY. The promise this route was written for
    // still holds — somebody who has used up their trial gets the sentence
    // that tells them what Deiko heard — and their own counter is untouched,
    // so a summary never spends the audio allowance it is not made of.
    //
    // The budget it spends is the SUMMARY budget, not the audio ceiling. This
    // route takes any bearer string, and the burst limiter is keyed by token,
    // so a caller rotating tokens can send as many of these as it likes; when
    // they were nominal seconds against the audio ceiling, eight thousand of
    // them closed transcription for every paying customer for the rest of the
    // day. Now a flood of summaries exhausts summaries.
    try {
      const { summariesToday } = await recordSummary();
      if (summariesToday > SUMMARIES_PER_DAY) {
        // Refused summaries give their count back, or they keep climbing the
        // ceiling that is refusing them.
        await refundSummary().catch(() => {});
        return json(429, {
          error: "the summary service is at its daily ceiling — try again tomorrow",
        });
      }
    } catch (err) {
      return json(503, { error: unavailable(err) });
    }

    const out = await proxy(GROQ_URL, {
      authorization: `Bearer ${groqKey}`,
      "content-type": "application/json",
    }, JSON.stringify({
      model: SUMMARY_MODEL,
      messages: trimmed,
      temperature: SUMMARY_TEMPERATURE,
      max_completion_tokens: SUMMARY_MAX_COMPLETION_TOKENS,
    }));
    if (out.status >= 500) await refundSummary().catch(() => {});
    return out;
  }

  return json(404, { error: "no such endpoint" });
}

/// A DEADLINE ON THE UPSTREAM CALL. Sarvam answers a 25-second chunk in one
/// or two; Lambda's own timeout is 60. Without this, requests that stall on a
/// provider hold a container each for the full minute, and concurrency here is
/// single digits — a handful of them is the whole service. Twenty seconds is
/// far past honest latency and far short of the platform's patience.
const UPSTREAM_TIMEOUT_MS = 20_000;

async function proxy(url, headers, body) {
  const upstream = await fetch(url, {
    method: "POST",
    headers,
    body,
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });
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

/// A token FINGERPRINT, a path, a status and a duration. Never a body, never a
/// transcript, never the token itself.
///
/// It used to log the token's own first eight characters, which for `dev_xxxx`
/// left four usable hex digits — too few to identify anybody, and the wrong
/// string anyway, because revocation needs the value in full. The fingerprint
/// is both safe to write down AND the exact string `DEIKO_REVOKED_TOKENS`
/// accepts, so finding an abusive install in the logs and stopping it are now
/// the same two minutes.
export function logLine({ method, path, status, ms, token }) {
  return [
    new Date().toISOString(),
    method,
    path,
    status,
    `${ms}ms`,
    token ? `tok:${tokenFingerprint(token)}` : "tok:none",
  ].join(" ");
}

export function bearerFrom(authorizationHeader) {
  const header = authorizationHeader ?? "";
  return header.startsWith("Bearer ") ? header.slice(7) : null;
}
