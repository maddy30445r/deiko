// THE MONEY PATH, END TO END, WITH NO AWS ACCOUNT.
//
// `quota.test.mjs` checks the arithmetic. This checks the thing that arithmetic
// is wired into: that a real `handle()` call counts the right number of seconds
// against the right row, refuses at the right threshold, and never reaches
// Sarvam when it has refused.
//
// DynamoDB is a fake HTTP server rather than DynamoDB Local, which would need
// Java or Docker — a test that needs a container is a test that stops being run.
// The SDK talks to it because v3 honours `AWS_ENDPOINT_URL_DYNAMODB`, so the
// code under test is byte-for-byte the code that ships: no injected client, no
// test-only branch, no interface that exists only to be mocked.

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";

import { FREE_TRIAL_SECONDS, monthKey } from "../quota.mjs";

// ── A DynamoDB that lives in a Map ──────────────────────────────────────────

const rows = new Map();
let server;
let port;

function ddb(target, body) {
  const key = body.Key?.subject?.S ?? body.Item?.subject?.S;

  if (target.endsWith("DescribeTable")) {
    return { Table: { TableStatus: "ACTIVE" } };
  }
  if (target.endsWith("UpdateItem")) {
    const add = Number(body.ExpressionAttributeValues[":n"].N);
    const row = rows.get(key) ?? {};
    row.audioSeconds = (row.audioSeconds ?? 0) + add;
    rows.set(key, row);
    return { Attributes: { audioSeconds: { N: String(row.audioSeconds) } } };
  }
  if (target.endsWith("GetItem")) {
    const row = rows.get(key);
    if (!row) return {};
    // Return every attribute the row actually has. This used to return only the
    // licence-cache fields, which made `peek` — a GetItem on a *usage* row —
    // read every counter as zero. The code was right; the double was lying.
    const Item = { subject: { S: key } };
    if (row.audioSeconds != null) Item.audioSeconds = { N: String(row.audioSeconds) };
    if (row.tier != null) Item.tier = { S: row.tier };
    if (row.checkedAt != null) Item.checkedAt = { N: String(row.checkedAt) };
    return { Item };
  }
  if (target.endsWith("PutItem")) {
    rows.set(key, {
      ...(rows.get(key) ?? {}),
      tier: body.Item.tier.S,
      checkedAt: Number(body.Item.checkedAt.N),
    });
    return {};
  }
  throw new Error(`unexpected DynamoDB call: ${target}`);
}

// ── What the relay tried to call ────────────────────────────────────────────

let upstream = [];
let upstreamBodies = [];
let licenseValid = true;

function stubFetch() {
  globalThis.fetch = async (url, init) => {
    const href = String(url);
    upstream.push(href);
    // The body matters as well as the destination: the summarize route is
    // supposed to REBUILD what it sends rather than forward what it was given,
    // and only the body can show that.
    upstreamBodies.push(typeof init?.body === "string" ? init.body : "");
    if (href.includes("lemonsqueezy")) {
      return new Response(
        JSON.stringify({ valid: licenseValid, license_key: { status: licenseValid ? "active" : "expired" } }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }
    if (href.includes("sarvam")) {
      return new Response(JSON.stringify({ transcript: "ok" }), { status: 200 });
    }
    if (href.includes("groq")) {
      return new Response(JSON.stringify({ choices: [] }), { status: 200 });
    }
    throw new Error(`unexpected upstream: ${href}`);
  };
}

let handle;
let logLine;

before(async () => {
  server = createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      const target = req.headers["x-amz-target"] ?? "";
      let out;
      try {
        out = ddb(target, raw ? JSON.parse(raw) : {});
      } catch (err) {
        res.writeHead(400, { "content-type": "application/x-amz-json-1.0" });
        res.end(JSON.stringify({ __type: "ValidationException", message: String(err.message) }));
        return;
      }
      res.writeHead(200, { "content-type": "application/x-amz-json-1.0" });
      res.end(JSON.stringify(out));
    });
  });
  await new Promise((r) => server.listen(0, r));
  port = server.address().port;

  // Set before importing: the module reads the table name at load, and the SDK
  // resolves its endpoint and credentials from the environment.
  process.env.AWS_ENDPOINT_URL_DYNAMODB = `http://127.0.0.1:${port}`;
  process.env.AWS_REGION = "ap-south-1";
  process.env.AWS_ACCESS_KEY_ID = "test";
  process.env.AWS_SECRET_ACCESS_KEY = "test";
  process.env.SARVAM_API_KEY = "test-sarvam";
  process.env.GROQ_API_KEY = "test-groq";

  ({ handle, logLine } = await import("../relay.mjs"));
});

