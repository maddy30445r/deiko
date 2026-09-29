// The public playground is the easiest thing to point a script at: no install,
// no licence, and it spends the Groq key. These checks stand between a stranger
// and that bill, and between a prompt-injected transcript and the page.
//
// Pure where it can be: the ticket is HMAC arithmetic and the patch validator is
// a pure function, so neither needs AWS. The routes that touch DynamoDB are
// exercised only up to the point where they would.

import { test } from "node:test";
import assert from "node:assert/strict";

process.env.DEIKO_PLAYGROUND_SECRET = "test-secret";
process.env.GROQ_API_KEY = "test-key";

const { handle } = await import("../src/relay.mjs");

const call = (path, o = {}) => handle({
  origin: o.origin ?? "",
  method: o.method ?? "POST",
  path,
  query: "",
  token: o.token ?? null,
  contentType: o.contentType ?? "application/json",
  body: o.body ?? null,
});

// Mint a ticket the way the relay does, rather than through the route: issuing
// one counts against a per-caller daily cap that needs the usage table, and these
// tests run without AWS. The signature is the contract tested here; the counter
// is tested by the route.
const { createHmac } = await import("node:crypto");
const mintTicket = (ttlMs = 15 * 60 * 1000, id = "testticket") => {
  const expiresAt = Date.now() + ttlMs;
  const sig = createHmac("sha256", process.env.DEIKO_PLAYGROUND_SECRET)
    .update(`${id}.${expiresAt}`).digest("base64url");
  return `${id}.${expiresAt}.${sig}`;
};
const newTicket = async () => mintTicket();

test("issuing a ticket needs the usage table, and fails CLOSED without it", async () => {
  // The per-caller daily cap is the only thing stopping a script from minting
  // tickets in a loop, so none may be handed out when that counter cannot be
  // read. There is no AWS here, so this is the unreachable case.
  const res = await call("/v1/playground/ticket", { origin: "https://deiko.app" });
  assert.equal(res.status, 503);
});

test("only a listed page may ask for a ticket, and a script with no Origin may not", async () => {
  // CORS stops another site reading the answer, not its visitors' browsers
  // sending the request, so the check is on the request itself and comes before
  // the usage table is touched (a 503 here would mean it had not).
  for (const origin of ["https://evil.example", "", "https://deiko.app.evil.example"]) {
    const res = await call("/v1/playground/ticket", { origin });
    assert.equal(res.status, 403, `${origin || "no origin"} must be refused`);
  }
});

test("a minted ticket has the shape the relay signs", () => {
  assert.match(mintTicket(), /^[A-Za-z0-9_-]+\.\d+\.[A-Za-z0-9_-]+$/);
});

test("only a ticket this relay signed gets in", async () => {
  const ticket = mintTicket();
  const [id, exp, sig] = ticket.split(".");

  for (const [what, tok] of [
    ["none", null],
    ["nonsense", "not-a-ticket"],
    ["forged signature", `${id}.${exp}.${"x".repeat(sig.length)}`],
    ["expired", `${id}.${Date.now() - 1}.${sig}`],
    ["extended expiry, original signature", `${id}.${Number(exp) + 60_000}.${sig}`],
  ]) {
    const res = await call("/v1/playground/transcribe", { token: tok, body: Buffer.from("x") });
    assert.equal(res.status, 401, `${what} should be refused`);
  }
});

test("a clip has a hard byte ceiling, because browser audio cannot be metered by length", async () => {
  const ticket = await newTicket();
  const res = await call("/v1/playground/transcribe", {
    token: ticket,
    body: Buffer.alloc(600 * 1024),
    contentType: "multipart/form-data",
  });
  assert.equal(res.status, 413);
  assert.match(JSON.parse(res.body).error, /twenty seconds/);
});

