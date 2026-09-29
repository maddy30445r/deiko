// Usage counters and licence verdicts, kept in one DynamoDB table
// (`deiko-usage`, partition key `subject`). Row shapes:
//
//   dev:<token>#YYYY-MM      a device's free audio seconds this month. 40-day TTL.
//   lic:<key>#YYYY-MM        a licence's audio seconds this month. 40-day TTL.
//   lic:<key>                the cached Polar verdict. Expires at four cache
//                            lifetimes; refreshed when older than a day.
//   global#YYYY-MM-DD        every subject's audio today. 7-day TTL.
//
// Counters are incremented, not read-then-written: `UpdateItem` with `ADD`
// returns the new total in one round trip and is atomic across concurrent
// Lambda containers.

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
  isPolarKey,
  licenseKey,
  playgroundClipKey,
  playgroundIntentKey,
  playgroundIpKey,
  playgroundTicketKey,
  playgroundTicketQueryKey,
  usageKey,
} from "./quota.mjs";

const TABLE = process.env.DEIKO_USAGE_TABLE ?? "deiko-usage";
/// Polar's public validate endpoint, which its docs say is safe to call from a
/// desktop app, so the relay stores no Polar credential. `POLAR_API_BASE` points
/// it at `https://sandbox-api.polar.sh` for test purchases.
const POLAR_API = process.env.POLAR_API_BASE ?? "https://api.polar.sh";
const POLAR_VALIDATE = `${POLAR_API}/v1/customer-portal/license-keys/validate`;

/// Not a secret: it is in every checkout URL and the validate endpoint is
/// unauthenticated. A constant rather than an environment variable because a
/// missing one would fail every validation and demote paying customers.
const POLAR_ORGANIZATION_ID =
  process.env.POLAR_ORGANIZATION_ID ?? "a5147c76-3225-423b-ab8c-bdee6d06353a";

/// How long a Polar verdict is trusted before it is checked again. A long
/// session is dozens of relay calls (audio is split at 25 seconds), so
/// validating each would add latency and hit Polar's rate limit. A cancellation
/// therefore takes up to a day to bite.
const LICENSE_CACHE_MS = 24 * 60 * 60 * 1000;

/// How soon an error-derived verdict is rechecked. An error says nothing about
/// the licence, only about the network, so it is retried within minutes.
const ERROR_RETRY_MS = 5 * 60 * 1000;

/// What a caller is told when the usage table cannot be reached. Fixed text: the
/// real DynamoDB error carries the table name and an ARN, so it goes to
/// CloudWatch instead of the response body.
export function unavailable(err) {
  console.error(`usage table unreachable: ${String(err?.message ?? err)}`);
  return "usage service unavailable";
}

/// Created once per container so a warm Lambda reuses the connection.
let client;
function db() {
  client ??= new DynamoDBClient({});
  return client;
}

/// Can this relay meter right now?
///
/// Makes a real DescribeTable call rather than checking a configured name, so a
/// missing table or a role without a policy is caught. Cached for a minute per
/// container, as a promise so concurrent checks share one call: `/health` takes
/// no bearer and must not let anybody spend the account's DescribeTable rate.
const HEALTH_CACHE_MS = 60_000;
let health = null;
export function meteringHealthy(now = Date.now()) {
  if (!health || now - health.at >= HEALTH_CACHE_MS) {
    health = {
      at: now,
      ok: db().send(new DescribeTableCommand({ TableName: TABLE }))
        .then((out) => out.Table?.TableStatus === "ACTIVE", () => false),
    };
  }
  return health.ok;
}

