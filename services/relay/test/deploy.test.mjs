// Runs `deploy.sh` against a fake AWS: `aws`, `curl`, `npm` and `sleep` are
// stubs on PATH that log what they were asked and answer from the test's script,
// so the script's logic (who may invoke the function, what the environment
// becomes, what counts as healthy) runs with no account, network or keys. The
// environment is built from nothing, and AWS's credential lookups are switched
// off in case a stub is ever bypassed.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const script = join(dirname(fileURLToPath(import.meta.url)), "..", "deploy.sh");

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
  "lambda get-policy")
    if [ -n "$STUB_POLICY_DENIED" ]; then
      echo "An error occurred (AccessDeniedException) when calling the GetPolicy operation: User: arn:aws:iam::123456789012:user/deployer is not authorized to perform: lambda:GetPolicy" >&2
      exit 254
    fi
    if [ -z "$STUB_POLICY" ]; then
      echo "An error occurred (ResourceNotFoundException) when calling the GetPolicy operation: The resource you requested does not exist." >&2
      exit 254
    fi
    echo "$STUB_POLICY" ;;
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
      // Stubs first, so `aws` can only resolve to the fake one.
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

test("a deployer who may not read the policy is told so, and no grant is touched", () => {
  const { status, calls, out } = deploy({ STUB_POLICY_DENIED: "1" });
  assert.equal(status, 1);
  assert.match(out, /needs lambda:GetPolicy/);
  assert.equal(index(calls, /-permission .*(FunctionURLInvokeAllowPublicAccess|AllowPublicInvoke)/), -1,
    "neither re-added every deploy (a 403 blink) nor removed blind");
});

test("the deploy fails if anybody can still invoke the function past its URL", () => {
  const withOpen = (statement) => JSON.stringify({
    Statement: [...JSON.parse(SCOPED_POLICY).Statement, { Effect: "Allow", ...statement }],
  });
  for (const [what, statement] of [
    ["an old grant that would not go", { Sid: "AllowPublicInvoke", Principal: "*", Action: "lambda:InvokeFunction" }],
    ["a wildcard action", { Sid: "Everything", Principal: "*", Action: "lambda:*" }],
    ["a wildcard in a list, for AWS:*", { Sid: "Sneaky", Principal: { AWS: "*" }, Action: ["s3:GetObject", "lambda:Invoke*"] }],
  ]) {
    const { status, out } = deploy({ STUB_POLICY: withOpen(statement) });
    assert.equal(status, 1, `${what} must fail the deploy`);
    assert.match(out, new RegExp(`past its URL: ${statement.Sid}`));
  }
  const urlOnly = withOpen({ Sid: "FunctionURLAllowPublicAccess", Principal: "*", Action: "lambda:InvokeFunctionUrl" });
  assert.equal(deploy({ STUB_POLICY: urlOnly }).status, 0, "the URL's own grant is not an open door");
});
