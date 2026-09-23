// THE MONEY PATH, END TO END, WITH NO AWS ACCOUNT.
//
// `quota.test.mjs` checks the arithmetic. This checks the thing that arithmetic
// is wired into: that a real `handle()` call counts the right number of seconds
// against the right row, refuses at the right threshold, and never reaches
// the upstream when it has refused.
//
// DynamoDB is a fake HTTP server rather than DynamoDB Local, which would need
// Java or Docker — a test that needs a container is a test that stops being run.
// The SDK talks to it because v3 honours `AWS_ENDPOINT_URL_DYNAMODB`, so the
// code under test is byte-for-byte the code that ships: no injected client, no
// test-only branch, no interface that exists only to be mocked.

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";

import { FREE_TRIAL_SECONDS, MIN_SECONDS_PER_REQUEST, globalKey, monthKey } from "../quota.mjs";

// ── A DynamoDB that lives in a Map ──────────────────────────────────────────

const rows = new Map();
/// Keys whose UpdateItem the fake refuses with a ValidationException — the
/// exact response an over-long partition key draws from the real service, and
/// the way to make one half of a two-row write fail while the other lands.
const failWritesTo = new Set();
let server;
let port;

function ddb(target, body) {
  const key = body.Key?.subject?.S ?? body.Item?.subject?.S;

  if (target.endsWith("DescribeTable")) {
    return { Table: { TableStatus: "ACTIVE" } };
  }
  if (target.endsWith("UpdateItem")) {
    if (failWritesTo.has(key)) throw new Error(`refused write to ${key}`);
    const add = Number(body.ExpressionAttributeValues[":n"].N);
    const row = rows.get(key) ?? {};
    row.audioSeconds = (row.audioSeconds ?? 0) + add;
    // The `SET expiresAt = if_not_exists(...)` half of the expression. The
    // fake used to ignore it, which made "a lifetime row must carry no TTL"
    // pass no matter what record() actually wrote — the regression it guards
    // (the trial renewing itself every forty days) was invisible to the suite.
    const ttl = body.ExpressionAttributeValues[":ttl"]?.N;
    if (body.UpdateExpression?.includes("expiresAt") && ttl != null) {
      row.expiresAt ??= Number(ttl);
    }
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
    // REPLACES the whole item, exactly as the real PutItem does. The fake
    // used to merge into the existing row, which hid the one bug class the
    // `#trial` usage-key suffix exists to prevent: a verdict PutItem wiping
    // a usage counter that shared its key.
    rows.set(key, {
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
/// When set, the classifier upstream answers 502, for the refund path.
let jevDown = false;

function stubFetch() {
  globalThis.fetch = async (url, init) => {
    const href = String(url);
    upstream.push(href);
    // The body matters as well as the destination: the summarize route is
    // supposed to REBUILD what it sends rather than forward what it was given,
    // and only the body can show that.
    upstreamBodies.push(typeof init?.body === "string" ? init.body : "");
    if (href.includes("polar")) {
      return new Response(
        JSON.stringify({ status: licenseValid ? "granted" : "revoked" }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }
    if (href.includes("/audio/translations") || href.includes("/audio/transcriptions")) {
      return new Response(JSON.stringify({ transcript: "ok" }), { status: 200 });
    }
    if (href.includes("/chat/completions")) {
      return new Response(JSON.stringify({ choices: [] }), { status: 200 });
    }
    if (href.includes("api.typesafe.ai")) {
      if (jevDown) return new Response("boom", { status: 502 });
      return new Response(JSON.stringify({ model: "jev-1.13.0", answers: {} }), {
        status: 200, headers: { "content-type": "application/json" },
      });
    }
    if (href.includes("openrouter.ai/api/alpha/decisions")) {
      return new Response(JSON.stringify({ model: "typesafe/jev-1.13", answers: { tier: { type: "score", score: 0 } } }), {
        status: 200, headers: { "content-type": "application/json" },
      });
    }
    if (href.includes("ai-gateway.vercel.sh")) {
      // TypeSafe's own shape, straight through.
      return new Response(JSON.stringify({ model: "typesafe-ai/jev", answers: { tier: { type: "score", score: 0 } } }), {
        status: 200, headers: { "content-type": "application/json" },
      });
    }
    if (href.includes("api.cloudflare.com")) {
      // Workers AI wraps the model's own answer in its envelope.
      return new Response(JSON.stringify({
        result: { model: "jev-1.13.0", answers: { tier: { type: "score", score: 0 } } },
        success: true, errors: [], messages: [],
      }), { status: 200, headers: { "content-type": "application/json" } });
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
  process.env.TYPESAFE_API_KEY = "test-typesafe";

  ({ handle, logLine } = await import("../relay.mjs"));
});

after(() => server?.close());

beforeEach(() => {
  rows.clear();
  failWritesTo.clear();
  upstream = [];
  upstreamBodies = [];
  licenseValid = true;
  jevDown = false;
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
  assert.ok(upstream.some((u) => u.includes("/audio/translations")), "should have reached the transcription upstream");
});

test("?task=transcribe asks Groq for the words as spoken, and is metered the same", async () => {
  const r = await handle({
    method: "POST", path: "/v1/transcribe", query: "task=transcribe", token: "dev_zh",
    contentType: "multipart/form-data; boundary=x", body: Buffer.alloc(20 * 32_000),
  });
  assert.equal(r.status, 200);
  assert.ok(upstream.some((u) => u.includes("/audio/transcriptions")), "should reach the transcriptions upstream");
  assert.ok(!upstream.some((u) => u.includes("/audio/translations")), "and not the translation one");
  assert.equal(rows.get("dev:zh").audioSeconds, 20);
});

test("seconds land on the device's lifetime row, and on today's global row", async () => {
  await post("dev_abc", 25);
  assert.equal(rows.get("dev:abc").audioSeconds, 25);
  const global = [...rows.keys()].find((k) => k.startsWith("global#"));
  assert.equal(rows.get(global).audioSeconds, 25);
});

test("the free trial runs out, and the refusal is 402 with the upstream untouched", async () => {
  seed("dev:heavy", FREE_TRIAL_SECONDS - 20);   // 20 seconds of trial left
  const ok = await post("dev_heavy", 15);
  assert.equal(ok.status, 200, "still inside the trial");

  upstream = [];
  const refused = await post("dev_heavy", 25);  // tips it over
  assert.equal(refused.status, 402);
  assert.equal(
    upstream.filter((u) => u.includes("/audio/translations")).length, 0,
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
  assert.equal(r.status, 200, "45 minutes is over free's 30 and well under Pro's ten hours");
  assert.ok(upstream.some((u) => u.includes("polar")), "should have validated");
});

test("the Polar verdict is cached — dozens of chunks, one validation", async () => {
  for (let i = 0; i < 5; i++) await post("lic_real-key", 20);
  assert.equal(
    upstream.filter((u) => u.includes("polar")).length, 1,
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
    upstream.filter((u) => u.includes("polar")).length, 1,
    "a garbage key must not generate a validation per chunk",
  );
});

test("a forged licence key gets no allowance at all, not a fresh trial", async () => {
  // THE FORGERY THIS CLOSES, IN THREE ACTS. A `lic_` subject first landed in a
  // MONTHLY row carrying the FREE cap, so junk got thirty minutes every
  // calendar month, self-resetting. The `#trial` suffix fixed the renewal and
  // left the rest: a LIFETIME trial keyed on whatever string was typed, so
  // thirty minutes could still be minted by typing `ee`, then `ff`, for ever.
  // Found by typing `ee` into Settings and watching the bar refill.
  //
  // The trial belongs to the machine — that is what the derived device token is
  // for — so a licence the store does not recognise is worth nothing.
  licenseValid = false;
  const r = await post("lic_forged", 20);
  assert.equal(r.status, 402, "no allowance, so the very first chunk is refused");
  assert.match(JSON.parse(r.body).error, /remove it/,
    "and the sentence says what to do, rather than naming a trial they never started");
  assert.equal(rows.get(trialRow("forged"))?.audioSeconds ?? 0, 0,
    "refused, therefore refunded — a forged key cannot even bank seconds");
  assert.equal(rows.get(monthRow("forged")), undefined, "and never touches a monthly row");
  assert.equal(upstream.filter((u) => u.includes("/audio/translations")).length, 0,
    "nothing was bought");
});

test("a second forged key is worth no more than the first", async () => {
  // The whole point: junk is not a fresh identity. There are infinitely many
  // strings and each used to be worth half an hour.
  licenseValid = false;
  for (const key of ["lic_ee", "lic_ff", "lic_gg"]) {
    const r = await post(key, 20);
    assert.equal(r.status, 402, `${key} must buy nothing`);
  }
  assert.equal(rows.get(globalKey(Date.now()))?.audioSeconds ?? 0, 0,
    "and none of them reached the day's ceiling either");
});

test("the device keeps its own trial while a bad key is pasted over it", async () => {
  // What the user saw and reported as "it reset my trial": the bar refilled
  // because the BEARER changed, not because any counter moved. Removing the key
  // must return them to their own trial with whatever was left of it.
  seed("dev:mine", 600);
  licenseValid = false;
  await post("lic_junk", 20);
  assert.equal(rows.get("dev:mine").audioSeconds, 600, "the machine's trial is untouched");
  const back = await handle({ method: "GET", path: "/v1/quota", token: "dev_mine" });
  assert.equal(JSON.parse(back.body).usedSeconds, 600, "and is still there when the key comes out");
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
  assert.equal(r.status, 200, "the sentence that says what Deiko heard is not the paid part");
  assert.equal(
    rows.get("dev:spent").audioSeconds, before,
    "a text summary must not spend an audio allowance",
  );
});

test("a summary IS counted, so a flood cannot stay invisible", async () => {
  const key = `global#${new Date().toISOString().slice(0, 10)}#summary`;
  const before = rows.get(key)?.audioSeconds ?? 0;
  await summarize("dev_anyone");
  assert.equal((rows.get(key)?.audioSeconds ?? 0), before + 1,
    "an unmetered route is an unbounded bill");
});

test("a flood of summaries cannot close transcription for a paying customer", async () => {
  // THE ATTACK THIS PINS. /v1/summarize takes any bearer string and the burst
  // limiter is keyed by token, so a caller rotating tokens sends as many as it
  // likes. While these were charged five nominal seconds against the AUDIO
  // ceiling, ~8,600 cheap text calls closed transcription for everybody —
  // paying customers included — until UTC midnight, for about a dollar.
  const audioDay = `global#${new Date().toISOString().slice(0, 10)}`;
  for (let i = 0; i < 50; i += 1) await summarize(`dev_flood${i}`);
  assert.equal(rows.get(audioDay)?.audioSeconds ?? 0, 0,
    "summaries must not touch the ceiling that bounds transcription");
  const paid = await post("lic_real-key", 20);
  assert.equal(paid.status, 200, "a paying customer transcribes through a summary flood");
});

test("the caller does not get to choose the model or the token budget", async () => {
  // This route spends Deiko's Groq key and accepts any bearer string. Before
  // the body was rebuilt server-side, that made it an open LLM proxy: name an
  // expensive model and a large completion, and bill it here.
  await summarize("dev_greedy", {
    model: "some-expensive-model",
    max_completion_tokens: 100_000,
    messages: [{ role: "user", content: "hi" }],
  });
  const sent = JSON.parse(upstreamBodies.at(-1));
  assert.equal(sent.model, "openai/gpt-oss-20b", "the model is ours to pick");
  assert.equal(sent.max_completion_tokens, 200, "and so is the completion budget");
});

// ── Classification ──────────────────────────────────────────────────────────

const classify = (token, body) => handle({
  method: "POST", path: "/v1/classify", token,
  contentType: "application/json",
  body: Buffer.from(JSON.stringify(body ?? { narration: "fix the drag on the board" })),
});
const classifyDay = () => `global#${new Date().toISOString().slice(0, 10)}#classify`;

test("a classification is counted on its own row and never on the audio ceiling", async () => {
  const audioDay = `global#${new Date().toISOString().slice(0, 10)}`;
  const r = await classify("dev_anyone");
  assert.equal(r.status, 200);
  assert.equal(rows.get(classifyDay())?.audioSeconds, 1, "an unmetered route is an unbounded bill");
  assert.equal(rows.get(audioDay)?.audioSeconds ?? 0, 0, "a text call must not touch the audio ceiling");
  assert.equal(rows.get(`global#${new Date().toISOString().slice(0, 10)}#summary`)?.audioSeconds ?? 0, 0,
    "nor the summary's");
});

test("the relay builds the classifier request itself: pinned model, pinned questions", async () => {
  const candidates = Array.from({ length: 130 }, (_, i) => ({
    id: `202609${String(i % 28 + 1).padStart(2, "0")}-${String(100000 + i).slice(-6)}`,
    date: "Sep 1", line: `earlier brief ${i}`,
  }));
  candidates.push({ id: "../etc/passwd", date: "?", line: "not a session" });
  candidates.push({ id: "none", date: "?", line: "not a session either" });
  await classify("dev_greedy", {
    model: "some-expensive-model",
    questions: { steal: { type: "choice", criteria: { a: "b" } } },
    narration: "same drag bug as last time on the board",
    titles: ["Orb.swift — Deiko"],
    collections: [{ id: "deiko", name: "Deiko", hint: "the mac app" }, { id: "Bad Id", name: "x" }, { id: "none", name: "x" }],
    candidates,
  });
  const sent = JSON.parse(upstreamBodies.at(-1));
  assert.equal(sent.model, "jev-1.13.0", "the model is ours to pick");
  assert.equal(sent.questions.steal, undefined, "and so are the questions");
  const keys = Object.keys(sent.questions);
  assert.equal(keys.filter((k) => k.startsWith("rel_")).length, 120, "candidates are capped");
  assert.equal(keys.length, 3 + 120, "tier, collection, continues, one yes/no per candidate");
  assert.equal(keys.some((k) => k.includes("..")), false, "a bogus id never becomes a question");
  assert.deepEqual(Object.keys(sent.questions.collection.criteria), ["deiko", "none"]);
  assert.equal(sent.questions.collection.criteria.deiko, "Deiko — the mac app");
  assert.equal(sent.questions.continues.criteria.none, "It stands on its own");
  // Lowercase, and case-sensitive per docs.typesafe.ai/api — a capitalised
  // `Choice` is a 400 on the first real call, which is the worst moment to
  // find out.
  assert.deepEqual(
    [...new Set(Object.values(sent.questions).map((q) => q.type))].sort(),
    ["choice", "noul", "score"],
  );
  assert.ok(Array.isArray(sent.questions.tier.criteria), "score levels are an ordered array");
  assert.equal(typeof sent.questions.collection.criteria, "object", "choice options are a map");
  assert.equal(sent.state.brief.windowTitles[0], "Orb.swift — Deiko");
});

test("with an empty board only the tier is asked", async () => {
  await classify("dev_first");
  const sent = JSON.parse(upstreamBodies.at(-1));
  assert.deepEqual(Object.keys(sent.questions), ["tier"]);
});

test("a classification without a narration is refused", async () => {
  const r = await classify("dev_empty", { candidates: [] });
  assert.equal(r.status, 400);
  assert.equal(rows.get(classifyDay())?.audioSeconds ?? 0, 0, "a refusal is not counted");
});

test("an upstream failure refunds the classification", async () => {
  jevDown = true;
  const r = await classify("dev_unlucky");
  assert.equal(r.status, 502);
  assert.equal(rows.get(classifyDay())?.audioSeconds ?? 0, 0);
});

test("Cloudflare serves the same model, and the caller cannot tell", async () => {
  // TypeSafe paused signups; the same model on Workers AI is the way in for
  // anybody without a key. The app must see one shape either way.
  const key = process.env.TYPESAFE_API_KEY;
  delete process.env.TYPESAFE_API_KEY;
  process.env.CLOUDFLARE_ACCOUNT_ID = "acct";
  process.env.CLOUDFLARE_AI_TOKEN = "cf-token";
  try {
    const r = await classify("dev_cf");
    assert.equal(r.status, 200);
    assert.ok(upstream.at(-1).includes("api.cloudflare.com/client/v4/accounts/acct/ai/run"));
    const sent = JSON.parse(upstreamBodies.at(-1));
    assert.equal(sent.model, "typesafe/jev", "Cloudflare names the model its own way");
    assert.ok(sent.input.questions.tier, "the questions are the same ones, wrapped");
    const back = JSON.parse(r.body);
    assert.equal(back.result, undefined, "the envelope is taken off");
    assert.ok(back.answers.tier, "and the answers are where the app looks for them");
  } finally {
    process.env.TYPESAFE_API_KEY = key;
    delete process.env.CLOUDFLARE_ACCOUNT_ID;
    delete process.env.CLOUDFLARE_AI_TOKEN;
  }
});

test("Vercel's gateway takes TypeSafe's dialect unchanged", async () => {
  const key = process.env.TYPESAFE_API_KEY;
  delete process.env.TYPESAFE_API_KEY;
  process.env.AI_GATEWAY_API_KEY = "vc-key";
  try {
    const r = await classify("dev_vercel");
    assert.equal(r.status, 200);
    assert.ok(upstream.at(-1).includes("ai-gateway.vercel.sh/typesafe/v1/systemone"));
    const sent = JSON.parse(upstreamBodies.at(-1));
    assert.equal(sent.model, "typesafe-ai/jev", "Vercel names the model its own way");
    assert.ok(sent.questions.tier, "and everything else is TypeSafe's request, unwrapped");
    assert.equal(sent.input, undefined, "no Cloudflare envelope here");
    assert.ok(JSON.parse(r.body).answers.tier, "the answers come back where the app looks");
  } finally {
    process.env.TYPESAFE_API_KEY = key;
    delete process.env.AI_GATEWAY_API_KEY;
  }
});

test("OpenRouter's decisions endpoint takes TypeSafe's dialect unchanged", async () => {
  const key = process.env.TYPESAFE_API_KEY;
  delete process.env.TYPESAFE_API_KEY;
  process.env.OPENROUTER_API_KEY = "or-key";
  try {
    const r = await classify("dev_openrouter");
    assert.equal(r.status, 200);
    assert.ok(upstream.at(-1).includes("openrouter.ai/api/alpha/decisions"));
    const sent = JSON.parse(upstreamBodies.at(-1));
    assert.equal(sent.model, "typesafe/jev-1.13");
    assert.ok(sent.questions.tier);
    assert.equal(sent.input, undefined);
    assert.ok(JSON.parse(r.body).answers.tier);
  } finally {
    process.env.TYPESAFE_API_KEY = key;
    delete process.env.OPENROUTER_API_KEY;
  }
});

test("the vendor outranks every gateway when both are configured", async () => {
  process.env.AI_GATEWAY_API_KEY = "vc-key";
  try {
    await classify("dev_both");
    assert.ok(upstream.at(-1).includes("api.typesafe.ai"), "a TypeSafe key is used when present");
  } finally {
    delete process.env.AI_GATEWAY_API_KEY;
  }
});

test("with no classifier configured at all the route says so", async () => {
  const key = process.env.TYPESAFE_API_KEY;
  delete process.env.TYPESAFE_API_KEY;
  try {
    assert.equal((await classify("dev_none")).status, 503);
  } finally {
    process.env.TYPESAFE_API_KEY = key;
  }
});

test("an oversized classification body is refused before it is parsed", async () => {
  const r = await handle({
    method: "POST", path: "/v1/classify", token: "dev_big",
    contentType: "application/json", body: Buffer.alloc(97 * 1024, "x"),
  });
  assert.equal(r.status, 413);
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
  // because DEIKO_REVOKED_TOKENS needs the value in full. You could see an
  // abusive install and still have no way to stop it.
  const line = logLine({ method: "POST", path: "/v1/transcribe", status: 200, ms: 5, token: "dev_abuser" });
  const printed = line.split("tok:")[1];
  assert.ok(printed && printed.length === 12, "the log carries a fingerprint, not a token");
  assert.ok(!line.includes("dev_abuser"), "and never the bearer itself");

  process.env.DEIKO_REVOKED_TOKENS = printed;
  try {
    const r = await post("dev_abuser", 10);
    assert.equal(r.status, 403, "the string you can read must be the string you can revoke");
  } finally {
    delete process.env.DEIKO_REVOKED_TOKENS;
  }
});

test("the quota route is rate limited too", async () => {
  // It reads DynamoDB, writes a verdict row, and for an unseen licence calls
  // Polar — all of which sat ABOVE the limiter, making it the cheapest
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
    upstream.filter((u) => u.includes("/audio/translations")).length, 0,
    "not knowing what somebody has spent must stop the buying, not start it",
  );
  await new Promise((r) => saved.listen(port, r));
});

// ── Refunds: a refusal or an outage must not spend anybody's seconds ────────

test("a refused request gives its seconds back — refusals cannot drain the day", async () => {
  seed("dev:spent", FREE_TRIAL_SECONDS);        // trial exactly used up
  const first = await post("dev_spent", 25);
  const second = await post("dev_spent", 25);
  assert.equal(first.status, 402);
  assert.equal(second.status, 402);
  // The counter is incremented before it is judged, so without the refund
  // these two refusals would have left 50 phantom seconds on BOTH rows —
  // and 30 refusals a minute walk the global ceiling shut in twelve minutes.
  assert.equal(rows.get("dev:spent").audioSeconds, FREE_TRIAL_SECONDS);
  const global = [...rows.keys()].find((k) => k.startsWith("global#"));
  assert.equal(rows.get(global)?.audioSeconds ?? 0, 0);
});

test("a transcription outage does not eat the lifetime trial", async () => {
  globalThis.fetch = async (url) => {
    upstream.push(String(url));
    if (String(url).includes("/audio/translations")) return new Response("upstream down", { status: 503 });
    throw new Error(`unexpected upstream: ${url}`);
  };
  const r = await post("dev_unlucky", 20);
  assert.equal(r.status, 503, "the provider's failure is passed through");
  assert.equal(rows.get("dev:unlucky")?.audioSeconds ?? 0, 0,
    "audio that was never transcribed must not stay billed — the trial is once, ever");
});

test("a refused summary gives its count back", async () => {
  const { SUMMARIES_PER_DAY } = await import("../quota.mjs");
  const day = `global#${new Date().toISOString().slice(0, 10)}#summary`;
  seed(day, SUMMARIES_PER_DAY + 1);             // the day's summaries are spent
  const r = await handle({
    method: "POST",
    path: "/v1/summarize",
    token: "dev_orb",
    contentType: "application/json",
    body: Buffer.from(JSON.stringify({ messages: [{ role: "user", content: "hi" }] })),
  });
  assert.equal(r.status, 429);
  assert.equal(rows.get(day).audioSeconds, SUMMARIES_PER_DAY + 1,
    "refused summaries must not keep climbing the ceiling that is refusing them");
});

// ── The Polar verdict: an error is not an answer ────────────────────

test("one Polar failure does not demote a paying customer for a day", async () => {
  // A real "pro" verdict exists but is stale, so revalidation is due.
  rows.set("lic:steady", { tier: "pro", checkedAt: Date.now() - 25 * 60 * 60 * 1000 });
  globalThis.fetch = async (url) => {
    upstream.push(String(url));
    if (String(url).includes("polar")) throw new Error("timeout");
    if (String(url).includes("/audio/translations")) return new Response(JSON.stringify({ transcript: "ok" }), { status: 200 });
    throw new Error(`unexpected upstream: ${url}`);
  };
  const r = await post("lic_steady", 20);
  assert.equal(r.status, 200, "the last real verdict stands through an outage");
  assert.equal(rows.get(monthRow("steady"))?.audioSeconds, 20,
    "still metered as Pro — on the monthly row, not the lifetime trial row");
  assert.equal(rows.get("lic:steady").tier, "pro", "the error must not overwrite the verdict");
});

test("an error-derived free verdict is rechecked in minutes, not tomorrow", async () => {
  globalThis.fetch = async (url) => {
    upstream.push(String(url));
    if (String(url).includes("polar")) return new Response("oops", { status: 500 });
    if (String(url).includes("/audio/translations")) return new Response(JSON.stringify({ transcript: "ok" }), { status: 200 });
    throw new Error(`unexpected upstream: ${url}`);
  };
  const r = await post("lic_newkey", 20);
  // THE ACCEPTED COST OF THE FORGERY FIX. This used to be a 200: an
  // unvalidatable key fell back to the free trial and transcribed. It cannot
  // any more, because that allowance was what junk keys were minting. A real
  // customer meets this only with a BRAND-NEW key during a Polar outage —
  // anyone who has validated once has a cached verdict, and the short retry
  // below is what makes the window minutes rather than a day.
  assert.equal(r.status, 402, "an unknown key buys nothing — and is never promoted either");
  const verdict = rows.get("lic:newkey");
  assert.equal(verdict.tier, "free");
  assert.ok(Date.now() - verdict.checkedAt > 20 * 60 * 60 * 1000,
    "written already-stale, so the recheck happens when Polar is back, not in 24h");
});

// ── The summarize envelope count is pinned like everything else ─────────────

test("twenty thousand empty messages do not reach the model", async () => {
  const flood = Array.from({ length: 20_000 }, () => ({}));
  const r = await handle({
    method: "POST",
    path: "/v1/summarize",
    token: "dev_flood",
    contentType: "application/json",
    body: Buffer.from(JSON.stringify({ messages: flood })),
  });
  assert.equal(r.status, 200);
  const sent = JSON.parse(upstreamBodies.find((b) => b.includes('"model"')));
  assert.ok(sent.messages.length <= 32,
    `the caller chose 20,000 envelopes; the relay must choose the count (sent ${sent.messages.length})`);
});

// ── The id is a security boundary, end to end ───────────────────────────────

test("a crafted licence id cannot reset a paying customer's month", async () => {
  // Before the charset rule, `lic_<key>#<month>` reached tierFor, whose
  // PutItem replaced the real key's MONTHLY usage row with a verdict object —
  // the counter gone, for the price of one GET.
  const key = "DEIKO-REAL-KEY";
  rows.set(`lic:${key}`, { tier: "pro", checkedAt: Date.now() });
  seed(monthRow(key), 30_000);

  const r = await handle({
    method: "GET",
    path: "/v1/quota",
    token: `lic_${key}#${monthKey(Date.now())}`,
  });
  assert.equal(r.status, 401, "malformed, therefore not a subject at all");
  assert.equal(rows.get(monthRow(key)).audioSeconds, 30_000, "the month is untouched");
  assert.equal(upstream.filter((u) => u.includes("polar")).length, 0, "and Polar was never asked");
});

test("a partial write banks nothing — the global row is taken back when the subject write fails", async () => {
  // The exact failure an over-long id produced at DynamoDB: the subject write
  // rejects, the global write beside it lands. Without compensation those
  // seconds sat on the day's row with no refund path able to reach them.
  failWritesTo.add("dev:half");
  const r = await post("dev_half", 20);
  assert.equal(r.status, 503, "fail closed, as before");
  assert.equal(rows.get(globalKey(Date.now()))?.audioSeconds ?? 0, 0,
    "the global write landed and was compensated — no phantom seconds");
  assert.equal(upstream.filter((u) => u.includes("/audio/translations")).length, 0, "nothing was bought");
});

test("an upstream that throws is a 502 that refunds, and says nothing about why", async () => {
  // A timeout or a DNS failure rejects the fetch. Uncaught, that left handle()
  // before either `status >= 500` refund — a provider stall ate a lifetime
  // trial — and carried the message into a public body via the adapter.
  globalThis.fetch = async (url) => {
    upstream.push(String(url));
    if (String(url).includes("/audio/translations")) throw new Error("getaddrinfo ENOTFOUND api.groq.com");
    throw new Error(`unexpected upstream: ${url}`);
  };
  const r = await post("dev_dns", 20);
  assert.equal(r.status, 502);
  assert.doesNotMatch(r.body, /ENOTFOUND|getaddrinfo/, "the reason is for CloudWatch, not the caller");
  assert.equal(rows.get("dev:dns").audioSeconds, 0, "refunded — nothing was bought");
  assert.equal(rows.get(globalKey(Date.now())).audioSeconds, 0, "on the day's row too");
});

// ── The cheapest request has a price ────────────────────────────────────────

test("a tiny body still costs the floor — compressed audio cannot buy thirty seconds for one", async () => {
  // 16 KB: the byte rule says half a second. A caller sending 8 kbps MP3
  // would get ~15 s of Groq for it; the floor is what bounds how many times
  // a day that trade can be made.
  const r = await post("dev_tiny", 0.5);
  assert.equal(r.status, 200);
  assert.equal(rows.get("dev:tiny").audioSeconds, MIN_SECONDS_PER_REQUEST);
  assert.equal(rows.get(globalKey(Date.now())).audioSeconds, MIN_SECONDS_PER_REQUEST);
});
