// THE DEPLOY SCRIPT, RUN AGAINST A FAKE AWS.
//
// `deploy-aws.sh` decides who may invoke the function, what the function's
// environment becomes and whether a deploy counts as healthy — and until now
// nothing checked any of it short of a real deploy. Here `aws`, `curl`, `npm`
// and `sleep` are stubs on PATH that log what they were asked and answer from
// the test's script, so the script's own logic runs with no account, no
// network and no keys. The environment is built from nothing: every value in
// it is a placeholder, and AWS's own credential lookups are switched off in
// case a stub were ever bypassed.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const script = join(dirname(fileURLToPath(import.meta.url)), "..", "deploy-aws.sh");

const HEALTHY = JSON.stringify({
  ok: true, transcription: true, summary: true, classify: true, playground: true, metering: true,
});
const SCOPED_POLICY = JSON.stringify({ Statement: [{
  Sid: "FunctionURLInvokeAllowPublicAccess",
  Action: "lambda:InvokeFunction",
  Condition: { Bool: { "lambda:InvokedViaFunctionUrl": "true" } },
}] });

const AWS_STUB = `#!/bin/bash
echo "aws $*" >> "$STUB_LOG"
case "$1 $2" in
  "sts get-caller-identity") echo 123456789012 ;;
  "dynamodb describe-time-to-live") echo ENABLED ;;
  "iam get-role") echo arn:aws:iam::123456789012:role/deiko-relay-role ;;
  "lambda get-function") [ -n "$STUB_EXISTS" ] || exit 254 ;;
  "lambda get-function-configuration") echo "$STUB_LIVE_NAMES" ;;
  "lambda get-function-url-config") echo https://stub.lambda-url.ap-south-1.on.aws/ ;;
  "lambda get-policy") [ -n "$STUB_POLICY" ] && echo "$STUB_POLICY" || exit 254 ;;
esac
exit 0
`;

/// Run the deploy with `env` on top of a complete, valid configuration.
function deploy(env = {}) {
  const dir = mkdtempSync(join(tmpdir(), "deiko-deploy-"));
  const bin = join(dir, "bin");
  const log = join(dir, "calls.log");
  writeFileSync(log, "");
  spawnSync("mkdir", [bin]);
  const stubs = {
    aws: AWS_STUB,
    curl: `#!/bin/bash\necho "curl $*" >> "$STUB_LOG"\nprintf '%s' "$STUB_HEALTH"\n`,
    npm: `#!/bin/bash\necho "npm $* lock:$([ -f package-lock.json ] && echo yes || echo no)" >> "$STUB_LOG"\n`,
    sleep: "#!/bin/bash\nexit 0\n",
  };
  for (const [name, body] of Object.entries(stubs)) {
    writeFileSync(join(bin, name), body);
    chmodSync(join(bin, name), 0o755);
  }
  const run = spawnSync("bash", [script], {
    encoding: "utf8",
    env: {
      // Stubs FIRST, so `aws` can only ever resolve to the fake one.
      PATH: `${bin}:${dirname(process.execPath)}:/usr/bin:/bin`,
      HOME: dir,
      TMPDIR: dir,
      STUB_LOG: log,
      STUB_EXISTS: "1",
      STUB_HEALTH: HEALTHY,
      AWS_CONFIG_FILE: "/dev/null",
      AWS_SHARED_CREDENTIALS_FILE: "/dev/null",
      AWS_EC2_METADATA_DISABLED: "true",
      GROQ_API_KEY: "placeholder-groq",
      TYPESAFE_API_KEY: "placeholder-typesafe",
      DEIKO_PLAYGROUND_SECRET: "placeholder-secret",
      ...env,
    },
  });
  const calls = readFileSync(log, "utf8").split("\n").filter(Boolean);
  rmSync(dir, { recursive: true, force: true });
  return { status: run.status, out: run.stdout + run.stderr, calls };
}

const index = (calls, pattern) => calls.findIndex((c) => pattern.test(c));

