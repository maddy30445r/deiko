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

import { isIPv6 } from "node:net";

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

/// Pro's fair use. At Groq's $0.111/hour for whisper-large-v3 this is $1.11 a
/// month of audio against a $2.99/month or $24.99/year subscription — a ceiling
/// for the pathological case and NOT a budget. After Polar's 5% + 50¢ a monthly
/// subscription nets ~$2.34 and an annual one ~$1.94 a month, so a licence that
/// pinned this cap would still earn more than it costs. THAT WAS NOT TRUE when
/// the vendor was Sarvam at ₹30/hour and this comment said so; if the vendor or
/// the price moves again, redo this sum before trusting the cap.
///
/// Nobody reaches it in any case. Measured sessions run a
/// median of 9 seconds and a mean of 14 — audio is recorded per hold and the
/// silence between holds is never captured — so ten hours is between two and a
/// half and four thousand sessions, over eighty a day every day. That is a
/// stuck client, which is what the burst limiter and the global ceiling below
/// are for, and a genuine heavy user has a cheaper door: bringing a key is
/// free on every plan, and a caller using their own Groq key costs us nothing.
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
/// THE COST OF THAT, STATED: this is the only guard on the transcription
/// vendor's spend anywhere in this repo. The AWS budget alarm watches the AWS
/// bill, and Groq is a different vendor — so a maximally bad month is 360
/// hours, about $40 at the $0.111/hour above, and nothing but this number
/// stops it. Set a spend limit in the vendor's own console as well if it
/// offers one; that is the guard this file cannot provide.
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

/// Classifications, the same shape for the same reason: a text call that
/// takes any bearer, on its own row, counted in requests.
///
/// SIZED FROM THE BIGGEST REQUEST, NOT THE AVERAGE. The first number here was
/// 4000, justified as "a Jev decision costs a tenth of a summary" — which is
/// true of a decision about an empty board and false of the one this client
/// actually sends. A full request carries eight shortlisted tasks, about 10k
/// input tokens against a summary's 2k, so it costs a few times a summary rather
/// than a tenth of one. At Jev's $0.042 per million that is ~$0.0004 each, so
/// this ceiling is the day's worst case in money: about 40 cents.
///
/// Like every ceiling here it bounds the blast radius of a stranger with the
/// URL, not honest use — a thousand briefs a day across everybody is far past
/// anything real, and the counter is global rather than per person.
export const CLASSIFIES_PER_DAY =
  Number(process.env.DEIKO_CLASSIFIES_PER_DAY ?? 1000);

/// ONE CALLER'S SHARE OF THOSE TWO DAYS. The ceilings above are global, so a
/// single script could spend all of one on its own and switch the route off
/// for everybody until midnight. These sit in front of them: per subject (the
/// bearer), and per hashed address so that rotating bearers from one machine
/// does not reset anything. An honest install summarises and files a few
/// dozen briefs a day; the address cap is twice the subject's so an office
/// behind one NAT is not one person.
export const SUMMARIES_PER_CALLER_PER_DAY =
  Number(process.env.DEIKO_SUMMARIES_PER_CALLER_PER_DAY ?? 200);
export const CLASSIFIES_PER_CALLER_PER_DAY =
  Number(process.env.DEIKO_CLASSIFIES_PER_CALLER_PER_DAY ?? 200);
export const TEXT_CALLS_PER_IP_PER_DAY =
  Number(process.env.DEIKO_TEXT_CALLS_PER_IP_PER_DAY ?? 400);

/// 16 kHz, mono, 16-bit — so two bytes a sample, 32,000 bytes a second. The
/// client's chunker uses exactly these constants.
///
/// THE BYTES ARE THE DURATION because the relay makes them so: /v1/transcribe
/// accepts only the app's own WAV — PCM, 16 kHz, mono, 16-bit, in the 44-byte
/// header `wrapWav` writes — and meters the data after that header. This
/// used to be a byte count of whatever body arrived, forwarded as it came, so
/// compressed audio metered at a fraction of its length (8 kbps MP3 at 1/31).
/// The format check in relay.mjs is what closed that; nothing here parses.
export const BYTES_PER_SECOND = 32_000;

/// No single request may count as more than this, and relay.mjs refuses any
/// upload longer than it — so what is metered is what Groq hears. The client's
/// chunker splits at 25 seconds (about 27 where it waits for a pause), so a
/// request claiming more than 40 is not a chunk. The clamp in `audioSeconds`
/// stays as the second line: because the counter is incremented before it is
/// judged, an unclamped oversized body once let a handful of junk requests
/// spend the whole service's daily ceiling.
export const MAX_SECONDS_PER_REQUEST = 40;

