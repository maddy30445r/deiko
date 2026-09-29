# The Deiko relay

So that a new user transcribes without holding an account anywhere. The app
posts narration audio here; this forwards it to Groq with **your** key and
returns the text. Same for the orb's summary, via Groq.

**This is not deployed by the repo.** Hosting, the domain and the provider keys
are live infrastructure and yours to run.

## Run it locally

```sh
GROQ_API_KEY=… node services/relay/src/server.mjs
# → deiko relay on :8787
```

Point the app at it — this overrides the built-in default, so nothing needs
rebuilding:

```sh
DEIKO_RELAY_URL=http://localhost:8787 open build/Deiko.app
```

Then record a session **with no Groq key in Settings** and confirm it
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
GROQ_API_KEY=… TYPESAFE_API_KEY=… DEIKO_PLAYGROUND_SECRET=… make relay-deploy
```

`deploy.sh` creates or updates the function, its role, its URL and its
concurrency cap using only the AWS CLI — no SAM, CDK or Terraform. It is
idempotent, so the same command ships a code change.

It **refuses** rather than ship a relay missing a route: the Groq key, a
classifier key (or the Cloudflare pair) and the playground secret are all
required, a deploy that would remove a setting the live function has stops
before changing anything (`DEIKO_ALLOW_ENV_DROP=1` to drop one on purpose), and
`/health` must report every route configured afterwards. The function URL is the
only way in: `lambda:InvokeFunction` is granted only with
`lambda:InvokedViaFunctionUrl`, so nobody can invoke it directly with a forged
source address — and the deploy re-reads the policy afterwards and fails if any
statement still lets `*` invoke it another way (the deployer needs
`lambda:GetPolicy`). The DynamoDB SDK is installed with `npm ci` from this
directory's `package-lock.json`, at the versions the tests run against.

**Lambda specifically because this service is idle most of the day by design** —
nobody is recording — and it is the only option that costs *nothing* while
idle. A container platform bills for provisioned memory whether or not anyone
is talking. The 6MB request cap is far above what a chunk actually weighs:
`transcribe.mjs` splits audio at 25 seconds, which is 0.76MB of 16kHz mono.

Knobs, all overridable in the environment:

| | |
|---|---|
| `AWS_REGION` | `ap-south-1` — closest to the people using it |
| `DEIKO_LAMBDA_CONCURRENCY` | `5` reserved — a blast radius, not a quota. Past ~12, raise the table's write units with it. |
| `DEIKO_REVOKED_TOKENS` | comma-separated tokens to refuse |
| `DEIKO_USAGE_TABLE` | `deiko-usage` — the DynamoDB table holding every counter |
| `DEIKO_GLOBAL_DAILY_SECONDS` | `43200` (12 hours) — the ceiling on the whole service's daily audio |
| `DEIKO_SUMMARIES_PER_DAY` | `2000` — summaries served in a day, counted in their own row so a flood cannot close transcription |
| `DEIKO_SUMMARIES_PER_CALLER_PER_DAY` / `DEIKO_CLASSIFIES_PER_CALLER_PER_DAY` | `200` each — one install's share of those days |
| `DEIKO_TEXT_CALLS_PER_IP_PER_DAY` | `400` — one address's (IPv6: one /64's) share, per text route, so rotating bearers resets nothing |
| `DEIKO_PRO_BENEFIT_IDS` | Polar benefit ids that mean Pro. Unset = any live licence is Pro — correct while Pro is the only paid benefit; the day there is a second one this MUST be set, or the cheaper SKU buys Pro's allowance. |
| `POLAR_API_BASE` | `https://sandbox-api.polar.sh` to validate against Polar's sandbox. Unset = production. |

The deploy checks this for you; by hand, check every flag, not just `ok`:

```sh
curl -s https://<id>.lambda-url.<region>.on.aws/health
# {"ok":true,"transcription":true,"summary":true,"classify":true,"playground":true,"metering":true}
```

