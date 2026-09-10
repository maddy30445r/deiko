# The Deiko relay

So that a new user transcribes without holding an account anywhere. The app
posts narration audio here; this forwards it to Sarvam with **your** key and
returns the text. Same for the orb's summary, via Groq.

**This is not deployed by the repo.** Hosting, the domain and the provider keys
are live infrastructure and yours to run.

## Run it locally

```sh
SARVAM_API_KEY=… GROQ_API_KEY=… node services/relay/server.mjs
# → deiko relay on :8787
```

Point the app at it — this overrides the built-in default, so nothing needs
rebuilding:

```sh
DEIKO_RELAY_URL=http://localhost:8787 open build/Deiko.app
```

Then record a session **with no Sarvam key in Settings** and confirm it
transcribes. Kill the relay mid-session and confirm you still get a brief, from
on-device words.

## Shape

Five files, because the same logic has to run in two places and because the
decisions worth testing should not need a database to run:

| | |
|---|---|
| `relay.mjs` | routing, auth, proxying, and the order everything happens in. Knows nothing about a transport. |
| `quota.mjs` | **pure.** Tiers, caps, storage keys, and the allow/refuse decision. No network, no database. |
| `usage.mjs` | the numbers — DynamoDB counters and the cached Polar verdict |
| `lambda.mjs` | the AWS entry point |
| `server.mjs` | a `node:http` entry point, for local testing and containers |

The split between `quota.mjs` and `usage.mjs` is the same one the Swift package
makes: the arithmetic that decides whether somebody gets transcribed is checked
by `npm test` in milliseconds, with no AWS account involved.

What you `curl` on localhost is therefore the same code that runs in
production, which is the point: a bug found locally is a bug fixed everywhere.

## Deploying — AWS Lambda

```sh
SARVAM_API_KEY=… GROQ_API_KEY=… make relay-deploy
```

`deploy-aws.sh` creates or updates the function, its role, its URL and its
concurrency cap using only the AWS CLI — no SAM, CDK or Terraform. It is
idempotent, so the same command ships a code change.

**Lambda specifically because this service is idle most of the day by design** —
nobody is recording — and it is the only option that costs *nothing* while
idle. A container platform bills for provisioned memory whether or not anyone
is talking. The 6MB request cap is far above what a chunk actually weighs:
`transcribe.mjs` splits audio at 25 seconds, which is 0.76MB of 16kHz mono.

Knobs, all overridable in the environment:

| | |
|---|---|
| `AWS_REGION` | `ap-south-1` — closest to Sarvam |
| `DEIKO_LAMBDA_CONCURRENCY` | `5` reserved — a blast radius, not a quota. Past ~12, raise the table's write units with it. |
| `DEIKO_REVOKED_TOKENS` | comma-separated tokens to refuse |
| `DEIKO_USAGE_TABLE` | `deiko-usage` — the DynamoDB table holding every counter |
| `DEIKO_GLOBAL_DAILY_SECONDS` | `14400` (4 hours) — the ceiling on the whole service's daily audio |
| `DEIKO_PRO_BENEFIT_IDS` | Polar benefit ids that mean Pro. Unset = any live licence is Pro — correct while Pro is the only paid benefit; the day there is a second one this MUST be set, or the cheaper SKU buys Pro's allowance. |
| `POLAR_API_BASE` | `https://sandbox-api.polar.sh` to validate against Polar's sandbox. Unset = production. |

Then verify — and check `transcription`, not just `ok`:

```sh
curl -s https://<id>.lambda-url.<region>.on.aws/health
# {"ok":true,"transcription":true,"summary":true,"metering":true,"table":"deiko-usage"}
```

`metering` is a real `DescribeTable`, not a check on whether the table's name is
configured — the name has a default, so the cheap version reports healthy on
precisely the deploy where the table is missing or the role has no policy.
**A relay answering `"metering":false` will 503 every transcription**, on
purpose: not knowing what anybody has spent should stop the buying.

A relay with no key answers `ok` happily and then 503s every real request.

## Deploying — anywhere else

