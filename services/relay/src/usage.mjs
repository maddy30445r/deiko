// ─────────────────────────────────────────────────────────────────────────────
// THE NUMBERS, AND WHERE THEY LIVE
//
// One DynamoDB table, `deiko-usage`, on-demand billing, partition key `subject`.
// Everything stateful the relay needs is a row in it:
//
//   dev:<token>              lifetime free-trial seconds. No TTL — the trial is
//                            once, and a row that expired would silently renew it.
//   lic:<key>#2026-08        a licence's audio seconds this month. 40-day TTL.
//   lic:<key>                the cached Polar verdict. Expires at four
//                            cache lifetimes; refreshed when older than a day.
//   global#2026-08-10        every subject's audio today. 7-day TTL.
//
// COUNTERS ARE INCREMENTED, NOT READ-THEN-WRITTEN. `UpdateItem` with `ADD`
// returns the new total in the same round trip, which is atomic across every
// concurrent Lambda container. Read-then-write would need a transaction to be
// correct, and would still cost two calls to be wrong more slowly.
//
// The SDK is bundled into the deployment zip rather than taken from the Lambda
// runtime — the runtime does provide one, but AWS's own guidance is to ship your
// own so the version is yours to choose. Hand-rolling SigV4 would have kept the
// zip dependency-free, which is tempting in a service that has no other
// dependencies, and it is the wrong place to save: a signing bug is a security
// bug, and this is three API calls.
// ─────────────────────────────────────────────────────────────────────────────

import {
  DynamoDBClient,
  UpdateItemCommand,
  GetItemCommand,
  PutItemCommand,
  DescribeTableCommand,
} from "@aws-sdk/client-dynamodb";

import {
  MONTHLY_TTL_SECONDS,
  DAILY_TTL_SECONDS,
  globalKey,
  licenseKey,
  summaryKey,
  usageKey,
} from "./quota.mjs";

const TABLE = process.env.DEIKO_USAGE_TABLE ?? "deiko-usage";
/// Polar's PUBLIC validate endpoint — the one its docs say is safe to call from
/// a desktop app — so the relay stores no Polar credential at all. The
/// authenticated `/v1/license-keys/validate` would buy nothing here except a
/// token to leak and to rotate.
///
/// `POLAR_API_BASE` points this at `https://sandbox-api.polar.sh` for a test
/// purchase against Polar's sandbox organisation.
const POLAR_API = process.env.POLAR_API_BASE ?? "https://api.polar.sh";
const POLAR_VALIDATE = `${POLAR_API}/v1/customer-portal/license-keys/validate`;

/// NOT A SECRET — it is in every checkout URL, and the validate endpoint is
/// unauthenticated by design. A constant rather than an environment variable
/// because a missing one would fail every validation, and a failed validation
/// demotes a paying customer.
const POLAR_ORGANIZATION_ID =
  process.env.POLAR_ORGANIZATION_ID ?? "a5147c76-3225-423b-ab8c-bdee6d06353a";

/// How long a Polar verdict is trusted before it is checked again.
///
/// `transcribe.mjs` splits audio at 25 seconds, so one long session is dozens of
/// relay calls; validating each against Polar would add a second of
/// latency per chunk and hammer somebody else's rate limit for an answer that
/// changes at most once a month. A cancellation therefore takes up to a day to
/// bite, which is the right trade for a $3.99 product.
const LICENSE_CACHE_MS = 24 * 60 * 60 * 1000;

/// How soon an ERROR-derived verdict is rechecked. Minutes, not a day: an
/// error is not a fact about the licence, only about the network between two
/// clouds, and it heals on Polar's schedule, not ours.
const ERROR_RETRY_MS = 5 * 60 * 1000;

/// What a caller is told when the usage table cannot be reached.
///
/// FIXED TEXT. The real error is a DynamoDB message carrying the table name
/// and an ARN-shaped resource string, and it was going straight into the HTTP
/// body of a public endpoint. It goes to CloudWatch instead, where the person
/// who needs it can read it and the person probing the service cannot.
export function unavailable(err) {
  console.error(`usage table unreachable: ${String(err?.message ?? err)}`);
  return "usage service unavailable";
}

/// Created once per container, not per request, so the connection and its TLS
/// handshake are reused across a warm Lambda's invocations.
let client;
function db() {
  client ??= new DynamoDBClient({});
  return client;
}

/// Can this relay actually meter, right now?
///
/// A REAL CALL, not a check on a configured name. The obvious version of this
/// reads an environment variable that has a default and reports whether it is
/// set — which is to say it reports `true` always, and reassures you on exactly
/// the deploy where the table is missing or the role has no policy. The one
/// thing this flag exists to catch is the one thing that version cannot see.
///
/// `DescribeTable` is a cheap control-plane call, and `/health` is asked at
/// deploy time rather than per request.
export async function meteringHealthy() {
  try {
    const out = await db().send(new DescribeTableCommand({ TableName: TABLE }));
    return out.Table?.TableStatus === "ACTIVE";
  } catch {
    return false;
  }
}

