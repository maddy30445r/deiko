// ─────────────────────────────────────────────────────────────────────────────
// THE NUMBERS, AND WHERE THEY LIVE
//
// One DynamoDB table, `deiko-usage`, on-demand billing, partition key `subject`.
// Everything stateful the relay needs is a row in it:
//
//   dev:<token>              lifetime free-trial seconds. No TTL — the trial is
//                            once, and a row that expired would silently renew it.
//   lic:<key>#2026-08        a licence's audio seconds this month. 40-day TTL.
//   lic:<key>                the cached Lemon Squeezy verdict. No TTL; refreshed
//                            when it is older than a day.
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
  usageKey,
} from "./quota.mjs";

const TABLE = process.env.DEIKO_USAGE_TABLE ?? "deiko-usage";
const LEMONSQUEEZY_VALIDATE = "https://api.lemonsqueezy.com/v1/licenses/validate";

/// How long a Lemon Squeezy verdict is trusted before it is checked again.
///
/// `transcribe.mjs` splits audio at 25 seconds, so one long session is dozens of
/// relay calls; validating each against Lemon Squeezy would add a second of
/// latency per chunk and hammer somebody else's rate limit for an answer that
/// changes at most once a month. A cancellation therefore takes up to a day to
/// bite, which is the right trade for a $4 product.
const LICENSE_CACHE_MS = 24 * 60 * 60 * 1000;

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

/// Count something against the DAY only, and report the day's new total.
///
/// For work that costs the service money but is not the user's audio — the
/// orb's three-line summary. Charging it to their own counter would spend a
/// transcription allowance on a text call and make the trial run out faster
/// than the thing the trial is for; leaving it uncounted entirely is how an
/// unmetered route becomes an unbounded bill. The day's backstop is the right
/// place: it bounds the service without touching what anybody was promised.
export async function recordGlobal({ seconds, now = Date.now() }) {
  const globalUsedSeconds = await addSeconds(globalKey(now), seconds, DAILY_TTL_SECONDS);
  return { globalUsedSeconds };
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
  if (checkedAt && now - checkedAt < LICENSE_CACHE_MS) {
    return cached.Item?.tier?.S ?? "free";
  }

  const tier = await validateWithLemonSqueezy(subject.id);

  // Written even when the answer is "not valid", so a garbage key cannot be
  // used to generate a Lemon Squeezy call per chunk.
  //
  // It expires, though — at four cache lifetimes, long after it stops being
  // consulted. Without a TTL every distinct string anybody ever typed into the
  // licence field left a permanent row, which is a slow storage leak with an
  // obvious way to accelerate it.
  await db().send(new PutItemCommand({
    TableName: TABLE,
    Item: {
      subject: { S: key },
      tier: { S: tier },
      checkedAt: { N: String(now) },
      expiresAt: {
        N: String(Math.floor((now + LICENSE_CACHE_MS * 4) / 1000)),
      },
    },
  }));

  return tier;
}

/// Ask Lemon Squeezy whether a key is live.
///
/// A NETWORK FAILURE MUST NOT PROMOTE ANYBODY. Returning "free" on an error
/// means a paying customer briefly drops to on-device transcription if Lemon
/// Squeezy is down, which is recoverable and honest; the other direction would
/// make an outage into a way to get Pro for nothing.
///
/// The validate endpoint is unauthenticated, but an API key is sent when one is
/// configured — the docs have moved on this before, and two lines here is
/// cheaper than a deploy that 401s.
async function validateWithLemonSqueezy(key) {
  try {
    const headers = { accept: "application/json" };
    if (process.env.LEMONSQUEEZY_API_KEY) {
      headers.authorization = `Bearer ${process.env.LEMONSQUEEZY_API_KEY}`;
    }

    const body = new URLSearchParams({ license_key: key });
    const response = await fetch(LEMONSQUEEZY_VALIDATE, {
      method: "POST",
      headers,
      body,
      signal: AbortSignal.timeout(5000),
    });

    if (!response.ok) return "free";
    const json = await response.json();
    if (!json?.valid) return "free";

    const status = json?.license_key?.status;
    if (status !== "active") return "free";

    // Until the store exists there are no variant ids to match, and the only
    // paid SKU is Pro — so any live licence is Pro. When a second paid tier
    // appears, this is the line that learns to tell them apart.
    const proVariants = (process.env.DEIKO_PRO_VARIANT_IDS ?? "")
      .split(",").filter(Boolean);
    if (proVariants.length === 0) return "pro";
    return proVariants.includes(String(json?.meta?.variant_id)) ? "pro" : "free";
  } catch {
    return "free";
  }
}
