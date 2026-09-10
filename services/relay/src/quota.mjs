// ─────────────────────────────────────────────────────────────────────────────
// WHO IS CALLING, AND MAY THEY
//
// Every decision about tiers, caps and storage keys, and NOT ONE of them talks
// to the network or to a database. That split is the same one the Swift package
// makes — the decision layers live in their own targets so they can be tested
// without a screen, a microphone or a window server. Here it means the
// arithmetic that decides whether somebody gets transcribed is checked by `node
// --test` in milliseconds, with no AWS account involved.
//
// `usage.mjs` reads and writes the numbers. This file only says what they mean.
// ─────────────────────────────────────────────────────────────────────────────

/// A free install gets thirty minutes of relay audio ONCE — not thirty a month.
///
/// The recurring version was the earlier plan and it is a small annuity paid to
/// everybody who never intends to buy: at ₹30/hour it is only ~₹15 each, but it
/// is ₹15 every month, forever, times however many people a video reaches.
///
/// After the trial the app does not stop working — it drops to Apple's
/// on-device recogniser, which costs us nothing and is already the documented
/// third path in `selectTranscriber`. The accuracy people lose is exactly the
/// accuracy Pro sells, especially on mixed-language speech, so the free tier
/// argues for the paid one by being honest rather than by being crippled.
export const FREE_TRIAL_SECONDS = 30 * 60;

/// Pro's fair use. At Sarvam's ₹30/hour this is ₹300/month of audio against a
/// $3.99/month or $29.99/year subscription — so it is a ceiling for the pathological
/// case and NOT a budget. BE PRECISE ABOUT WHAT THAT MEANS NOW: after Polar's
/// 5% + 50¢ a monthly subscription nets ~₹283 and an annual one ~₹201 a month,
/// so a licence that actually pinned this cap would cost more than it pays.
/// Five hours could not do that; ten can.
///
/// It is priced anyway because nobody reaches it. Measured sessions run a
/// median of 9 seconds and a mean of 14 — audio is recorded per hold and the
/// silence between holds is never captured — so ten hours is between two and a
/// half and four thousand sessions, over eighty a day every day. That is a
/// stuck client, which is what the burst limiter and the global ceiling below
/// are for, and a genuine heavy user has a cheaper door: BYO key is a Pro
/// feature, and a licence using its own Sarvam key costs us nothing at all.
///
/// Raised from five hours at the same price. The cap was never what bounded
/// the bill — GLOBAL_DAILY_SECONDS is — and five hours was already three times
/// what the heaviest real session log suggests anybody uses.
export const PRO_MONTHLY_SECONDS = 10 * 60 * 60;

/// THE BACKSTOP THAT DOES NOT DEPEND ON HONEST CLIENTS.
///
/// Per-subject limits are harder to forge than they were and are not
/// unforgeable: the device token is derived from the machine's hardware id
/// rather than kept in preferences, so `defaults delete` no longer mints a
/// fresh trial — but a VM, a second Mac, or a patched client still will, and no
/// amount of cleverness in a client we ship can change that. This is the number
/// that actually bounds the bill — whatever anybody mints, the service will not
/// buy more than this much audio in a day.
///
/// Twelve hours is ₹360/day. It was four, and it had to move when Pro went
/// from five hours a month to ten: at four hours a day the whole service buys
/// 120 hours a month, so a dozen licences pinning a ten-hour cap would have
/// made the limit people actually hit this one — and this one fails CLOSED FOR
/// EVERYONE AT ONCE, paying customers included. Advertising a cap the service
/// cannot honour is worse than advertising a smaller one. Twelve hours a day
/// is 360 a month: three dozen Pro users all pinning their cap, or several
/// hundred at the usage anybody actually has.
///
/// THE COST OF THAT, STATED: this is the only guard on Sarvam spend anywhere
/// in this repo. The AWS budget alarm watches the AWS bill, and Sarvam is a
/// different vendor — so a maximally bad month is now ~₹10,800 rather than
/// ~₹3,600, and nothing but this number stops it. Set a cap in Sarvam's own
/// dashboard as well; that is the guard this file cannot provide.
export const GLOBAL_DAILY_SECONDS =
  Number(process.env.DEIKO_GLOBAL_DAILY_SECONDS ?? 12 * 60 * 60);