export const USAGE_TABLE = TABLE;

/// Add `seconds` to a subject's counter and return the new total.
///
/// `ttl` is only set on rows that should expire. DynamoDB ignores the attribute
/// unless TTL is enabled on the table pointing at this exact name, so a missing
/// TTL config shows up as rows that never expire — costing storage, never
/// correctness.
async function addSeconds(key, seconds, ttlSeconds) {
  const expression = ttlSeconds
    ? "ADD audioSeconds :n SET expiresAt = if_not_exists(expiresAt, :ttl)"
    : "ADD audioSeconds :n";

  const values = { ":n": { N: String(seconds) } };
  if (ttlSeconds) {
    values[":ttl"] = { N: String(Math.floor(Date.now() / 1000) + ttlSeconds) };
  }

  const out = await db().send(new UpdateItemCommand({
    TableName: TABLE,
    Key: { subject: { S: key } },
    UpdateExpression: expression,
    ExpressionAttributeValues: values,
    ReturnValues: "UPDATED_NEW",
  }));

  return Number(out.Attributes?.audioSeconds?.N ?? 0);
}

/// What a subject has spent, WITHOUT spending any more.
///
/// Serves `/v1/quota`, which the app asks the moment somebody pastes a licence
/// key — the answer is the confirmation that the key worked, and it has to be
/// available before a session has ever run. A read cannot be the same call as
/// the increment for that reason alone.
export async function peek(subject, tier, now = Date.now()) {
  const out = await db().send(new GetItemCommand({
    TableName: TABLE,
    Key: { subject: { S: usageKey(subject, now, tier) } },
  }));
  return Number(out.Item?.audioSeconds?.N ?? 0);
}

/// Count this request against the subject and against the day, and report both
/// new totals.
///
/// The two writes are independent, so they go together — one round trip's
/// latency rather than two, on the path a user is waiting on.
/// The TTL follows the KEY, not the token's shape. A monthly row expires so
/// the next month starts clean; a lifetime row must not, or the trial renews
/// itself every forty days. Only a Pro licence gets the monthly row, so only a
/// Pro licence gets the TTL — a free licence is a trial like any other, and
/// giving it an expiring row is exactly the bug `usageKey` documents.
export async function record({ subject, seconds, tier, now = Date.now() }) {
  const key = usageKey(subject, now, tier);
  const [usedSeconds, globalUsedSeconds] = await Promise.all([
    addSeconds(key, seconds, key.includes("#") && tier === "pro" ? MONTHLY_TTL_SECONDS : null),
    addSeconds(globalKey(now), seconds, DAILY_TTL_SECONDS),
  ]);
  return { usedSeconds, globalUsedSeconds };
}

/// Give a request's seconds back, because it bought nothing.
///
/// The counter is incremented before it is judged (see `record`'s caller), so
/// a REFUSED request has already added its seconds to both rows — and without
/// this, refusals themselves became the weapon: a spent free token retrying in
/// a loop added up to 40 metered seconds per attempt to the GLOBAL row, enough
/// to walk the whole service to its daily ceiling in minutes and 429 every
/// paying customer with requests that were never going to be transcribed.
/// Same shape when the upstream provider 5xxs: the audio was billed and never
/// bought, and a trial is lifetime — an outage must not eat it.
///
/// Best-effort by design: the caller swallows a refund that fails, because the
/// fallback is only the old over-counting behaviour. `ADD` of a negative is
/// atomic like any other, so concurrent refunds cannot corrupt the row.
export async function refund({ subject, seconds, tier, now = Date.now() }) {
  await Promise.all([
    addSeconds(usageKey(subject, now, tier), -seconds, null),
    addSeconds(globalKey(now), -seconds, null),
  ]);
}

/// Count one summary against the day, and report the day's new total.
///
/// Its OWN row (`summaryKey`), not the audio ceiling's. Charging summaries to
/// a user's own counter would spend a transcription allowance on a text call
/// and make the trial run out faster than the thing the trial is for; charging
/// them to the AUDIO ceiling — which is what this did — let a flood of cheap
/// text calls close the expensive route for everybody, paying customers
/// included. A budget each, so neither can shut the other.
///
/// The stored attribute is still `audioSeconds` because it is the counter
/// `addSeconds` maintains; here it counts REQUESTS. The row key says which.
export async function recordSummary({ now = Date.now() } = {}) {
  const summariesToday = await addSeconds(summaryKey(now), 1, DAILY_TTL_SECONDS);
  return { summariesToday };
}