/// WHAT THE CHEAPEST POSSIBLE REQUEST COSTS. Five seconds, however short the
/// audio: a floor on the price of a REQUEST, so the day's ceiling also bounds
/// how many calls can be made against it (~8,640 at twelve hours), not only
/// how much audio. It was first the only answer to compressed audio metering
/// short; the format check answers that now, and the floor stays because a
/// request has a cost of its own — a Lambda slot, two writes, a Groq call.
/// Honest chunks are 25 s and never meet it; only a hold shorter than five
/// seconds rounds up, which is the correct direction for a limit to be wrong in.
export const MIN_SECONDS_PER_REQUEST = 5;

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
/// WHAT AN ID MAY CONTAIN — a security boundary, not tidiness.
///
/// The id is INTERPOLATED INTO ROW KEYS — `lic:<id>`, `lic:<id>#<month>`,
/// `lic:<id>#trial`, `dev:<id>` — so any character that means something in that
/// grammar lets one row be spelled two ways. `lic_<key>#2026-09` made
/// `licenseKey()` return `lic:<key>#2026-09`, which IS the real key's monthly
/// usage row; `tierFor` then wrote its verdict there with `PutItem`, which
/// REPLACES THE WHOLE ITEM, and the customer's month reset to zero. One request
/// a day turned ten hours a month into ten hours a day.
///
/// Length is the same bug in a different hat: DynamoDB's partition key stops at
/// 2048 bytes, so an over-long id made the SUBJECT write throw while the global
/// write beside it succeeded — seconds banked against the whole service's day
/// that no refund path could reach, and no audio bought to show for them.
///
/// The charset is what the three real issuers produce and nothing else: Polar
/// licence keys (alphanumeric and dashes), the 32-hex device digest, and the
/// v4-shaped UUIDs every build up to 0.3.0 sent unprefixed.
const ID_ALLOWED = /^[A-Za-z0-9_-]{1,128}$/;

/// WHAT EVERY POLAR LICENCE KEY ENDS WITH: an optional brand prefix, then a
/// UUID4 (polar.sh/docs/features/benefits/license-keys, "MYAPP_<UUID4>").
/// A `lic_` id without one cannot be a key Polar issued.
export function isPolarKey(id) {
  return /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(id));
}

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

/// The day's classification count. Its own row, like the summary's, so the
/// classifier's vendor bill and the summary's cannot close each other.
export function classifyKey(now) {
  return `global#${dayKey(now)}#classify`;
}

/// One caller's count on a text route today. `who` is `dev:<id>`, `lic:<id>`
/// or `ip:<hash>` — ids are `[A-Za-z0-9_-]`, so none of them can spell another
/// row's key.
export function callerKey(route, who, now) {
  return `${route}:${who}#${dayKey(now)}`;
}

/// WHAT COUNTS AS ONE ADDRESS. An IPv4 address is one; an IPv6 address is
/// its /64, because that is what one subscriber is handed — keyed on the full
/// address, a single home line could mint a fresh identity per request and
/// the per-address caps bounded nothing.
///
/// EXCEPT THE /64 THAT IS ALL ZEROES, which is not a subscriber's: it holds
/// `::1` and every IPv4-mapped address (`::ffff:a.b.c.d`, however it is
/// spelled — dotted, hex, zero-padded). Bucketed like the rest it put every
/// IPv4 caller that a dual-stack socket reported in hex into ONE bucket, so
/// one of them could spend the others' allowance. A mapped address is the
/// IPv4 address it carries; anything else there is its own address.
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

/// ── THE PLAYGROUND ──────────────────────────────────────────────────────────
///
/// The website's playground lets anybody on the internet spend the Groq key
/// without installing anything. It gets its OWN budget rows so that it cannot
/// close transcription for the app, which is the failure that matters: the
/// global audio ceiling fails closed for everyone at once, and a public page
/// is the easiest thing in this repo to point a script at.
///
/// Counted in REQUESTS, not seconds. The byte-length estimate the app relies
/// on is honest only about PCM, and a browser sends compressed audio — a
/// ten-second Opus clip is a few tens of KB and would meter as under a second.
/// So the playground does not pretend to measure time at all: one clip is one
/// unit, the clip length is bounded by `PLAYGROUND_MAX_CLIP_BYTES`, and the
/// day's bill is bounded by the count.
/// Deliberately small while this is new. 200 clips × 20s is ~67 minutes of
/// Groq audio a day — pennies — and it is the number to raise once the page
/// has shown it is worth the spend, not before.
export const PLAYGROUND_CLIPS_PER_DAY =
  Number(process.env.DEIKO_PLAYGROUND_CLIPS_PER_DAY ?? 200);