/// HOW MUCH OF THE DAY FREE CALLERS MAY SPEND.
///
/// The ceiling above fails CLOSED FOR EVERYONE AT ONCE, which made it a lever:
/// a device token is derived from the machine and is therefore FORGEABLE — a
/// VM, a second Mac or a patched client mints as many as it likes, each with a
/// fresh thirty-minute trial. Two dozen of them walk the whole service to its
/// ceiling and 429 every paying customer until UTC midnight, for the price of
/// some junk audio.
///
/// A LICENCE CANNOT BE FORGED — Polar validates it — so the unforgeable
/// callers get the half of the day that the forgeable ones cannot reach.
/// Refused requests are refunded, so free traffic cannot push the shared row
/// past this share no matter how many tokens it mints.
///
/// The cost, stated: a genuine free user is cut off earlier on a busy day.
/// They fall through to Apple's on-device words, which is the free tier
/// working as designed — and it is the correct thing to sacrifice, because the
/// alternative sacrifices somebody who paid.
export const FREE_GLOBAL_SHARE = 0.5;

/// The day's ceiling for one tier. Pro sees the whole thing.
export function globalCapFor(tier) {
  return tier === "pro"
    ? GLOBAL_DAILY_SECONDS
    : Math.floor(GLOBAL_DAILY_SECONDS * FREE_GLOBAL_SHARE);
}

/// SUMMARIES HAVE THEIR OWN DAY, AND THIS IS WHY.
///
/// `/v1/summarize` accepts any bearer string on purpose — somebody whose trial
/// is spent still gets the sentence that says what Deiko heard. It used to be
/// metered as five nominal seconds against the audio ceiling above, which made
/// it the cheapest way to close that ceiling: no licence, no valid token, and
/// the burst limiter is keyed by token so rotating tokens walks straight past
/// it. Eight thousand cheap text calls locked out every paying customer.
///
/// Its own row and its own budget means a summary flood now exhausts only
/// summaries. Counted in REQUESTS rather than seconds, because that is what a
/// summary is — the seconds were always a fiction to make it share a counter
/// it should never have shared.
export const SUMMARIES_PER_DAY =
  Number(process.env.DEIKO_SUMMARIES_PER_DAY ?? 2000);

/// 16 kHz, mono, 16-bit — so two bytes a sample, 32,000 bytes a second. The
/// client's chunker uses exactly these constants.
///
/// Derived from the body's LENGTH, never by parsing it. The relay's header
/// promises it does not touch the audio, and a quota is not a good enough
/// reason to break that: the multipart wrapper adds a few hundred bytes, which
/// overestimates by well under a percent, and over-counting is the correct
/// direction for a limit to be wrong in.
///
/// The under-count direction is accepted, and bounded: a body that is not
/// 16-bit 16 kHz PCM — compressed audio, a lower rate — meters as fewer
/// seconds than Sarvam hears, up to roughly 10× if Sarvam accepts it at all.
/// Fixing it means parsing the audio, which the promise above forbids. What
/// bounds it instead: Sarvam rejects clips over ~30 s regardless of size, the
/// per-request clamp below, the global daily ceiling, and the budget alarm.
export const BYTES_PER_SECOND = 32_000;

/// No single request may count as more than this. The client's chunker splits
/// at 25 seconds, so a request claiming more than 40 is not a chunk — and
/// because the counter is incremented before it is judged (see `relay.mjs`),
/// an unclamped one let a handful of oversized junk bodies spend the whole
/// service's daily ceiling and lock out everybody paying. Clamping is the
/// right direction to be wrong in: an honest chunk is never near it.
export const MAX_SECONDS_PER_REQUEST = 40;

export function audioSeconds(byteLength) {
  if (!byteLength || byteLength < 0) return 0;
  return Math.min(byteLength / BYTES_PER_SECOND, MAX_SECONDS_PER_REQUEST);
}

/// Which kind of caller a bearer token is.
///
/// THE PREFIX IS LOAD-BEARING, because a Polar licence key and a Deiko
/// device token are both v4-shaped UUIDs and cannot be told apart by looking.
/// An earlier design said "the relay tells them apart by shape"; it would have
/// sent every free user's token to Polar for validation, and every
/// licence key would have metered as a free trial.
///
/// A bare, unprefixed value is a DEVICE token, because that is what every build
/// up to 0.3.0 sends. Old installs keep working and land on the free tier,
/// which is what they are.
export function subjectFrom(token) {
  if (typeof token !== "string" || token.length === 0) return null;
  if (token.startsWith("lic_")) {
    const id = token.slice(4);
    return id ? { kind: "license", id } : null;
  }
  if (token.startsWith("dev_")) {
    const id = token.slice(4);
    return id ? { kind: "device", id } : null;
  }
  return { kind: "device", id: token };
}

