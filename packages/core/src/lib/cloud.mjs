/**
 * Why a transcript came out worse than usual.
 *
 * The relay refuses for several reasons, and each has a different answer for
 * the user. Every one ends the same way (the session keeps working on Apple's
 * on-device words), so what matters is which happened:
 *
 *   trial        the free trial is used up            → buy Pro, or carry on degraded
 *   monthly      this month's Pro hours are gone      → it resets on the 1st
 *   ceiling      the service is at its daily limit    → nothing is wrong with the plan
 *   rejected     the relay refuses the token          → fix it in Settings
 *   unavailable  the relay or the network is unwell   → try again later
 *
 * Pure string-and-number work, so the mapping is testable without a relay. The
 * literals below are the relay's own: reword one there and this stops
 * matching, silently.
 */

/**
 * Why the relay refused, or null if it did not.
 *
 * `status` 0 means the request never got an answer (a thrown fetch, a DNS
 * failure, a timeout). That is `unavailable` like any 503.
 *
 * @param {number} status  HTTP status, or 0 for a network-layer failure.
 * @param {string} body    The response body, for the two 429s that differ only by it.
 * @returns {"trial"|"monthly"|"ceiling"|"rejected"|"unavailable"|null}
 */
export function refusalReason(status, body = "") {
  // services/relay/src/quota.mjs: "the free trial is used up"
  if (status === 402) return "trial";

  const text = String(body).toLowerCase();
  if (status === 429) {
    // quota.mjs: "this month's fair-use limit is used up"
    if (text.includes("fair-use")) return "monthly";
    // quota.mjs: "the service is at its daily ceiling"
    if (text.includes("daily ceiling")) return "ceiling";
    // relay.mjs: "rate limit exceeded", the in-memory per-container limiter.
    return "unavailable";
  }
  // A token the relay will not accept cannot heal by being sent again: 401 is
  // malformed, 403 revoked (services/relay/src/relay.mjs). Retrying would
  // upload every remaining chunk only to have each rejected, so this is final,
  // and it is the one refusal whose fix is in Settings.
  if (status === 401 || status === 403) return "rejected";

  // relay.mjs: "usage service unavailable"; 0 = the request never landed.
  if (status === 503 || status === 0) return "unavailable";
  return status >= 400 ? "unavailable" : null;
}

/**
 * Which refusals answer for the whole session, and which are worth retrying: a
 * trial, a monthly cap and a daily ceiling are facts about the account or the
 * day, so every later chunk would hear the same thing. `unavailable` is
 * deliberately not in this set: the relay's in-memory limiter allows 30
 * requests a minute per token (services/relay/src/relay.mjs), so a burst 429
 * partway through a long recording is plausible and transient, and treating it
 * as final would silently drop every word after it.
 */
export const REFUSAL_IS_FINAL = new Set(["trial", "monthly", "ceiling", "rejected"]);

/**
 * The one reason the review window shows, from everything the transcript knows.
 *
 * Ordered by what a user can act on: a refusal outranks a count of failed
 * chunks, which outranks `degradedHolds`. That last one is not about the cloud
 * (the cloud text survived; the on-device clock was lost), so it is named
 * "timing" rather than folded in with the others.
 *
 * @returns {"trial"|"monthly"|"ceiling"|"rejected"|"unavailable"|"on-device"|"timing"|null}
 */
export function degradedReason({ cloud, degradedHolds } = {}) {
  if (cloud?.refused) return cloud.refused;
  if ((cloud?.failedChunks ?? 0) > 0) return "unavailable";
  // No relay in this build: a misconfiguration, not a fact about the plan.
  // `selectTranscriber` reaches the on-device recogniser only with neither a
  // BYO Groq key (which names itself `groq:…`) nor a DEIKO_RELAY_URL, and the
  // branches above already took every case where a relay was reached and then
  // refused or failed. A spent trial is answered by a purchase, this by a
  // rebuild. Ahead of "timing" because a wholly local transcript is the larger
  // claim, and timing's "what you said is intact" is the wrong reassurance for
  // it.
  if (cloud?.transcriber === "on-device") return "on-device";
  if (degradedHolds?.length) return "timing";
  return null;
}

/**
 * One retry per chunk: a dropped connection or a burst 429 usually clears a
 * moment later. `attempt(last)` is told which try it is, so a failure it
 * reports only on the last one ("the cloud was unavailable") is not reported
 * by a first try the retry then rescues.
 */
export async function withOneRetry(attempt, delayMs = 1500) {
  try {
    return await attempt(false);
  } catch {
    await new Promise((resolve) => setTimeout(resolve, delayMs));
    return attempt(true);
  }
}
