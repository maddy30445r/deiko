// Every decision about tiers, caps and storage keys, with no network or
// database access, so the arithmetic that decides whether somebody is
// transcribed is testable with `node --test` and no AWS account. `usage.mjs`
// reads and writes the numbers; this file says what they mean.

import { isIPv6 } from "node:net";

/// A free install gets thirty minutes of relay audio once, not per month. After
/// the trial the app falls back to Apple's on-device recogniser, which costs the
/// service nothing.
export const FREE_TRIAL_SECONDS = 30 * 60;

/// Pro's fair use: a ceiling for the pathological case, not a budget. Real
/// sessions are seconds long, so reaching it means a stuck client, which the
/// burst limiter and GLOBAL_DAILY_SECONDS are for. Bringing your own key is free
/// on every plan and costs the service nothing. This cap does not bound the
/// bill; GLOBAL_DAILY_SECONDS does.
export const PRO_MONTHLY_SECONDS = 10 * 60 * 60;

/// The backstop that does not depend on honest clients: whatever anybody mints,
/// the service will not buy more than this much audio in a day.
///
/// Per-subject limits can be forged (a VM, a second Mac or a patched client mints
/// fresh device tokens). This one fails closed for everyone at once, paying
/// customers included, so keep it high enough that Pro users pinning their
/// monthly cap do not make it the limit people hit.
///
/// It is the only guard on the transcription vendor's spend; the AWS budget
/// alarm watches the AWS bill only. Set a spend limit in the vendor's own
/// console as well.
export const GLOBAL_DAILY_SECONDS =
  Number(process.env.DEIKO_GLOBAL_DAILY_SECONDS ?? 12 * 60 * 60);

/// The share of the day's ceiling that free callers may spend.
///
/// The ceiling fails closed for everyone, and device tokens are forgeable, so a
/// script minting trials could otherwise walk the service to the ceiling and 429
/// every paying customer. A licence cannot be forged (Polar validates it), so
/// Pro gets the half of the day free traffic cannot reach. Refused requests are
/// refunded, so free traffic cannot push the shared row past this share.
///
/// The cost is that a genuine free user is cut off earlier on a busy day and
/// falls back to on-device words, which beats cutting off somebody who paid.
export const FREE_GLOBAL_SHARE = 0.5;

/// The day's ceiling for one tier. Pro sees the whole thing.
export function globalCapFor(tier) {
  return tier === "pro"
    ? GLOBAL_DAILY_SECONDS
    : Math.floor(GLOBAL_DAILY_SECONDS * FREE_GLOBAL_SHARE);
}

/// Summaries have their own daily budget. `/v1/summarize` accepts any bearer
/// string on purpose, so somebody with a spent trial still gets the sentence
/// saying what Deiko heard. Metering it against the audio ceiling would make it
/// the cheapest way to close that ceiling (rotating tokens walks past the burst
/// limiter). Its own row means a summary flood exhausts only summaries; it
/// counts requests, not seconds.
export const SUMMARIES_PER_DAY =
  Number(process.env.DEIKO_SUMMARIES_PER_DAY ?? 2000);

/// Classifications: same shape and reasoning as summaries (a text call that
/// takes any bearer, on its own row, counted in requests).
///
/// Sized from the largest request, not the average: one classify can be up to
/// three upstream requests (round 1 over twenty shortlisted tasks, plus up to
/// two second looks), several times a summary's input. Like every ceiling here
/// it bounds the blast radius of a stranger with the URL, not honest use, and
/// the counter is global.
export const CLASSIFIES_PER_DAY =
  Number(process.env.DEIKO_CLASSIFIES_PER_DAY ?? 1000);

/// One caller's share of those two days. The ceilings above are global, so a
/// single script could otherwise switch a route off for everybody until
/// midnight. These sit in front of them: per subject (the bearer), and per
/// hashed address so rotating bearers from one machine resets nothing. The
/// address cap is twice the subject's so an office behind one NAT is not treated
/// as one person.
export const SUMMARIES_PER_CALLER_PER_DAY =
  Number(process.env.DEIKO_SUMMARIES_PER_CALLER_PER_DAY ?? 200);
export const CLASSIFIES_PER_CALLER_PER_DAY =
  Number(process.env.DEIKO_CLASSIFIES_PER_CALLER_PER_DAY ?? 200);
export const TEXT_CALLS_PER_IP_PER_DAY =
  Number(process.env.DEIKO_TEXT_CALLS_PER_IP_PER_DAY ?? 400);