/// The row a subject's usage accumulates in.
///
/// A TRIAL IS LIFETIME; A SUBSCRIPTION RENEWS. That is the whole rule, and the
/// tier is what decides which one you are — not the shape of your token.
///
/// A lifetime row carries no month and never expires: a trial that quietly
/// renewed itself every forty days because of a TTL would be a monthly free
/// tier wearing a different name. A monthly row carries the month and expires
/// on its own, so there is no reset job to write and none to forget to run.
///
/// The tier argument is not decoration. Keying on `subject.kind` alone meant a
/// licence that Polar had never heard of — any string at all typed
/// into Settings' licence field — still got the MONTHLY row, while its cap was
/// the free trial's thirty minutes. Thirty free minutes every calendar month,
/// forever, self-resetting, for anybody who typed junk; thirty minutes once,
/// ever, for anybody honest. The forgery was strictly better than the truth.
/// The `#trial` suffix is load-bearing rather than decorative: `licenseKey`
/// returns a bare `lic:<id>` for the cached Polar verdict, and
/// `tierFor` writes that row with PutItem, which REPLACES the whole item. A
/// trial counter sharing that key would be wiped clean every time the verdict
/// was revalidated — the same forgery back again, wearing a subtler disguise.
export function usageKey(subject, now, tier) {
  if (subject.kind === "device") return `dev:${subject.id}`;
  if (tier !== "pro") return `lic:${subject.id}#trial`;
  return `lic:${subject.id}#${monthKey(now)}`;
}

/// Where a licence's cached Polar verdict lives. Deliberately NOT the
/// same row as its usage: the verdict outlives any one month.
export function licenseKey(subject) {
  return `lic:${subject.id}`;
}

export function globalKey(now) {
  return `global#${dayKey(now)}`;
}

/// Where the day's summary count lives. A DIFFERENT ROW from the audio
/// ceiling, which is the whole point — the two budgets bound two different
/// vendors' bills and must not be able to close each other.
export function summaryKey(now) {
  return `global#${dayKey(now)}#summary`;
}

/// `2026-08` and `2026-08-10`, in UTC.
///
/// UTC rather than any local zone because the service runs in one region and
/// the callers are worldwide: a month that begins at midnight somewhere in
/// particular would roll over mid-afternoon for most people, and a limit that
/// resets at an hour nobody can predict reads as a bug.
export function monthKey(now) {
  return new Date(now).toISOString().slice(0, 7);
}

export function dayKey(now) {
  return new Date(now).toISOString().slice(0, 10);
}

/// Rows expire on their own. Forty days for a monthly counter so the row
/// outlives the month it measures by a comfortable margin; a week for the
/// global daily row, which nothing reads after the day it counts.
export const MONTHLY_TTL_SECONDS = 40 * 24 * 60 * 60;
export const DAILY_TTL_SECONDS = 7 * 24 * 60 * 60;

/// What a tier is allowed, in seconds of audio.
export function capFor(tier) {
  return tier === "pro" ? PRO_MONTHLY_SECONDS : FREE_TRIAL_SECONDS;
}

/// THE DECISION.
///
/// Both totals are the values AFTER this request's audio has been added,
/// because the counter is incremented first and judged second: one round trip
/// instead of read-then-write, and no window in which two concurrent chunks
/// both see room that only one of them can have. The cost of being over by one
/// chunk is a few paise.
///
/// The global ceiling is checked FIRST and reported as 429, because it is our
/// problem and not the caller's — telling a paying customer they are out of
/// quota when in fact the service is, would be a lie that sends them to support
/// instead of to a retry.
///
/// A free caller past their trial gets 402, not 429. The distinction matters
/// downstream: `transcribe.mjs` treats 402 as "fall back to on-device and carry
/// on", which is the free tier working exactly as designed, while a 429 is a
/// transient condition worth surfacing.
export function decide({ tier, usedSeconds, globalUsedSeconds }) {
  const cap = capFor(tier);

  if (globalUsedSeconds > globalCapFor(tier)) {
    return {
      allowed: false,
      status: 429,
      error: "the service is at its daily ceiling — try again tomorrow",
      remainingSeconds: 0,
    };
  }

  if (usedSeconds > cap) {
    return tier === "pro"
      ? {
          allowed: false,
          status: 429,
          error: "this month's fair-use limit is used up",
          remainingSeconds: 0,
        }
      : {
          allowed: false,
          status: 402,
          error: "the free trial is used up — transcription continues on your Mac",
          remainingSeconds: 0,
        };
  }

  return {
    allowed: true,
    status: 200,
    remainingSeconds: Math.max(0, Math.round(cap - usedSeconds)),
  };
}