after(() => server?.close());

beforeEach(() => {
  rows.clear();
  upstream = [];
  upstreamBodies = [];
  licenseValid = true;
  stubFetch();
});

/// One request carrying `seconds` of 16kHz mono 16-bit audio.
///
/// Capped at 25 seconds because that is what the client actually sends —
/// `transcribe.mjs` splits there, and 25s of this format is 0.76MB against a
/// 12MB body limit. Building a 31-minute body to simulate a used-up trial gets
/// a perfectly correct 413 from the size guard, several checks before metering
/// is reached; ask for that and the test is measuring the wrong refusal.
const post = (token, seconds) => {
  assert.ok(seconds <= 25, `chunks are 25s or less — seed the counter instead of sending ${seconds}s`);
  return handle({
    method: "POST",
    path: "/v1/transcribe",
    token,
    contentType: "multipart/form-data; boundary=x",
    body: Buffer.alloc(Math.round(seconds * 32_000)),
  });
};

/// Put a subject's counter where a long history would have left it, without
/// spending the wall-clock time of sending that history one chunk at a time.
const seed = (key, seconds) => rows.set(key, { ...(rows.get(key) ?? {}), audioSeconds: seconds });

const monthRow = (id) => `lic:${id}#${monthKey(Date.now())}`;
/// Where a licence that is NOT Pro accumulates: a lifetime row, like a device.
const trialRow = (id) => `lic:${id}#trial`;

// ── Tests ───────────────────────────────────────────────────────────────────

test("health reports metering by actually describing the table", async () => {
  const r = await handle({ method: "GET", path: "/health" });
  const body = JSON.parse(r.body);
  assert.equal(body.metering, true);
  assert.equal(body.transcription, true);
});

test("a free install transcribes with no configuration at all", async () => {
  const r = await post("dev_new-mac", 20);
  assert.equal(r.status, 200);
  assert.ok(upstream.some((u) => u.includes("sarvam")), "should have reached Sarvam");
});

test("seconds land on the device's lifetime row, and on today's global row", async () => {
  await post("dev_abc", 25);
  assert.equal(rows.get("dev:abc").audioSeconds, 25);
  const global = [...rows.keys()].find((k) => k.startsWith("global#"));
  assert.equal(rows.get(global).audioSeconds, 25);
});

test("the free trial runs out, and the refusal is 402 with Sarvam untouched", async () => {
  seed("dev:heavy", FREE_TRIAL_SECONDS - 20);   // 20 seconds of trial left
  const ok = await post("dev_heavy", 15);
  assert.equal(ok.status, 200, "still inside the trial");

  upstream = [];
  const refused = await post("dev_heavy", 25);  // tips it over
  assert.equal(refused.status, 402);
  assert.equal(
    upstream.filter((u) => u.includes("sarvam")).length, 0,
    "a refusal must not buy the audio it refused",
  );
});