`metering` is a real `DescribeTable`, not a check on whether the table's name is
configured — the name has a default, so the cheap version reports healthy on
precisely the deploy where the table is missing or the role has no policy. It
is asked at most once a minute per container, so an anonymous loop on `/health`
cannot spend the account's control-plane rate.
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
| `GROQ_API_KEY` | required — it spends BOTH `/v1/transcribe` and `/v1/summarize` |
| `GROQ_API_KEY` | required for `/v1/summarize` |
| `PORT` | default 8787 |
| `DEIKO_REVOKED_TOKENS` | comma-separated tokens to refuse |
| `DEIKO_USAGE_TABLE` | `deiko-usage` — the DynamoDB table holding every counter |
| `DEIKO_GLOBAL_DAILY_SECONDS` | `43200` (12 hours) — the ceiling on the whole service's daily audio |
| `DEIKO_SUMMARIES_PER_DAY` | `2000` — summaries served in a day, counted in their own row so a flood cannot close transcription |
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
  and a 12-character fingerprint of the token — never the token, never a word
  of what was said.
- **No raw screen content, ever.** Crops, OCR, screen text and screenshots
  never leave the user's Mac. `/v1/classify` accepts window and page titles
  and the labels read from them — pages, sites, web addresses (host and path
  only, never the part after "?"), files, repo, docs, tickets — plus
  open-document names; every other endpoint still takes narration alone.

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

## The client and the relay ship together

**The upload is parsed and rebuilt, and only what the app sends survives.** `/v1/transcribe` accepts
exactly `sttForm`'s fields — one `file`, `model=whisper-large-v3`, `response_format`, and for "Same as
I speak" `timestamp_granularities[]` and `language` — and refuses anything else with a 400 before a
second is counted. It used to forward the body verbatim, which let a caller add Groq's `url` field
(Groq then fetches audio of any length itself, off the meter) or a billed `prompt`. The file must be
the app's own WAV — PCM, 16 kHz, mono, 16-bit, at most 40 seconds — which pins bytes to seconds, so
the meter reads the audio's real duration. The audio's bytes are forwarded untouched; only the
envelope is rebuilt.

The playground's clip is rebuilt the same way: its bytes travel as the only file in a body the relay
builds, beside the pinned model, under a filename and type the relay picks from the clip's first
bytes (WebM, Ogg, MP4 or WAV — anything else is a 400). Nothing the page sends can name a `url`.

`/v1/summarize` takes `{ narration, mode: "hinglish" | "native" }` and holds the two system prompts
itself (mirrored from `packages/core/src/summarize.mjs`, and a test keeps them word for word). A body in the
old `{ messages }` shape still gets a summary — its transcript is taken, its system turn is not.

The two halves are still version-coupled: a relay that expects different fields refuses every app
built before it. A 400-class answer from the provider about the caller's audio stays **billed** —
that rule exists so junk bodies cannot probe the upstream off the meter — so an old install on a
mismatched relay burns its trial a chunk at a time. Every other provider failure (a 401 from a
rotated key, a 429, a 5xx, a dropped response) is refunded, and the caller only ever sees a fixed
502: the provider's status and body stay in CloudWatch.

So: **cut a release whenever the upstream changes**, and treat `make relay-deploy` followed by
`make release` as one operation rather than two.

## What actually bounds the spend

In order, cheapest first:

1. **The burst limiter** — in memory, 30 requests a minute, per warm container.
   Catches a client stuck in a loop before it costs a database write. It is not
   a quota and does not pretend to be; on Lambda a determined caller gets a
   fresh container and a fresh counter.