/// 16 kHz, mono, 16-bit: two bytes a sample, 32,000 bytes a second. The client's
/// chunker uses the same constants.
///
/// The bytes are the duration because /v1/transcribe accepts only the app's own
/// WAV (PCM, 16 kHz, mono, 16-bit, in the 44-byte header `wrapWav` writes) and
/// meters the data after that header. The format check in relay.mjs enforces
/// this; nothing here parses.
export const BYTES_PER_SECOND = 32_000;

/// No single request may count as more than this, and relay.mjs refuses any
/// upload longer than it, so what is metered is what Groq hears. The client's
/// chunker splits at 25 seconds (about 27 where it waits for a pause). The clamp
/// in `audioSeconds` is the second line of defence: the counter is incremented
/// before it is judged, so an unclamped oversized body would spend the daily
/// ceiling.
export const MAX_SECONDS_PER_REQUEST = 40;

/// The least a request counts as, however short the audio. A request has a cost
/// of its own (a Lambda slot, two writes, a Groq call), so the floor makes the
/// day's ceiling bound the number of calls as well as the audio. Honest chunks
/// are 25 seconds and never meet it; rounding up is the safe direction for a
/// limit to be wrong in.
export const MIN_SECONDS_PER_REQUEST = 5;

export function audioSeconds(byteLength) {
  if (!byteLength || byteLength < 0) return 0;
  return Math.min(byteLength / BYTES_PER_SECOND, MAX_SECONDS_PER_REQUEST);
}

/// What an id may contain: a security boundary, not tidiness.
///
/// The id is interpolated into row keys (`lic:<id>`, `lic:<id>#<month>`,
/// `lic:<id>#trial`, `dev:<id>`), so any character meaningful in that grammar
/// lets one row be spelled two ways. A crafted id could make `licenseKey()`
/// return a real key's monthly usage row, which `tierFor` then overwrites with
/// `PutItem` (it replaces the whole item), resetting that customer's month.
/// Length matters too: DynamoDB's partition key stops at 2048 bytes, and an
/// over-long id would make the subject write throw while the global write
/// succeeded, banking seconds that no refund path could reach.
///
/// The charset is what the real issuers produce: Polar licence keys
/// (alphanumeric and dashes), the 32-hex device digest, and legacy unprefixed
/// UUIDs.
const ID_ALLOWED = /^[A-Za-z0-9_-]{1,128}$/;

/// What a Polar licence key looks like, accepted two ways: an optional brand
/// prefix followed by a UUID4 (Polar's documented format), or Deiko's own
/// `DEIKO-` prefix with a plausible body. Anything else is junk and is refused
/// without a Polar call. Getting this wrong reads every buyer as Free; change
/// the prefix here if it changes in Polar.
const UUID_SUFFIX = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DEIKO_PREFIXED = /^DEIKO-[A-Za-z0-9-]{12,}$/i;
export function isPolarKey(id) {
  const s = String(id);
  return UUID_SUFFIX.test(s) || DEIKO_PREFIXED.test(s);
}

/// Which kind of caller a bearer token is. The prefix is load-bearing: a Polar
/// licence key and a Deiko device token are both v4-shaped UUIDs and cannot be
/// told apart by shape. A bare, unprefixed value is a device token, which is
/// what older builds send; those installs land on the free tier.
export function subjectFrom(token) {
  if (typeof token !== "string" || token.length === 0) return null;
  if (token.startsWith("lic_")) {
    const id = token.slice(4);
    return ID_ALLOWED.test(id) ? { kind: "license", id } : null;
  }
  if (token.startsWith("dev_")) {
    const id = token.slice(4);
    return ID_ALLOWED.test(id) ? { kind: "device", id } : null;
  }
  return ID_ALLOWED.test(token) ? { kind: "device", id: token } : null;
}

/// The row a subject's usage accumulates in.
///
/// A trial is lifetime and a subscription renews; the tier decides which, not
/// the shape of the token. A lifetime row carries no month and never expires (an
/// expiring trial would be a monthly free tier). A monthly row carries the month
/// and expires on its own, so there is no reset job.
///
/// The tier argument matters: keying on `subject.kind` alone would give a
/// licence Polar has never heard of the monthly row with the free trial's cap,
/// a free trial that resets every month. The `#trial` suffix is also
/// load-bearing: `licenseKey` returns a bare `lic:<id>` for the cached Polar
/// verdict and `tierFor` writes it with PutItem, which replaces the whole item,
/// so a trial counter sharing that key would be wiped on every revalidation.
export function usageKey(subject, now, tier) {
  if (subject.kind === "device") return `dev:${subject.id}`;
  if (tier !== "pro") return `lic:${subject.id}#trial`;
  return `lic:${subject.id}#${monthKey(now)}`;
}