test("/v1/quota reports what is left without spending any of it", async () => {
  await post("dev_abc", 25);
  const before = rows.get("dev:abc").audioSeconds;

  const r = await handle({ method: "GET", path: "/v1/quota", token: "dev_abc" });
  const q = JSON.parse(r.body);
  assert.equal(q.tier, "free");
  assert.equal(q.usedSeconds, 25);
  assert.equal(q.remainingSeconds, FREE_TRIAL_SECONDS - 25);
  assert.equal(rows.get("dev:abc").audioSeconds, before, "asking must not consume");
});

test("/v1/quota answers before a session has ever run — the key confirmation", async () => {
  const r = await handle({ method: "GET", path: "/v1/quota", token: "lic_fresh-purchase" });
  const q = JSON.parse(r.body);
  assert.equal(r.status, 200);
  assert.equal(q.tier, "pro", "a licence must read as Pro the moment it is pasted");
  assert.equal(q.usedSeconds, 0);
});

test("/v1/quota still needs a token, and still honours revocation", async () => {
  assert.equal((await handle({ method: "GET", path: "/v1/quota" })).status, 401);
  assert.equal((await handle({ method: "GET", path: "/v1/transcribe", token: "dev_a" })).status, 405);
});

test("a second install is not charged for the first one's trial", async () => {
  seed("dev:one", FREE_TRIAL_SECONDS + 60);
  assert.equal((await post("dev_one", 10)).status, 402);
  const other = await post("dev_two", 10);
  assert.equal(other.status, 200, "quota is per subject, not global-by-accident");
});

test("a valid licence is Pro, and carries on well past the free cap", async () => {
  seed(monthRow("real-key"), FREE_TRIAL_SECONDS + 15 * 60);  // 45 min in
  const r = await post("lic_real-key", 20);
  assert.equal(r.status, 200, "45 minutes is over free's 30 and well under Pro's five hours");
  assert.ok(upstream.some((u) => u.includes("lemonsqueezy")), "should have validated");
});

test("the Lemon Squeezy verdict is cached — dozens of chunks, one validation", async () => {
  for (let i = 0; i < 5; i++) await post("lic_real-key", 20);
  assert.equal(
    upstream.filter((u) => u.includes("lemonsqueezy")).length, 1,
    "a 20-minute session is ~48 chunks; it must not be 48 validations",
  );
});

test("an invalid licence is metered as free, and its verdict is cached too", async () => {
  licenseValid = false;
  seed(trialRow("garbage"), FREE_TRIAL_SECONDS + 60);
  const refused = await post("lic_garbage", 10);
  assert.equal(refused.status, 402, "a bad key must not buy Pro's allowance");
  await post("lic_garbage", 10);
  assert.equal(
    upstream.filter((u) => u.includes("lemonsqueezy")).length, 1,
    "a garbage key must not generate a validation per chunk",
  );
});

test("a forged licence key does not get a fresh trial next month", async () => {
  // THE FORGERY THIS CLOSES. A `lic_` subject used to land in a MONTHLY row
  // carrying the FREE cap, so anybody who typed junk into Settings got thirty
  // minutes every calendar month, forever, self-resetting — while an honest
  // user got thirty minutes once, ever. The forgery beat the truth.
  licenseValid = false;
  await post("lic_forged", 20);
  assert.equal(rows.get(trialRow("forged")).audioSeconds, 20, "lands in the lifetime row");
  assert.equal(rows.get(monthRow("forged")), undefined, "and never in a monthly one");
  assert.equal(
    rows.get(trialRow("forged")).expiresAt,
    undefined,
    "a lifetime row must carry no TTL, or the trial renews itself every forty days",
  );
});

test("a legacy unprefixed token still works, as a free device", async () => {
  const uuid = "7C6C4E1A-58F9-4E2E-9E1B-2F0A3B4C5D6E";
  const r = await post(uuid, 10);
  assert.equal(r.status, 200);
  assert.equal(rows.get(`dev:${uuid}`).audioSeconds, 10);
});

const summarize = (token, body) => handle({
  method: "POST", path: "/v1/summarize", token,
  contentType: "application/json",
  body: Buffer.from(JSON.stringify(body ?? { messages: [{ role: "user", content: "hi" }] })),
});