/// The model call that turns a sentence into a patch. Cheaper than audio, but
/// it is still somebody else's bill on a public page.
export const PLAYGROUND_INTENTS_PER_DAY =
  Number(process.env.DEIKO_PLAYGROUND_INTENTS_PER_DAY ?? 400);

/// What one visitor may spend before the page has to ask for a new ticket.
/// Two clips at twenty seconds each — about forty seconds of talking. Ten
/// was too short in practice: it cut real sentences mid-word and whisper
/// returned a garbled fragment, which read as bad transcription rather than
/// as a limit being hit.
export const PLAYGROUND_CLIPS_PER_TICKET =
  Number(process.env.DEIKO_PLAYGROUND_CLIPS_PER_TICKET ?? 2);

/// THE ONLY THING BOUNDING CLIP LENGTH, since compressed audio cannot be
/// metered by time before it is decoded. Twenty seconds of Opus at the 24 kbps
/// the page asks for is ~60 KB; 192 KB leaves room for a browser that ignores
/// the hint and picks a fatter codec, while still refusing anything that could
/// only be a much longer recording. It tracks the clip length: if that goes
/// up again, this has to go up with it or clips 413 instead.
export const PLAYGROUND_MAX_CLIP_BYTES =
  Number(process.env.DEIKO_PLAYGROUND_MAX_CLIP_BYTES ?? 192 * 1024);

/// How long a browser ticket is good for. Short, because the only thing
/// stopping a scraper from minting them is the daily ceiling behind them.
export const PLAYGROUND_TICKET_TTL_MS =
  Number(process.env.DEIKO_PLAYGROUND_TICKET_TTL_MS ?? 15 * 60 * 1000);

/// HOW MANY TIMES ONE VISITOR MAY ASK. The clip cap alone was not a limit:
/// the page can type instead of speak, and typing skips transcription
/// entirely, so the model route was reachable without ever spending a clip.
/// A query is one interpreted instruction, spoken or typed.
export const PLAYGROUND_QUERIES_PER_TICKET =
  Number(process.env.DEIKO_PLAYGROUND_QUERIES_PER_TICKET ?? 2);

/// AND HOW MANY TICKETS ONE CALLER MAY MINT. Without this the per-ticket caps
/// bound nothing at all — reloading the page asks for another ticket, and a
/// script can ask a thousand times. Keyed by a HASH of the address, never the
/// address: the relay's header promises it logs no content, and an IP in
/// DynamoDB is the same kind of mistake.
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

/// What a subject is allowed, in seconds of audio.
///
/// A LICENCE THE STORE DOES NOT RECOGNISE IS NOT A TRIAL, and this is the third
/// time that idea has had to be written down. The first version keyed usage on
/// `subject.kind` alone, so junk got the MONTHLY row and thirty free minutes
/// every calendar month. The `#trial` suffix fixed the renewal and left the
/// rest: a lifetime trial row keyed on *whatever string was typed*, so thirty
/// minutes could be minted by typing `ee`, then `ff`, then `gg`, for ever.
///
/// The device token is derived from the machine precisely so the trial is once
/// per Mac — `defaults delete` cannot mint another. Handing the same allowance
/// to anyone who can type a character defeated that completely, and no amount
/// of row-key cleverness fixes it, because the caller chooses the key.
///
/// So: the trial belongs to the DEVICE, and a licence is worth exactly what
/// the store says it is worth — nothing, until Polar says otherwise. Somebody
/// who pastes a key that does not validate is told to remove it, and removing
/// it returns them to their own trial with whatever was left of it.
///
/// `kind` is optional so an unknown caller reads as a device, which is the
/// generous-to-the-honest direction and matches what an unprefixed legacy
/// token already means.
export function capFor(tier, kind) {
  if (tier === "pro") return PRO_MONTHLY_SECONDS;
  return kind === "license" ? 0 : FREE_TRIAL_SECONDS;
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
          // 402 EITHER WAY, because the client's handling is the same — stop
          // uploading, keep Apple's words, carry on — but the sentence is not,
          // and a licence holder told "your trial is used up" would go looking
          // for a trial they never started. Theirs ran out the moment the key
          // failed to validate, and the fix is to take it out.
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