// A spent ticket and a closed playground are different answers. The page holds
// a ticket across reloads, so when one runs out of goes it must know to fetch
// another. `spent` is that signal, and the daily ceilings must never carry it:
// retrying there would burn the caller's remaining tickets against a wall.
test("only a used-up ticket is marked spent, never a daily ceiling", async () => {
  const src = await (await import("node:fs")).promises.readFile(
    new URL("../src/relay.mjs", import.meta.url), "utf8");
  for (const [what, needle] of [
    ["the per-ticket clip limit", "this playground session is done"],
    ["the per-ticket query limit", "that is both of this session's goes"],
  ]) {
    const at = src.indexOf(needle);
    assert.notEqual(at, -1, `${what} message should exist`);
    assert.match(src.slice(at, at + 160), /spent: true/, `${what} must be marked spent`);
  }
  for (const ceiling of ["the playground is at its daily ceiling"]) {
    let at = src.indexOf(ceiling);
    while (at !== -1) {
      assert.doesNotMatch(src.slice(at, at + 120), /spent: true/,
        "a daily ceiling must not invite a retry");
      at = src.indexOf(ceiling, at + 1);
    }
  }
});

// The clip route forwards raw multipart, so the only thing stopping a caller
// naming a pricier model is a check on those bytes. It has to be strict about
// abuse and permissive about what a browser sends (an unanchored `name="` would
// match inside `filename="narration.webm"` and reject every real upload).
const clip = (parts, { filename = true } = {}) => {
  const b = "----WebKitFormBoundaryAbC123";
  const body = parts.map(([k, v]) =>
    `--${b}\r\nContent-Disposition: form-data; name="${k}"` +
    (k === "file" && filename ? `; filename="narration.webm"\r\nContent-Type: audio/webm` : "") +
    `\r\n\r\n${v}\r\n`).join("") + `--${b}--\r\n`;
  return { body: Buffer.from(body, "latin1"), contentType: `multipart/form-data; boundary=${b}` };
};
const postClip = async (parts, opts) => {
  const c = clip(parts, opts);
  return call("/v1/playground/transcribe", { token: mintTicket(), body: c.body, contentType: c.contentType });
};

test("a real browser upload is not mistaken for an abusive one", async () => {
  // Gets past every check on the upload (no usage table here, so anything but 400
  // proves it). The clip has to be audio: WebM's first four bytes, here.
  const res = await postClip([["file", "\x1a\x45\xdf\xa3" + "\0".repeat(16)], ["model", "whisper-large-v3"]]);
  assert.notEqual(res.status, 400, "the page's own upload shape must be accepted");
});

test("a field named after an Object property is refused, not a crash", async () => {
  // `TRANSCRIBE_FIELDS[name]` must not find Object's own `constructor`, whose
  // `.ok` is undefined and would throw a 500.
  for (const name of ["constructor", "__proto__", "toString", "hasOwnProperty"]) {
    const b = "----X";
    const res = await handle({
      method: "POST", path: "/v1/transcribe", query: "", token: "dev_proto", origin: "",
      contentType: `multipart/form-data; boundary=${b}`,
      body: Buffer.from(`--${b}\r\nContent-Disposition: form-data; name="${name}"\r\n\r\nx\r\n` +
        `--${b}\r\nContent-Disposition: form-data; name="file"\r\n\r\nRIFF\r\n--${b}--\r\n`),
    });
    assert.equal(res.status, 400, `${name} must be an unexpected field`);
  }
});

test("the caller cannot choose the model or smuggle billed fields", async () => {
  const pricier = await postClip([["file", "AUDIO"], ["model", "whisper-large-v3-turbo-expensive"]]);
  assert.equal(pricier.status, 400, "a longer model name must not pass as a prefix");
  assert.match(JSON.parse(pricier.body).error, /whisper-large-v3 only/);

  const smuggled = await postClip([["file", "AUDIO"], ["model", "whisper-large-v3"], ["prompt", "x".repeat(200)]]);
  assert.equal(smuggled.status, 400, "`prompt` is billed as input and is not ours to forward");

  const none = await postClip([["file", "AUDIO"]]);
  assert.equal(none.status, 400, "a missing model must not fall through to the vendor's default");
});

