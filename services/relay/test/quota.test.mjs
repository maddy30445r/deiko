// The decisions that stand between a stranger and our Sarvam bill, checked
// without an AWS account. Everything here is pure: `usage.mjs` moves the
// numbers, `quota.mjs` says what they mean, and only the second one can be
// wrong in a way that costs money quietly.

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  BYTES_PER_SECOND,
  FREE_TRIAL_SECONDS,
  GLOBAL_DAILY_SECONDS,
  PRO_MONTHLY_SECONDS,
  MAX_SECONDS_PER_REQUEST,
  MIN_SECONDS_PER_REQUEST,
  audioSeconds,
  capFor,
  dayKey,
  decide,
  globalKey,
  ipBucket,
  licenseKey,
  monthKey,
  subjectFrom,
  usageKey,
} from "../quota.mjs";

// ── Who is calling ──────────────────────────────────────────────────────────

test("a prefixed licence and a prefixed device token are told apart", () => {
  assert.deepEqual(subjectFrom("lic_ABC-123"), { kind: "license", id: "ABC-123" });
  assert.deepEqual(subjectFrom("dev_ABC-123"), { kind: "device", id: "ABC-123" });
});

test("an unprefixed token is a device — every build up to 0.3.0 sends one", () => {
  const legacy = "7C6C4E1A-58F9-4E2E-9E1B-2F0A3B4C5D6E";
  assert.deepEqual(subjectFrom(legacy), { kind: "device", id: legacy });
});

test("a licence key and a device token are indistinguishable WITHOUT the prefix", () => {
  // Both are v4-shaped UUIDs. This is why the prefix exists at all, and the
  // assertion is here so that removing it fails loudly rather than silently
  // metering every paying customer as a free trial.
  const uuid = "7C6C4E1A-58F9-4E2E-9E1B-2F0A3B4C5D6E";
  assert.equal(subjectFrom(uuid).kind, "device");
  assert.equal(subjectFrom(`lic_${uuid}`).kind, "license");
});

test("nothing, an empty string, or a bare prefix is not a subject", () => {
  for (const bad of [null, undefined, "", "lic_", "dev_", 42, {}]) {
    assert.equal(subjectFrom(bad), null, `${JSON.stringify(bad)} should not be a subject`);
  }
});

// ── Where the numbers live ──────────────────────────────────────────────────

const AUG = Date.UTC(2026, 7, 10, 12, 0, 0);
const SEP = Date.UTC(2026, 8, 1, 0, 0, 0);

test("a device's trial key carries no month — the trial is once, not monthly", () => {
  const device = subjectFrom("dev_abc");
  assert.equal(usageKey(device, AUG), "dev:abc");
  assert.equal(usageKey(device, SEP), "dev:abc", "a new month must not reset a lifetime trial");
});

test("a PRO licence meters per calendar month, so the key rolls over on its own", () => {
  const licence = subjectFrom("lic_xyz");
  assert.equal(usageKey(licence, AUG, "pro"), "lic:xyz#2026-08");
  assert.equal(usageKey(licence, SEP, "pro"), "lic:xyz#2026-09");
});

test("a licence that is NOT Pro gets a lifetime row, like any other trial", () => {
  // Typing junk into the licence field used to be strictly better than being
  // honest: it bought the monthly row while keeping the free cap, so the
  // once-ever trial renewed itself every calendar month, forever.
  const licence = subjectFrom("lic_junk");
  assert.equal(usageKey(licence, AUG, "free"), "lic:junk#trial");
  assert.equal(
    usageKey(licence, SEP, "free"),
    "lic:junk#trial",
    "a new month must not reset a forged trial any more than a real one",
  );
});

test("a licence's cached verdict is a different row from its usage, on either tier", () => {
  const licence = subjectFrom("lic_xyz");
  assert.equal(licenseKey(licence), "lic:xyz");
  assert.notEqual(licenseKey(licence), usageKey(licence, AUG, "pro"));
  // The free case is the one that could collide: `tierFor` writes the verdict
  // row with PutItem, which replaces the whole item — a trial counter sharing
  // that key would be wiped clean on every revalidation.
  assert.notEqual(licenseKey(licence), usageKey(licence, AUG, "free"));
});

test("month and day keys are UTC, so a limit never resets at an unpredictable hour", () => {
  // 23:30 UTC on the 10th is already the 11th in India. The key must not care.
  const lateUTC = Date.UTC(2026, 7, 10, 23, 30, 0);
  assert.equal(dayKey(lateUTC), "2026-08-10");
  assert.equal(monthKey(lateUTC), "2026-08");
  assert.equal(globalKey(lateUTC), "global#2026-08-10");
});

test("the last instant of a month and the first of the next differ", () => {
  assert.equal(monthKey(Date.UTC(2026, 7, 31, 23, 59, 59)), "2026-08");
  assert.equal(monthKey(Date.UTC(2026, 8, 1, 0, 0, 0)), "2026-09");
});

// ── Seconds from bytes, without touching the audio ──────────────────────────