2. **Per-subject quota** — DynamoDB, counted in audio seconds. A free install
   gets 30 minutes *once*; a Pro licence gets 10 hours a month. Incremented and
   then judged, in one round trip, so concurrent chunks cannot both claim room
   only one of them has — and **both rows or neither**: a subject write that
   fails while the global one lands is compensated before the error surfaces.
   **No request meters below 5 seconds** (`MIN_SECONDS_PER_REQUEST`), and the
   audio must be 16 kHz mono 16-bit PCM WAV of at most 40 seconds, so its
   length is its duration — a caller sending 8 kbps MP3 used to buy thirty
   seconds of Groq for one.
   **The id after the prefix is `[A-Za-z0-9_-]{1,128}`** — it is interpolated
   into row keys, and `lic_<key>#2026-09` used to spell a paying customer's
   monthly usage row as a verdict row that `PutItem` then replaced.
3. **The global daily ceiling** — the one that does not depend on honest
   clients. Per-subject limits are *harder* to forge than they were, not
   impossible: the identifier is derived from the machine rather than stored in
   preferences, so `defaults delete` no longer buys a trial — but a VM, a
   borrowed Mac, or anyone willing to patch the client still can. The ceiling
   caps the whole service's audio for a day no matter how many subjects exist.
   Twelve hours is about $1.33 a day at Groq's rate, and free callers reach only half of it.
4. **A separate summary budget** — `DEIKO_SUMMARIES_PER_DAY`, and the
   classifier's — `DEIKO_CLASSIFIES_PER_DAY`. Both routes accept any bearer
   string, and the burst limiter is keyed by token, so a caller rotating
   tokens is not limited by it. Their own rows mean a flood of cheap text
   calls cannot close the expensive route, and **per-caller rows in front of
   them** — per bearer, and per hashed address — mean one script cannot spend
   the whole day's text calls for everybody.
   **A row found over its cap is remembered** for a minute in that container,
   so refusals stop costing a write and a refund each — a stream of them no
   longer throttles the table under paying requests. A minute, not the day,
   because a counter can read full for an instant while refused requests are
   still being refunded. A licence key not shaped like Polar's (a prefix and a
   UUID) is refused without a Polar call or a write at all, and logged by its
   `tok:` fingerprint so a real key of another shape is visible.
5. **Reserved concurrency** — 5 by intent. **Not applied on a default account:**
   AWS's per-account limit is 10 and it keeps 10 unreserved, so the deploy warns
   and the account-wide cap applies instead. Ask AWS to raise the quota.
6. **The revocation list, and the AWS budget alarm.** The alarm should fire long
   before the ceiling does: the ceiling stops a disaster, the alarm tells you
   one is starting.

**Being over by one chunk is fine and deliberate.** The counter is incremented
before the audio is bought, so an upstream failure still counts. Twenty-five
seconds of Whisper is about ₹0.06; a race that lets a cap be exceeded by however
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
  --environment "Variables={DEIKO_GLOBAL_DAILY_SECONDS=0,GROQ_API_KEY=…}"
```

`DEIKO_GLOBAL_DAILY_SECONDS=0` means the day's ceiling is already exceeded by
the first request, so **every** transcription is refused with a 429 — yours
included. Nothing breaks: the app falls back to Apple's on-device words, which
is the documented third path and costs nothing. Undo it by setting the value
back to `43200`, or by re-running `make relay-deploy`.

**The environment is replaced wholesale, not merged** — send the provider keys
in the same call or the relay comes back up with none and 503s everything.
`make relay-deploy` is the safer form of the same thing if you have the keys to
hand.

To stop **one** abuser rather than everybody, take the `tok:` fingerprint from
the CloudWatch line and put it in `DEIKO_REVOKED_TOKENS` — that is the same
string in both places, by design.

## The privacy promise changes when you turn this on

Without a relay: narration audio goes to Groq, and to nobody else.

With one: narration audio goes to **Deiko's server**, which forwards it and
keeps nothing. That is a materially different claim, and the app must say so
where people read it before they start — Settings says it next to the Groq
field that opts out of it, and a user with their own key never touches this
service at all.
