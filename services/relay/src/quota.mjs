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

/// Pro's fair use. At Sarvam's ₹30/hour this is ₹150/month of audio against a
/// $4 subscription — a ceiling for the pathological case, not a budget anybody
/// normal will approach. Measured sessions on this machine run a median of 9
/// seconds, so five hours is roughly two thousand of them.
export const PRO_MONTHLY_SECONDS = 5 * 60 * 60;

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
/// Four hours is ₹120/day, so a maximally bad month is ~₹3,600 against an AWS
/// budget alarm set at ₹500. That gap is deliberate: the alarm should fire long
/// before the ceiling does, because the ceiling is the thing that stops a
/// disaster and the alarm is the thing that tells you one is starting.
export const GLOBAL_DAILY_SECONDS =
  Number(process.env.DEIKO_GLOBAL_DAILY_SECONDS ?? 4 * 60 * 60);

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

  if (globalUsedSeconds > GLOBAL_DAILY_SECONDS) {
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