/// Add `seconds` to a subject's counter and return the new total.
///
/// `ttl` is set only on rows that should expire. DynamoDB ignores the attribute
/// unless TTL is enabled on the table for this exact name; rows then never
/// expire, which costs storage, not correctness.
async function addSeconds(key, seconds, ttlSeconds) {
  // `createdAt` is set once, by the write that creates the row (ISO, for
  // people reading the console).
  const expression = ttlSeconds
    ? "ADD audioSeconds :n SET createdAt = if_not_exists(createdAt, :now), expiresAt = if_not_exists(expiresAt, :ttl)"
    : "ADD audioSeconds :n SET createdAt = if_not_exists(createdAt, :now)";

  const values = {
    ":n": { N: String(seconds) },
    ":now": { S: new Date().toISOString() },
  };
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

/// What a subject has spent, without spending any more. Serves `/v1/quota`,
/// which the app calls right after a licence key is pasted, before any session
/// has run.
export async function peek(subject, tier, now = Date.now()) {
  const out = await db().send(new GetItemCommand({
    TableName: TABLE,
    Key: { subject: { S: usageKey(subject, now, tier) } },
  }));
  return Number(out.Item?.audioSeconds?.N ?? 0);
}

/// Count this request against the subject and against the day, and report both
/// new totals. The two writes run together to save a round trip.
///
/// The TTL follows the key, not the token's shape: a monthly row expires so the
/// next month starts clean. The `#trial` row of an unrecognised licence has a
/// zero allowance and never expires.
///
/// Both rows or neither: `Promise.all` rejects on the first failure while the
/// other write may already have landed, banking seconds against the service's
/// day with no refund path. `allSettled` lets the half that landed be taken back
/// before the failure is re-thrown. Compensation is best-effort; if it fails the
/// counter is over by one chunk, the safe direction.
export async function record({ subject, seconds, tier, now = Date.now() }) {
  const key = usageKey(subject, now, tier);
  const global = globalKey(now);
  const [subjectWrite, globalWrite] = await Promise.allSettled([
    addSeconds(key, seconds, /#\d{4}-\d{2}$/.test(key) ? MONTHLY_TTL_SECONDS : null),
    addSeconds(global, seconds, DAILY_TTL_SECONDS),
  ]);

  if (subjectWrite.status === "rejected" || globalWrite.status === "rejected") {
    if (subjectWrite.status === "fulfilled") {
      await addSeconds(key, -seconds, null).catch(() => {});
    }
    if (globalWrite.status === "fulfilled") {
      await addSeconds(global, -seconds, null).catch(() => {});
    }
    throw subjectWrite.reason ?? globalWrite.reason;
  }

  return { usedSeconds: subjectWrite.value, globalUsedSeconds: globalWrite.value };
}

/// Give a request's seconds back because it bought nothing (it was refused, or
/// the upstream provider failed).
///
/// The counter is incremented before the request is judged, so without this a
/// refused request would still count against both rows and repeated refusals
/// could walk the global row to its daily ceiling. Best-effort: the caller
/// swallows a failed refund, and the fallback is over-counting. `ADD` of a
/// negative is atomic like any other.
///
/// `now` is the original record's and has no default: a refund using its own
/// clock lands on the wrong row when the upstream answers after midnight.
export async function refund({ subject, seconds, tier, now }) {
  await Promise.all([
    addSeconds(usageKey(subject, now, tier), -seconds, null),
    addSeconds(globalKey(now), -seconds, null),
  ]);
}

/// Count one call against each of `keys` (daily, TTL'd rows) and return the new
/// totals in the same order. The text routes use a global day, the caller's day
/// and the caller's address's day.
///
/// All rows or none, for the reason given at `record`.
///
/// The stored attribute is still `audioSeconds`, the counter `addSeconds`
/// maintains; here it counts requests. The row key says which.
export async function countCalls(keys) {
  const writes = await Promise.allSettled(keys.map((k) => addSeconds(k, 1, DAILY_TTL_SECONDS)));
  const failed = writes.find((w) => w.status === "rejected");
  if (failed) {
    await uncountCalls(keys.filter((_, i) => writes[i].status === "fulfilled")).catch(() => {});
    throw failed.reason;
  }
  return writes.map((w) => w.value);
}

/// Give those calls back. The keys carry their own day, so a refund after
/// midnight still lands on the row it was charged to.
export async function uncountCalls(keys) {
  await Promise.all(keys.map((k) => addSeconds(k, -1, null)));
}

/// Playground counters, all TTL'd like the daily global: the day's clips, the
/// day's intent calls, and one row per issued ticket. None is the row the app
/// spends, so a flood on the public page exhausts only the public page.
export async function recordPlaygroundClip(ticketId, { now = Date.now() } = {}) {
  const [clipsToday, ticketClips] = await Promise.all([
    addSeconds(playgroundClipKey(now), 1, DAILY_TTL_SECONDS),
    addSeconds(playgroundTicketKey(ticketId), 1, DAILY_TTL_SECONDS),
  ]);
  return { clipsToday, ticketClips };
}

export async function refundPlaygroundClip(ticketId, { now }) {
  await Promise.all([
    addSeconds(playgroundClipKey(now), -1, null),
    addSeconds(playgroundTicketKey(ticketId), -1, null),
  ]);
}

export async function recordPlaygroundIntent(ticketId, { now = Date.now() } = {}) {
  const [intentsToday, ticketQueries] = await Promise.all([
    addSeconds(playgroundIntentKey(now), 1, DAILY_TTL_SECONDS),
    addSeconds(playgroundTicketQueryKey(ticketId), 1, DAILY_TTL_SECONDS),
  ]);
  return { intentsToday, ticketQueries };
}

export async function refundPlaygroundIntent(ticketId, { now }) {
  await Promise.all([
    addSeconds(playgroundIntentKey(now), -1, null),
    addSeconds(playgroundTicketQueryKey(ticketId), -1, null),
  ]);
}

/// Count a ticket against the caller who asked for it. Returns how many they
/// have taken today, so the route can refuse the next one.
export async function recordPlaygroundTicket(ipHash, { now = Date.now() } = {}) {
  const ticketsToday = await addSeconds(playgroundIpKey(ipHash, now), 1, DAILY_TTL_SECONDS);
  return { ticketsToday };
}

/// Is this licence real, and what does it entitle its holder to? Cached in the
/// same table as the counters so the verdict outlives one container.
export async function tierFor(subject, now = Date.now()) {
  if (subject.kind !== "license") return "free";
  // Anything `isPolarKey` refuses is junk and gets "free" without a Polar call
  // or a verdict write. relay.mjs logs each one, so a real key of another shape
  // shows up in CloudWatch.
  if (!isPolarKey(subject.id)) return "free";

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

  // A verdict and an error are different facts, and only the verdict may be
  // cached for a day: an error-derived "free" would meter a paying customer
  // against the free allowance for 24 hours. On an error the last real
  // verdict stands and is rechecked after five minutes (stale-Pro during an
  // outage is the accepted cancellation lag). A key with no history meters as
  // free during an outage, since an error must never promote, and is also
  // rechecked on the short window.
  const verdict = tier ?? cachedTier ?? "free";
  const freshAsOf = tier !== null
    ? now
    : now - LICENSE_CACHE_MS + ERROR_RETRY_MS;

  // Written even when the answer is "not valid", so a garbage key cannot
  // trigger a Polar call per chunk. It expires at four cache lifetimes so junk
  // keys do not accumulate.
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
/// Null means "could not ask" (timeout, 5xx, rate limit) and is distinct from
/// "free": it says nothing about the licence, so the caller keeps the last real
/// verdict. Null never promotes anybody to Pro on its own.
async function validateWithPolar(key) {
  try {
    const response = await fetch(POLAR_VALIDATE, {
      method: "POST",
      headers: { accept: "application/json", "content-type": "application/json" },
      body: JSON.stringify({ key, organization_id: POLAR_ORGANIZATION_ID }),
      signal: AbortSignal.timeout(5000),
    });

    // 4xx is an answer (Polar 404s a key it never issued); 5xx and 429 are its
    // absence.
    if (!response.ok) {
      return response.status >= 500 || response.status === 429 ? null : "free";
    }
    const json = await response.json();

    // Polar has three statuses: `granted` is live, `revoked` is a cancelled
    // subscription and `disabled` was turned off by hand. Only `granted` has paid.
    if (json?.status !== "granted") return "free";

    // Monthly and annual licences grant the same benefit, and the response names
    // the benefit, not the product. With no DEIKO_PRO_BENEFIT_IDS set, any live
    // licence is Pro; a second paid tier would need its own benefit id here, or
    // it would receive Pro's allowance.
    const proBenefits = (process.env.DEIKO_PRO_BENEFIT_IDS ?? "")
      .split(",").filter(Boolean);
    if (proBenefits.length === 0) return "pro";
    return proBenefits.includes(String(json?.benefit_id)) ? "pro" : "free";
  } catch {
    return null;
  }
}
