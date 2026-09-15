/**
 * WHY A TRANSCRIPT CAME OUT WORSE THAN USUAL.
 *
 * The relay refuses for four different reasons and the client used to treat one
 * of them (402) as a fact worth acting on and the rest as failures. Every one of
 * them ends the same way — the session keeps working on Apple's on-device words —
 * so the difference that matters to a user is not "did it fail" but WHICH of
 * these happened, because the four have four different answers:
 *
 *   trial        your free 30 minutes are gone        → buy Pro, or carry on degraded
 *   monthly      this month's Pro hours are gone      → it resets on the 1st
 *   ceiling      the SERVICE is at its daily limit    → nothing is wrong with your plan
 *   unavailable  the relay or the network is unwell   → try again later
 *
 * Before this, all four were silent: `render-brief.mjs` destructured a `source`
 * field that `transcribe.mjs` has never written at the top level, so `degraded`
 * was true only for `degradedHolds` — which is a DIFFERENT degradation (the
 * on-device recogniser failed and the cloud text was kept, with times spread
 * evenly). The user saw a worse transcript and no explanation, and what reached
 * the inbox was "the transcription is bad".
 *
 * Pure string-and-number work so the whole mapping is testable without a relay.
 * The literals below are the relay's own, and the citations are load-bearing:
 * reword one there and this stops matching, silently.
 */

/**
 * Why the relay refused, or null if it did not.
 *
 * `status` 0 means the request never got an answer — a thrown fetch, a DNS
 * failure, a timeout. That is `unavailable` like any 503; the caller cannot
 * tell the difference and neither can the user.
 *
 * @param {number} status  HTTP status, or 0 for a network-layer failure.
 * @param {string} body    The response body, for the two 429s that differ only by it.
 * @returns {"trial"|"monthly"|"ceiling"|"unavailable"|null}
 */
export function refusalReason(status, body = "") {
  // services/relay/quota.mjs:206 — "the free trial is used up"
  if (status === 402) return "trial";

  const text = String(body).toLowerCase();
  if (status === 429) {
    // quota.mjs:200 — "this month's fair-use limit is used up"
    if (text.includes("fair-use")) return "monthly";
    // quota.mjs:190 — "the service is at its daily ceiling"
    if (text.includes("daily ceiling")) return "ceiling";
    // relay.mjs:203 — "rate limit exceeded", the in-memory per-container limiter.
    return "unavailable";
  }
  // A BEARER THE RELAY WILL NOT ACCEPT CANNOT HEAL BY BEING SENT AGAIN.
  // 401 is a malformed token, 403 a revoked one (services/relay/relay.mjs:190
  // and :191). Retrying uploads every remaining chunk of the session to be
  // rejected one at a time — minutes of somebody's audio, sent to be refused —
  // so this is final, and it is the one refusal whose fix is in Settings.
  if (status === 401 || status === 403) return "rejected";

  // relay.mjs:223/249 — "usage service unavailable"; 0 = the request never landed.
  if (status === 503 || status === 0) return "unavailable";
  return status >= 400 ? "unavailable" : null;
}

/**
 * Which refusals answer for the WHOLE session, and which are worth retrying.
 *
 * A trial, a monthly cap and a daily ceiling are facts about the account or the
 * day: every later chunk would hear the same thing, so uploading them spends
 * bandwidth to be told what is already known.
 *
 * `unavailable` is NOT in this set, deliberately. The relay's in-memory limiter
 * allows 30 requests a minute per token (services/relay/relay.mjs:104), and a
 * twelve-minute session is roughly 29 chunks plus its quota calls — so a burst
 * 429 partway through a long recording is both plausible and transient. Treating
 * it as final would silently drop every word after it.
 */
export const REFUSAL_IS_FINAL = new Set(["trial", "monthly", "ceiling", "rejected"]);

/**
 * The one reason the review window shows, from everything the transcript knows.
 *
 * Ordered by what a user can act on. A refusal is a statement about their plan
 * or our service and outranks a count of failed chunks, which in turn outranks
 * `degradedHolds` — that last one is not about the cloud at all, so it is named
 * "timing" rather than being folded in with the others and mislabelled
 * "transcribed on your Mac" (which is exactly backwards for it: the cloud text
 * is what survived, and the on-device CLOCK is what was lost).
 *
 * @returns {"trial"|"monthly"|"ceiling"|"unavailable"|"timing"|null}
 */
export function degradedReason({ cloud, degradedHolds } = {}) {
  if (cloud?.refused) return cloud.refused;
  if ((cloud?.failedChunks ?? 0) > 0) return "unavailable";
  // NO RELAY IN THIS BUILD — a misconfiguration, not a fact about the plan.
  //
  // `selectTranscriber` reaches the on-device recogniser only when there is
  // neither a BYO Groq key nor a DEIKO_RELAY_URL, and a BYO key names itself
  // `groq:…`, so this name can only mean nothing was configured. The two
  // branches above already took every case where a relay WAS reached and then
  // refused or failed, which is exactly what keeps this apart from "trial": a
  // spent trial is normal and its answer is a purchase; this one's answer is a
  // rebuild, and collapsing them is how a day of mangled transcripts read first
  // as "the free minutes ran out" and then as "the aligner is broken".
  //
  // Ahead of "timing" on purpose. A wholly-local transcript is the larger
  // claim, and timing's sentence — "what you said is intact" — is the wrong
  // reassurance for a session that never had cloud words at all.
  if (cloud?.transcriber === "on-device") return "on-device";
  if (degradedHolds?.length) return "timing";
  return null;
}