test("the file's own bytes cannot forge a field", async () => {
  // The caller picks the audio, so a scan of the whole request reads whatever
  // they write into it: here, an approved-looking model line hidden in the clip
  // with a real, pricier model part beside it.
  const b = "----X";
  const raw =
    `--${b}\r\nContent-Disposition: form-data; name="file"; filename="a.webm"\r\n\r\n` +
    `AAAA; name="model"\r\n\r\nwhisper-large-v3\r\nAAAA\r\n` +
    `--${b}\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-large-v3-turbo\r\n--${b}--\r\n`;
  const res = await call("/v1/playground/transcribe", {
    token: mintTicket(), body: Buffer.from(raw, "latin1"),
    contentType: `multipart/form-data; boundary=${b}`,
  });
  assert.equal(res.status, 400, "a model declared in the payload is not a model field");
});

test("a part after the last delimiter is still a part", async () => {
  // A body that does not end with `--boundary--` must not drop its final part
  // from validation, or a billed `prompt` field could hide there.
  const b = "----X";
  const raw =
    `--${b}\r\nContent-Disposition: form-data; name="file"; filename="a.webm"\r\n\r\nAUDIO\r\n` +
    `--${b}\r\nContent-Disposition: form-data; name="model"\r\n\r\nwhisper-large-v3\r\n` +
    `--${b}\r\nContent-Disposition: form-data; name="prompt"\r\n\r\n${"x".repeat(50)}`;
  const res = await call("/v1/playground/transcribe", {
    token: mintTicket(), body: Buffer.from(raw, "latin1"),
    contentType: `multipart/form-data; boundary=${b}`,
  });
  assert.equal(res.status, 400, "an unterminated body must be refused, not partly validated");
});

test("the intent route has a body ceiling of its own", async () => {
  // The shared cap lives below the playground block, so the route needs its own.
  const huge = Buffer.from(JSON.stringify({ said: "x", pointed: Array(400000).fill("cardcardcard") }));
  assert.ok(huge.length > 2 * 1024 * 1024);
  const res = await call("/v1/playground/intent", { token: mintTicket(), body: huge });
  assert.equal(res.status, 413);
});

test("the intent route insists on something to interpret", async () => {
  const ticket = await newTicket();
  const res = await call("/v1/playground/intent", { token: ticket, body: Buffer.from("{}") });
  assert.equal(res.status, 400);
});

test("playground routes take POST only, and unknown ones 404", async () => {
  assert.equal((await call("/v1/playground/ticket", { method: "GET" })).status, 405);
  const ticket = await newTicket();
  assert.equal((await call("/v1/playground/nope", { token: ticket })).status, 404);
});

test("with no secret configured the playground is closed, not open", async () => {
  const keep = process.env.DEIKO_PLAYGROUND_SECRET;
  delete process.env.DEIKO_PLAYGROUND_SECRET;
  try {
    assert.equal((await call("/v1/playground/ticket")).status, 503);
    assert.equal((await call("/v1/playground/transcribe", { token: "a.b.c" })).status, 503);
  } finally {
    process.env.DEIKO_PLAYGROUND_SECRET = keep;
  }
});

// The app's own routes must be unreachable through the playground and
// unaffected by it: a flood should exhaust the playground, never transcription
// for somebody who paid.
test("the app's routes still demand a real bearer", async () => {
  const ticket = mintTicket();
  const quota = await handle({
    method: "GET", path: "/v1/quota", query: "", token: null, contentType: "", body: null,
  });
  assert.equal(quota.status, 401);

  // A playground ticket is not an app subject: `subjectFrom` would otherwise
  // happily read it as a device token and hand it a lifetime free trial.
  const { subjectFrom } = await import("../src/quota.mjs");
  assert.equal(subjectFrom(ticket), null, "a ticket must not parse as an app subject");
});