test("only the function URL can invoke the function: the public direct-invoke grant is removed", () => {
  const { status, calls, out } = deploy();
  assert.equal(status, 0, out);
  assert.ok(calls.some((c) => c.startsWith("aws sts")), "the fake aws answered, not a real one");
  const scoped = index(calls, /add-permission .*--statement-id FunctionURLInvokeAllowPublicAccess --action lambda:InvokeFunction --principal \* --invoked-via-function-url/);
  const dropped = index(calls, /remove-permission .*--statement-id AllowPublicInvoke/);
  assert.ok(scoped >= 0, "InvokeFunction is granted only via the URL");
  assert.ok(dropped > scoped, "and the unconditioned grant goes only once its replacement is in place");
  assert.equal(index(calls, /add-permission .*AllowPublicInvoke/), -1, "and is never granted again");
});

test("a grant already scoped to the URL is left alone, so the URL never blinks", () => {
  const { status, calls } = deploy({ STUB_POLICY: SCOPED_POLICY });
  assert.equal(status, 0);
  assert.equal(index(calls, /-permission .*FunctionURLInvokeAllowPublicAccess/), -1);
  assert.ok(index(calls, /remove-permission .*AllowPublicInvoke/) >= 0);
});

test("a deploy that would drop a live setting stops before changing anything", () => {
  const { status, calls, out } = deploy({ STUB_LIVE_NAMES: "GROQ_API_KEY\tDEIKO_REVOKED_TOKENS\tTYPESAFE_API_KEY" });
  assert.equal(status, 1);
  assert.match(out, /would remove settings the live relay has: DEIKO_REVOKED_TOKENS/);
  assert.equal(index(calls, /update-function-(code|configuration)/), -1, "nothing was changed");
  assert.doesNotMatch(out, /placeholder-/, "and no value was printed, only names");

  const allowed = deploy({ STUB_LIVE_NAMES: "DEIKO_REVOKED_TOKENS", DEIKO_ALLOW_ENV_DROP: "1" });
  assert.equal(allowed.status, 0, "dropping one on purpose is still possible");
});

test("every route must report configured, or the deploy fails", () => {
  for (const flag of ["classify", "playground", "metering", "transcription"]) {
    const health = JSON.stringify({ ...JSON.parse(HEALTHY), [flag]: false });
    const { status, out } = deploy({ STUB_HEALTH: health });
    assert.equal(status, 1, `${flag}:false must fail the deploy`);
    assert.match(out, new RegExp(`${flag}:false`));
  }
  assert.equal(deploy({ STUB_HEALTH: "" }).status, 1, "no answer at all fails it too");
});

test("a missing classifier key or playground secret is refused before anything is touched", () => {
  for (const unset of [{ TYPESAFE_API_KEY: "" }, { DEIKO_PLAYGROUND_SECRET: "" }]) {
    const { status, calls } = deploy(unset);
    assert.equal(status, 1, `${Object.keys(unset)[0]} is required`);
    assert.equal(index(calls, /aws (lambda|dynamodb|iam)/), -1);
  }
  const viaCloudflare = deploy({ TYPESAFE_API_KEY: "", CLOUDFLARE_ACCOUNT_ID: "a", CLOUDFLARE_AI_TOKEN: "b" });
  assert.equal(viaCloudflare.status, 0, "any one classifier will do");
});

test("the SDK comes from the lockfile, and the log group exists before its retention is set", () => {
  const { status, calls } = deploy();
  assert.equal(status, 0);
  assert.ok(calls.some((c) => /^npm ci --omit=dev --ignore-scripts .* lock:yes$/.test(c)), "npm ci against the lockfile");
  const created = index(calls, /logs create-log-group/);
  assert.ok(created >= 0 && created < index(calls, /logs put-retention-policy/));
});

test("localhost in the playground origins is called out before launch", () => {
  const { out } = deploy({ DEIKO_PLAYGROUND_ORIGINS: "https://deiko.app,localhost" });
  assert.match(out, /still allows localhost/);
});