/// Where a licence's cached Polar verdict lives. Deliberately not the same row
/// as its usage: the verdict outlives any one month.
export function licenseKey(subject) {
  return `lic:${subject.id}`;
}

export function globalKey(now) {
  return `global#${dayKey(now)}`;
}

/// Where the day's summary count lives. A different row from the audio ceiling:
/// the two budgets bound different vendors' bills and must not close each other.
export function summaryKey(now) {
  return `global#${dayKey(now)}#summary`;
}

/// The day's classification count. Its own row, like the summary's, so the two
/// vendors' bills cannot close each other.
export function classifyKey(now) {
  return `global#${dayKey(now)}#classify`;
}

/// One caller's count on a text route today. `who` is `dev:<id>`, `lic:<id>`
/// or `ip:<hash>` — ids are `[A-Za-z0-9_-]`, so none of them can spell another
/// row's key.
export function callerKey(route, who, now) {
  return `${route}:${who}#${dayKey(now)}`;
}

/// What counts as one address: an IPv4 address is one; an IPv6 address is its
/// /64, which is what one subscriber is handed (keying on the full address would
/// let a single line mint a fresh identity per request).
///
/// The all-zero /64 is the exception: it holds `::1` and every IPv4-mapped
/// address (`::ffff:a.b.c.d`, however spelled), and bucketing it would put every
/// IPv4 caller reported in hex by a dual-stack socket into one bucket. A mapped
/// address is the IPv4 address it carries; anything else there is its own
/// address.
export function ipBucket(ip) {
  const addr = String(ip ?? "").split("%")[0];
  if (!isIPv6(addr)) return addr;
  // Eight 16-bit groups, a dotted IPv4 tail counted as the two it is.
  const v4 = /(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(addr);
  const hex = v4
    ? `${addr.slice(0, v4.index)}${((v4[1] << 8) | v4[2]).toString(16)}:${((v4[3] << 8) | v4[4]).toString(16)}`
    : addr;
  const [head, tail] = hex.split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const g = [...left, ...Array(8 - left.length - right.length).fill("0"), ...right].map((x) => parseInt(x, 16));
  if (g.slice(0, 4).some(Boolean)) return `${g.slice(0, 4).map((x) => x.toString(16)).join(":")}::/64`;
  if (g[4] === 0 && g[5] === 0xffff) return [g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255].join(".");
  return g.map((x) => x.toString(16)).join(":");
}

/// The website playground lets anybody spend the Groq key without installing
/// anything, so it gets its own budget rows: the global audio ceiling fails
/// closed for everyone, and a public page is the easiest thing to point a script
/// at.
///
/// Counted in requests, not seconds. The byte-length estimate is honest only
/// about PCM, and a browser sends compressed audio (a ten-second Opus clip would
/// meter as under a second). One clip is one unit, clip length is bounded by
/// `PLAYGROUND_MAX_CLIP_BYTES`, and the day's bill is bounded by the count.
///
/// Deliberately small; raise it once the page has shown it is worth the spend.
export const PLAYGROUND_CLIPS_PER_DAY =
  Number(process.env.DEIKO_PLAYGROUND_CLIPS_PER_DAY ?? 200);

/// The model call that turns a sentence into a patch. Cheaper than audio, but
/// still a bill on a public page.
export const PLAYGROUND_INTENTS_PER_DAY =
  Number(process.env.DEIKO_PLAYGROUND_INTENTS_PER_DAY ?? 400);

/// What one visitor may spend before the page has to ask for a new ticket: two
/// clips of twenty seconds, about forty seconds of talking. Shorter cut real
/// sentences mid-word, which read as bad transcription rather than a limit.
export const PLAYGROUND_CLIPS_PER_TICKET =
  Number(process.env.DEIKO_PLAYGROUND_CLIPS_PER_TICKET ?? 2);

/// The only bound on clip length, since compressed audio cannot be metered by
/// time before it is decoded. Twenty seconds of Opus at the page's 24 kbps is
/// about 60 KB; 192 KB leaves room for a browser that picks a fatter codec while
/// still refusing much longer recordings. Raise it with the clip length or clips
/// 413.
export const PLAYGROUND_MAX_CLIP_BYTES =
  Number(process.env.DEIKO_PLAYGROUND_MAX_CLIP_BYTES ?? 192 * 1024);

/// How long a browser ticket is good for. Short, because only the daily ceiling
/// stops a scraper minting them.
export const PLAYGROUND_TICKET_TTL_MS =
  Number(process.env.DEIKO_PLAYGROUND_TICKET_TTL_MS ?? 15 * 60 * 1000);

/// How many times one visitor may ask. The clip cap alone is not a limit: the
/// page can type instead of speak, which skips transcription and reaches the
/// model route without spending a clip. A query is one interpreted instruction,
/// spoken or typed.
export const PLAYGROUND_QUERIES_PER_TICKET =
  Number(process.env.DEIKO_PLAYGROUND_QUERIES_PER_TICKET ?? 2);

/// How many tickets one caller may mint. Without it the per-ticket caps bound
/// nothing, since reloading the page asks for another. Keyed by a hash of the
/// address, never the address, so no raw IP is stored in DynamoDB.
export const PLAYGROUND_TICKETS_PER_IP_PER_DAY =
  Number(process.env.DEIKO_PLAYGROUND_TICKETS_PER_IP_PER_DAY ?? 4);

export function playgroundClipKey(now) {
  return `global#${dayKey(now)}#pgclip`;
}

export function playgroundIntentKey(now) {
  return `global#${dayKey(now)}#pgintent`;
}

/// One ticket's own spend, so a single visitor cannot drink the day.
export function playgroundTicketKey(id) {
  return `pg:${id}`;
}

/// A ticket's interpreted instructions, counted apart from its clips.
export function playgroundTicketQueryKey(id) {
  return `pg:${id}#q`;
}

/// How many tickets one caller has taken today. `hash` is already a digest.
export function playgroundIpKey(hash, now) {
  return `pgip:${hash}#${dayKey(now)}`;
}

/// `YYYY-MM` and `YYYY-MM-DD`, in UTC: the service runs in one region and the
/// callers are worldwide, and a limit that resets at an unpredictable local hour
/// reads as a bug.
export function monthKey(now) {
  return new Date(now).toISOString().slice(0, 7);
}

export function dayKey(now) {
  return new Date(now).toISOString().slice(0, 10);
}

/// Rows expire on their own: forty days for a monthly counter, so the row
/// outlives the month it measures, and a week for the daily rows, which nothing
/// reads after the day they count.
export const MONTHLY_TTL_SECONDS = 40 * 24 * 60 * 60;
export const DAILY_TTL_SECONDS = 7 * 24 * 60 * 60;

/// What a subject is allowed, in seconds of audio.
///
/// A licence the store does not recognise is not a trial. The trial belongs to
/// the device (the device token is derived from the machine, so it is once per
/// Mac); handing the same allowance to anyone who can type a licence string
/// would let a caller mint trials by choosing the key, and no row-key scheme
/// fixes that. A licence is worth what Polar says it is, nothing until then, and
/// removing a key that does not validate returns the user to their device's
/// trial.
///
/// `kind` is optional so an unknown caller reads as a device, the
/// generous-to-the-honest direction and what an unprefixed legacy token means.
export function capFor(tier, kind) {
  if (tier === "pro") return PRO_MONTHLY_SECONDS;
  return kind === "license" ? 0 : FREE_TRIAL_SECONDS;
}

/// The decision. Both totals are the values after this request's audio has been
/// added: the counter is incremented first and judged second, in one round trip
/// with no window where two concurrent chunks both see room only one can have.
/// Being over by one chunk is acceptable.
///
/// The global ceiling is checked first and reported as 429, because it is the
/// service's problem, not the caller's; telling a paying customer they are out
/// of quota would send them to support instead of a retry.
///
/// A free caller past their trial gets 402, not 429: `transcribe.mjs` treats 402
/// as "fall back to on-device and carry on", while a 429 is a transient
/// condition worth surfacing.
export function decide({ tier, kind, usedSeconds, globalUsedSeconds }) {
  const cap = capFor(tier, kind);

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
          // 402 either way, because the client's handling is the same (stop
          // uploading, keep Apple's words) but the sentence differs: a licence
          // holder told "your trial is used up" would look for a trial they
          // never started.
          error: kind === "license"
            ? "that licence is not active — remove it to use this Mac's trial"
            : "the free trial is used up — transcription continues on your Mac",
          remainingSeconds: 0,
        };
  }

  return {
    allowed: true,
    status: 200,
    remainingSeconds: Math.max(0, Math.round(cap - usedSeconds)),
  };
}