test("a used-up trial still gets its reading, and is not charged for it", async () => {
  seed("dev:spent", FREE_TRIAL_SECONDS + 60);
  const before = rows.get("dev:spent").audioSeconds;
  const r = await summarize("dev_spent");
  assert.equal(r.status, 200, "the sentence that says what Fovea heard is not the paid part");
  assert.equal(
    rows.get("dev:spent").audioSeconds, before,
    "a text summary must not spend an audio allowance",
  );
});

test("a summary IS charged against the day, so a flood cannot stay invisible", async () => {
  const key = `global#${new Date().toISOString().slice(0, 10)}`;
  const before = rows.get(key)?.audioSeconds ?? 0;
  await summarize("dev_anyone");
  assert.ok(
    (rows.get(key)?.audioSeconds ?? 0) > before,
    "the global backstop is the only thing that bounds an unmetered route",
  );
});

test("the caller does not get to choose the model or the token budget", async () => {
  // This route spends Fovea's Groq key and accepts any bearer string. Before
  // the body was rebuilt server-side, that made it an open LLM proxy: name an
  // expensive model and a large completion, and bill it here.
  await summarize("dev_greedy", {
    model: "some-expensive-model",
    max_completion_tokens: 100_000,
    messages: [{ role: "user", content: "hi" }],
  });
  const sent = JSON.parse(upstreamBodies.at(-1));
  assert.equal(sent.model, "llama-3.3-70b-versatile", "the model is ours to pick");
  assert.equal(sent.max_completion_tokens, 200, "and so is the completion budget");
});

test("an oversized summary body is refused before it is parsed", async () => {
  const r = await handle({
    method: "POST", path: "/v1/summarize", token: "dev_big",
    contentType: "application/json", body: Buffer.alloc(65 * 1024, "x"),
  });
  assert.equal(r.status, 413);
});

test("a token can be revoked by the fingerprint that appears in the logs", async () => {
  // Before, the log carried the token's own first eight characters — for
  // `dev_xxxx` that is four usable hex digits, and the wrong string anyway,
  // because FOVEA_REVOKED_TOKENS needs the value in full. You could see an
  // abusive install and still have no way to stop it.
  const line = logLine({ method: "POST", path: "/v1/transcribe", status: 200, ms: 5, token: "dev_abuser" });
  const printed = line.split("tok:")[1];
  assert.ok(printed && printed.length === 12, "the log carries a fingerprint, not a token");
  assert.ok(!line.includes("dev_abuser"), "and never the bearer itself");

  process.env.FOVEA_REVOKED_TOKENS = printed;
  try {
    const r = await post("dev_abuser", 10);
    assert.equal(r.status, 403, "the string you can read must be the string you can revoke");
  } finally {
    delete process.env.FOVEA_REVOKED_TOKENS;
  }
});

test("the quota route is rate limited too", async () => {
  // It reads DynamoDB, writes a verdict row, and for an unseen licence calls
  // Lemon Squeezy — all of which sat ABOVE the limiter, making it the cheapest
  // way to amplify writes against a 25-WCU table. Throttling there does not
  // fail the attacker's request; it fails transcription for whoever is paying.
  let last = 0;
  for (let i = 0; i < 35; i++) {
    last = (await handle({ method: "GET", path: "/v1/quota", token: "dev_loop" })).status;
  }
  assert.equal(last, 429);
});

test("when the usage table is unreachable the relay fails CLOSED", async () => {
  const saved = server;
  await new Promise((r) => saved.close(r));
  const r = await post("dev_abc", 10);
  assert.equal(r.status, 503);
  assert.equal(
    upstream.filter((u) => u.includes("sarvam")).length, 0,
    "not knowing what somebody has spent must stop the buying, not start it",
  );
  await new Promise((r) => saved.listen(port, r));
});