/// A refused summary gives its count back, or refusals would keep climbing the
/// very ceiling that is refusing them.
export async function refundSummary({ now = Date.now() } = {}) {
  await addSeconds(summaryKey(now), -1, null);
}

/// Is this licence real, and what does it entitle its holder to?
///
/// Cached in the same table as the counters, because it is the same kind of
/// fact — something the service learned that must outlive one container.
export async function tierFor(subject, now = Date.now()) {
  if (subject.kind !== "license") return "free";

  const key = licenseKey(subject);
  const cached = await db().send(new GetItemCommand({
    TableName: TABLE,
    Key: { subject: { S: key } },
  }));

  const checkedAt = Number(cached.Item?.checkedAt?.N ?? 0);
  const cachedTier = cached.Item?.tier?.S;
  if (checkedAt && now - checkedAt < LICENSE_CACHE_MS) {
    return cachedTier ?? "free";
  }

  const tier = await validateWithPolar(subject.id);

  // A VERDICT AND AN ERROR ARE DIFFERENT FACTS, and only the verdict may be
  // cached for a day. Caching an error-derived "free" was the bug: one Polar
  // timeout on one cold container wrote `tier: "free"`, and a PAYING
  // customer spent the next 24 hours metering against the lifetime `#trial`
  // row — 402'd for a day by a network blip, and again for a day on every
  // future blip once those thirty minutes were gone. On an error the last
  // real verdict stands, re-checked after five minutes rather than a day —
  // stale-Pro during an outage is the accepted cancellation lag, not a leak.
  //
  // A key with NO history still meters as free during an outage (an error
  // must never promote), and that too is written with the short window, so
  // the recheck happens when Polar is back rather than tomorrow.
  const verdict = tier ?? cachedTier ?? "free";
  const freshAsOf = tier !== null
    ? now
    : now - LICENSE_CACHE_MS + ERROR_RETRY_MS;

  // Written even when the answer is "not valid", so a garbage key cannot be
  // used to generate a Polar call per chunk.
  //
  // It expires, though — at four cache lifetimes, long after it stops being
  // consulted. Without a TTL every distinct string anybody ever typed into the
  // licence field left a permanent row, which is a slow storage leak with an
  // obvious way to accelerate it.
  await db().send(new PutItemCommand({
    TableName: TABLE,
    Item: {
      subject: { S: key },
      tier: { S: verdict },
      checkedAt: { N: String(freshAsOf) },
      expiresAt: {
        N: String(Math.floor((now + LICENSE_CACHE_MS * 4) / 1000)),
      },
    },
  }));

  return verdict;
}

/// Ask Polar whether a key is live: "pro", "free", or null.
///
/// NULL MEANS "COULD NOT ASK", AND IT IS A THIRD ANSWER, not a synonym for
/// "free". A timeout, a 5xx, or Polar rate-limiting us says nothing about the
/// licence; only an answer Polar actually gave does. The caller decides what
/// null costs — the last real verdict stands.
///
/// A NETWORK FAILURE STILL MUST NOT PROMOTE ANYBODY: null never becomes "pro"
/// unless a cached "pro" verdict — a real answer from a real validation —
/// already existed. The other direction would make an outage into a way to
/// get Pro for nothing.
async function validateWithPolar(key) {
  try {
    const response = await fetch(POLAR_VALIDATE, {
      method: "POST",
      headers: { accept: "application/json", "content-type": "application/json" },
      body: JSON.stringify({ key, organization_id: POLAR_ORGANIZATION_ID }),
      signal: AbortSignal.timeout(5000),
    });

    // 4xx is an answer — Polar 404s a key it has never issued, which is
    // "that is not a key" and not an outage. 5xx and 429 are its absence.
    if (!response.ok) {
      return response.status >= 500 || response.status === 429 ? null : "free";
    }
    const json = await response.json();

    // Polar has exactly three statuses. `granted` is live; `revoked` is what a
    // cancelled subscription becomes, and `disabled` is one we turned off by
    // hand. Only the first has paid.
    if (json?.status !== "granted") return "free";

    // Both SKUs — monthly and annual — grant the SAME licence-key benefit, and
    // the validate response names the benefit rather than the product, so
    // there is nothing here to tell $3.99/mo from $29.99/yr and nothing that needs
    // to. Until the store exists there are no ids to match, and the only paid
    // benefit is Pro's — so any live licence is Pro. A SECOND PAID TIER WOULD
    // COME WITH ITS OWN BENEFIT, and this is the line that learns to tell them
    // apart; leaving it unset then would sell Pro's allowance at the cheaper
    // tier's price.
    const proBenefits = (process.env.DEIKO_PRO_BENEFIT_IDS ?? "")
      .split(",").filter(Boolean);
    if (proBenefits.length === 0) return "pro";
    return proBenefits.includes(String(json?.benefit_id)) ? "pro" : "free";
  } catch {
    return null;
  }
}