`server.mjs` is the same `relay.mjs` behind a port, so any host that runs Node
and can reach DynamoDB will serve it. There is no container recipe in the tree
any more: a `Dockerfile` and a `fly.toml` lived here for a long time and
**neither had ever worked** — the image copied `relay.mjs` and `server.mjs`
without `quota.mjs`, `usage.mjs` or the AWS SDK they import, so it died on its
first request. A second deploy path that nobody exercises is a trap rather than
an option, and Lambda is the one that is actually deployed.

| Variable | |
|---|---|
| `SARVAM_API_KEY` | required for `/v1/transcribe` |
| `GROQ_API_KEY` | required for `/v1/summarize` |
| `PORT` | default 8787 |
| `DEIKO_REVOKED_TOKENS` | comma-separated tokens to refuse |
| `DEIKO_USAGE_TABLE` | `deiko-usage` — the DynamoDB table holding every counter |
| `DEIKO_GLOBAL_DAILY_SECONDS` | `14400` (4 hours) — the ceiling on the whole service's daily audio |
| `DEIKO_PRO_BENEFIT_IDS` | Polar benefit ids that mean Pro. Unset = any live licence is Pro — correct while Pro is the only paid benefit; the day there is a second one this MUST be set, or the cheaper SKU buys Pro's allowance. |
| `POLAR_API_BASE` | `https://sandbox-api.polar.sh` to validate against Polar's sandbox. Unset = production. |

Then point a build at it — **not by editing Swift.** The origin is deployment
configuration, stamped into the bundle's `Info.plist`:

```sh
make install RELAY_URL=https://<id>.lambda-url.<region>.on.aws
```

`Credentials.relayURL` reads the `DeikoRelayURL` key back out, and it is empty
until a build stamps it — deliberately, because a relay that fails on every
session is worse than no relay: the on-device fallback is silent and the failure
is not. This used to say "set `defaultRelayURL` in `Credentials.swift`", which
has not been a source constant since it moved to the plist; anyone following it
edited a file that changes nothing and shipped a build with no relay.

## What this service must never do

Three promises, arranged in the code so that breaking one takes an edit rather
than an oversight:

- **No audio or transcripts on disk.** Bodies are read into memory and
  forwarded; there is no upload directory to forget to clean.
- **No content in logs.** A line is a timestamp, method, path, status, duration
  and the first eight characters of a token. Never a word of what was said.
- **Nothing but narration ever arrives.** Crops, OCR, window titles and
  accessibility text never leave the user's Mac, and no endpoint here accepts
  them.

## What the token is, and is not

An opaque per-MACHINE identifier: `SHA256(salt + IOPlatformUUID)`, truncated,
computed fresh on every launch. It lets you meter a free trial, rate-limit, and
revoke one abusive install without stopping everybody.

**It is derived from the hardware, and that is a deliberate trade worth stating
plainly.** It used to be a random UUID in the app's preferences, which meant one
`defaults delete` bought another thirty free minutes, and so did a second macOS
login on the same Mac. Deriving from the machine closes both — at the cost of a
*more* identifying id than a random one, on a product sold on privacy. What
keeps that honest:

- the raw `IOPlatformUUID` is **never stored, never written to disk, and never
  sent** — only the digest leaves the function that computes it;
- it is **salted**, so the digest cannot be lined up against another product
  that fingerprints the same Mac. The salt ships inside the app, so this
  defeats correlation by a third party, **not by us** — claiming otherwise
  would be theatre;
- it identifies a **machine, not a person**. No account, no email, nothing here
  that says who you are.

Consequences to know: the identifier now **survives reinstalls and OS updates**,
and two macOS logins on one Mac share one trial. A Mac that cannot answer (a VM,
say) falls back to the old random-id-in-preferences path, so it gets a trial
rather than an error.

**Deliberately not in the keychain.** The stored fallback lives in preferences
because it used to live in the keychain, and that cost every user a
login-password prompt on their first session after every app update: a keychain
read decrypts, decryption is checked against an ACL pinned to one exact binary,
and an update always changes the binary. Since this is an identifier rather than
a secret — anyone holding the app can read it out either way — the keychain was
buying nothing and charging a prompt.