// ── The patch validator ──
//
// The only thing between whatever a model returns (or a prompt-injected
// transcript talks it into returning) and the page. Exercised directly because
// the route it lives in needs DynamoDB. A multiplier such as `size: 1.2` must be
// dropped: rounded, it would be a one-pixel font.
const cleanPatch = await (async () => {
  const { readFileSync } = await import("node:fs");
  const src = readFileSync(new URL("../src/relay.mjs", import.meta.url), "utf8");
  const body = src.slice(src.indexOf("function cleanPatch"), src.indexOf("// ── The one entry point"));
  return new Function("PG_ELEMENTS", "PG_OPS", "PG_HEX", body + "; return cleanPatch;")(
    new Set(["card", "nameField", "change", "del", "tog1", "seats"]),
    new Set(["color", "background", "text", "size", "radius", "weight", "toggle", "hide", "show"]),
    /^#[0-9a-fA-F]{6}$/,
  );
})();

test("a number has to be plausible for what it is, or the edit is dropped", () => {
  assert.deepEqual(cleanPatch([{ target: "change", op: "size", value: 1.2 }]), [], "a multiplier is not a pixel size");
  assert.deepEqual(cleanPatch([{ target: "change", op: "size", value: 4000 }]), []);
  assert.deepEqual(cleanPatch([{ target: "change", op: "weight", value: 2 }]), []);
  assert.deepEqual(cleanPatch([{ target: "change", op: "size", value: 22 }]), [{ target: "change", op: "size", value: 22 }]);
  assert.deepEqual(cleanPatch([{ target: "change", op: "weight", value: 700 }]), [{ target: "change", op: "weight", value: 700 }]);
});

test("only real elements, real ops and real colours survive", () => {
  assert.deepEqual(cleanPatch([{ target: "window", op: "hide", value: true }]), [], "invented element");
  assert.deepEqual(cleanPatch([{ target: "card", op: "execute", value: "rm -rf /" }]), [], "invented op");
  assert.deepEqual(cleanPatch([{ target: "change", op: "background", value: "orange" }]), [], "colour must be #rrggbb");
  assert.deepEqual(cleanPatch([{ target: "change", op: "background", value: "#ff6a00" }]),
    [{ target: "change", op: "background", value: "#ff6a00" }]);
});

test("nothing unbounded reaches the page", () => {
  assert.deepEqual(cleanPatch("not an array"), []);
  assert.deepEqual(cleanPatch(null), []);
  assert.equal(cleanPatch(Array.from({ length: 40 }, () => ({ target: "card", op: "hide", value: true }))).length, 8);
  assert.equal(cleanPatch([{ target: "nameField", op: "text", value: "x".repeat(500) }])[0].value.length, 60);
});

// ── CORS ──
//
// Only the playground is called from a browser, so only it carries these. An
// allowlist rather than `*`, which would let any page spend the ticket budget
// from a visitor's browser.
test("an allowed origin is echoed back, an unknown one is not", async () => {
  process.env.DEIKO_PLAYGROUND_ORIGINS = "https://deiko.app,localhost";
  // CORS headers ride on every answer, including the fail-closed one.
  const ok = await call("/v1/playground/ticket", { origin: "https://deiko.app" });
  assert.equal(ok.headers["access-control-allow-origin"], "https://deiko.app");
  assert.equal(ok.headers.vary, "origin");

  const dev = await call("/v1/playground/ticket", { origin: "http://localhost:8801" });
  assert.equal(dev.headers["access-control-allow-origin"], "http://localhost:8801");

  const evil = await call("/v1/playground/ticket", { origin: "https://evil.example" });
  assert.equal(evil.headers["access-control-allow-origin"], undefined, "never echo an unchecked origin");
});

test("preflight is answered, and only for the playground", async () => {
  process.env.DEIKO_PLAYGROUND_ORIGINS = "https://deiko.app";
  const pre = await call("/v1/playground/transcribe", { method: "OPTIONS", origin: "https://deiko.app" });
  assert.equal(pre.status, 204);
  assert.match(pre.headers["access-control-allow-headers"], /authorization/);

  // the app's routes gain nothing
  const app = await handle({
    method: "OPTIONS", path: "/v1/transcribe", query: "", token: null,
    contentType: "", body: null, origin: "https://deiko.app",
  });
  assert.equal(app.headers, undefined, "app routes send no CORS headers");
});