test("audio seconds come from the body's length, never from its contents", () => {
  assert.equal(audioSeconds(BYTES_PER_SECOND), 1);
  assert.equal(audioSeconds(BYTES_PER_SECOND * 25), 25, "one 25s chunk");
  assert.equal(audioSeconds(0), 0);
  assert.equal(audioSeconds(null), 0);
  assert.equal(audioSeconds(-5), 0);
});

test("no single request may count as more than one oversized chunk", () => {
  // The counter is incremented before it is judged, so without a clamp a
  // handful of maximum-size junk bodies could spend the whole service's daily
  // ceiling and lock out everybody paying. An honest chunk is 25s and never
  // approaches this.
  assert.equal(audioSeconds(BYTES_PER_SECOND * 10_000), MAX_SECONDS_PER_REQUEST);
  assert.ok(MAX_SECONDS_PER_REQUEST > 25, "but an honest 25s chunk must count in full");
});

test("multipart overhead over-counts, which is the safe direction for a limit", () => {
  const overhead = 400;
  const seconds = audioSeconds(BYTES_PER_SECOND * 25 + overhead);
  assert.ok(seconds > 25, "must not under-count");
  assert.ok(seconds < 25.02, `overhead should be well under 1%, got ${seconds}`);
});

// ── The decision ────────────────────────────────────────────────────────────

const under = { tier: "free", usedSeconds: 60, globalUsedSeconds: 60 };

test("a fresh free install is allowed, and is told what is left", () => {
  const v = decide(under);
  assert.equal(v.allowed, true);
  assert.equal(v.status, 200);
  assert.equal(v.remainingSeconds, FREE_TRIAL_SECONDS - 60);
});

test("free past the trial is 402, not 429 — it is a state, not a hiccup", () => {
  const v = decide({ ...under, usedSeconds: FREE_TRIAL_SECONDS + 1 });
  assert.equal(v.allowed, false);
  assert.equal(v.status, 402);
  assert.match(v.error, /on your Mac/, "the message must say the app keeps working");
});

test("exactly at the cap is still allowed; past it is not", () => {
  assert.equal(decide({ ...under, usedSeconds: FREE_TRIAL_SECONDS }).allowed, true);
  assert.equal(decide({ ...under, usedSeconds: FREE_TRIAL_SECONDS + 0.1 }).allowed, false);
});

test("pro gets twenty times the free allowance, per month", () => {
  assert.equal(capFor("pro"), PRO_MONTHLY_SECONDS);
  assert.equal(capFor("free"), FREE_TRIAL_SECONDS);
  assert.equal(capFor(undefined), FREE_TRIAL_SECONDS, "an unknown tier must not be generous");
});

test("pro past fair use is 429 — there is nothing to buy, so it is not 402", () => {
  const v = decide({ tier: "pro", usedSeconds: PRO_MONTHLY_SECONDS + 1, globalUsedSeconds: 0 });
  assert.equal(v.status, 429);
  assert.match(v.error, /fair-use/);
});

test("the global ceiling stops everybody, including pro", () => {
  const v = decide({
    tier: "pro",
    usedSeconds: 0,
    globalUsedSeconds: GLOBAL_DAILY_SECONDS + 1,
  });
  assert.equal(v.allowed, false);
  assert.equal(v.status, 429);
});

test("forged free tokens cannot spend the half of the day reserved for Pro", () => {
  // A device token is DERIVED FROM THE MACHINE and therefore forgeable — a VM
  // or a patched client mints as many as it likes, each with a fresh trial. If
  // free traffic could reach the whole ceiling, two dozen of them would 429
  // every paying customer until UTC midnight. A licence cannot be forged, so
  // the top half of the day belongs to licences.
  const justOverTheFreeShare = Math.floor(GLOBAL_DAILY_SECONDS * 0.5) + 1;
  assert.equal(
    decide({ tier: "free", usedSeconds: 60, globalUsedSeconds: justOverTheFreeShare }).allowed,
    false, "free is cut off at its share");
  assert.equal(
    decide({ tier: "pro", usedSeconds: 60, globalUsedSeconds: justOverTheFreeShare }).allowed,
    true, "a paying customer keeps transcribing through it");
});

test("the global ceiling is reported as ours, not as the caller's fault", () => {
  const v = decide({
    tier: "pro",
    usedSeconds: PRO_MONTHLY_SECONDS + 1,
    globalUsedSeconds: GLOBAL_DAILY_SECONDS + 1,
  });
  // Both limits are blown. The service's own ceiling wins the explanation,
  // because telling a paying customer they are out of quota when the service
  // is would send them to support instead of to a retry.
  assert.match(v.error, /daily ceiling/);
});

test("a refusal always reports zero remaining, never a negative number", () => {
  for (const tier of ["free", "pro"]) {
    const v = decide({ tier, usedSeconds: 10 ** 9, globalUsedSeconds: 0 });
    assert.equal(v.remainingSeconds, 0);
  }
});

// ── The id is a security boundary ───────────────────────────────────────────