**It is not authentication.** A token that ships inside a client can be read
out of it by anyone who wants to. Real per-user identity means accounts — a
product decision, not a line of code.

**A licence key is not authentication either**, and is not pretending to be.
It is the same kind of bearer: something the client holds that says which tier
to meter against. What makes it worth more than a device token is that Polar
can say whether it is still paid for.

**The prefix is what tells them apart.** `lic_…` is a licence, `dev_…` is a
device token, and a bare value is a device token because that is what every
build up to 0.3.0 sends. This matters more than it looks: both are v4-shaped
UUIDs, so without the prefix the two are indistinguishable — every free user's
token would be sent to Polar for validation and every licence would
meter as a free trial.

## What actually bounds the spend

In order, cheapest first:

1. **The burst limiter** — in memory, 30 requests a minute, per warm container.
   Catches a client stuck in a loop before it costs a database write. It is not
   a quota and does not pretend to be; on Lambda a determined caller gets a
   fresh container and a fresh counter.
2. **Per-subject quota** — DynamoDB, counted in audio seconds. A free install
   gets 30 minutes *once*; a Pro licence gets 5 hours a month. Incremented and
   then judged, in one round trip, so concurrent chunks cannot both claim room
   only one of them has.
3. **The global daily ceiling** — the one that does not depend on honest
   clients. Per-subject limits are *harder* to forge than they were, not
   impossible: the identifier is derived from the machine rather than stored in
   preferences, so `defaults delete` no longer buys a trial — but a VM, a
   borrowed Mac, or anyone willing to patch the client still can. The ceiling
   caps the whole service's audio for a day no matter how many subjects exist.
   Four hours is ₹120/day.
4. **Reserved concurrency** — 5 by default. A blast radius, not a quota.
5. **The revocation list, and the AWS budget alarm.** The alarm should fire long
   before the ceiling does: the ceiling stops a disaster, the alarm tells you
   one is starting.

**Being over by one chunk is fine and deliberate.** The counter is incremented
before the audio is bought, so an upstream failure still counts. Twenty-five
seconds of Sarvam is about ₹0.2; a race that lets a cap be exceeded by however
many containers happen to be warm is not.

**If the table cannot be reached, transcription 503s.** Failing closed is the
whole point — not knowing what somebody has spent is a reason to stop buying,
not to buy an unbounded amount and find out at the end of the month. The app
keeps working on Apple's on-device words.

## STOP THE BILL

The one command, for when the alarm fires at three in the morning and you want
the spending to stop before you understand why:

```sh
aws lambda update-function-configuration \
  --function-name deiko-relay --region ap-south-1 \
  --environment "Variables={DEIKO_GLOBAL_DAILY_SECONDS=0,SARVAM_API_KEY=…,GROQ_API_KEY=…}"
```

`DEIKO_GLOBAL_DAILY_SECONDS=0` means the day's ceiling is already exceeded by
the first request, so **every** transcription is refused with a 429 — yours
included. Nothing breaks: the app falls back to Apple's on-device words, which
is the documented third path and costs nothing. Undo it by setting the value
back to `14400`, or by re-running `make relay-deploy`.

**The environment is replaced wholesale, not merged** — send the provider keys
in the same call or the relay comes back up with none and 503s everything.
`make relay-deploy` is the safer form of the same thing if you have the keys to
hand.

To stop **one** abuser rather than everybody, take the `tok:` fingerprint from
the CloudWatch line and put it in `DEIKO_REVOKED_TOKENS` — that is the same
string in both places, by design.

## The privacy promise changes when you turn this on

Without a relay: narration audio goes to Sarvam, and to nobody else.

With one: narration audio goes to **Deiko's server**, which forwards it and
keeps nothing. That is a materially different claim, and the app must say so
where people read it before they start — Settings says it next to the Sarvam
field that opts out of it, and a user with their own key never touches this
service at all.