test("an id carrying '#' is refused — it would spell another subject's usage row", () => {
  // `lic_<key>#2026-09` made the VERDICT row key equal the real key's MONTHLY
  // usage row, and tierFor's PutItem replaced the whole item: a paying
  // customer's month reset to zero for the price of one GET /v1/quota.
  const month = monthKey(Date.now());
  assert.equal(subjectFrom(`lic_DEIKO-REAL-KEY#${month}`), null);
  assert.equal(subjectFrom("lic_DEIKO-REAL-KEY#trial"), null);
  assert.equal(subjectFrom(`dev_abc#${month}`), null);
  assert.equal(subjectFrom("lic_a:b"), null, "':' is the other key-grammar character");
  assert.ok(subjectFrom("lic_DEIKO-REAL-KEY"), "the honest key still passes");
});

test("an over-long id is refused before it can reach a 2048-byte partition key", () => {
  // Past DynamoDB's limit the SUBJECT write throws while the global write
  // beside it lands — seconds banked against the whole day, nothing to refund
  // them against, and no Sarvam call to show for them.
  assert.equal(subjectFrom(`dev_${"a".repeat(129)}`), null);
  assert.equal(subjectFrom(`lic_${"A".repeat(2100)}`), null);
  assert.equal(subjectFrom("a".repeat(129)), null, "unprefixed too");
  assert.ok(subjectFrom(`dev_${"a".repeat(128)}`), "128 is the ceiling, not 127");
});

test("every real issuer's shape still passes, and nothing else does", () => {
  // Polar prefix + dashed key, the salted 32-hex device digest, the legacy bare
  // v4 UUID. Dropping any of these from the allowed set is a lockout.
  assert.ok(subjectFrom("lic_DEIKO-9F2A7C1B-4D3E-4A5B-8C6D-7E8F9A0B1C2D"));
  assert.ok(subjectFrom("dev_0c23f5dd3e497ca07d3e6560b884ea17"));
  assert.ok(subjectFrom("7C6C4E1A-58F9-4E2E-9E1B-2F0A3B4C5D6E"));
  assert.equal(subjectFrom("dev_ abc"), null, "whitespace is not an id");
  assert.equal(subjectFrom("lic_ключ"), null, "nor is anything outside ASCII");
  assert.equal(subjectFrom("lic_a/b"), null, "nor a path separator");
});

// ── The cheapest request has a price ────────────────────────────────────────

test("the byte rule alone is fooled by compressed audio, which is why a floor exists", () => {
  // Thirty seconds of 8 kbps MP3 is ~30 KB, priced by bytes at under a second.
  assert.ok(audioSeconds(30 * 1024) < 1);
  assert.ok(MIN_SECONDS_PER_REQUEST >= 5, "bounds the day at ~8,640 calls");
  assert.ok(MIN_SECONDS_PER_REQUEST < 25, "an honest 25s chunk must never meet it");
});

// ── What counts as one address ──────────────────────────────────────────────

test("an IPv6 caller is its /64, however the address is written", () => {
  // One subscriber is handed a whole /64. Keyed on the full address, a
  // single home line minted a fresh identity per request.
  const home = ipBucket("2001:db8:abcd:12::1");
  assert.equal(home, "2001:db8:abcd:12::/64");
  for (const same of ["2001:db8:abcd:12:ffff:1:2:3", "2001:0DB8:ABCD:0012::9", "2001:db8:abcd:12:0:0:0:0"]) {
    assert.equal(ipBucket(same), home, `${same} is the same subscriber`);
  }
  assert.notEqual(ipBucket("2001:db8:abcd:13::1"), home, "the next /64 is somebody else");
});

test("an IPv4 caller is its address, and a dual-stack socket's mapped form is the same one", () => {
  assert.equal(ipBucket("203.0.113.7"), "203.0.113.7");
  assert.equal(ipBucket("::ffff:203.0.113.7"), "203.0.113.7");
  assert.equal(ipBucket("fe80::1%en0"), "fe80:0:0:0::/64", "a zone id is not part of the address");
});

test("an IPv4-mapped address is its IPv4 however it is spelled, and ::1 is nobody else", () => {
  // All of these sat in one `0:0:0:0::/64` bucket, so every IPv4 caller a
  // dual-stack socket reported in hex shared a single allowance.
  for (const spelling of [
    "::ffff:203.0.113.7", "::FFFF:203.0.113.7", "::ffff:cb00:7107",
    "0:0:0:0:0:ffff:cb00:7107", "0000:0000:0000:0000:0000:FFFF:CB00:7107",
  ]) {
    assert.equal(ipBucket(spelling), "203.0.113.7", spelling);
  }
  assert.notEqual(ipBucket("::ffff:198.51.100.1"), ipBucket("::ffff:cb00:7107"), "two IPv4 callers are two callers");
  assert.notEqual(ipBucket("::1"), ipBucket("::2"), "the zero /64 is not one subscriber");
  assert.notEqual(ipBucket("::1"), ipBucket("::ffff:0:1"));
});
