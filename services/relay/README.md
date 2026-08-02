# The Fovea relay

So that a new user transcribes without holding an account anywhere. The app
posts narration audio here; this forwards it to Sarvam with **your** key and
returns the text. Same for the orb's summary, via Groq.

**This is not deployed by the repo.** Hosting, the domain and the provider keys
are live infrastructure and yours to run.

## Run it locally

```sh
SARVAM_API_KEY=… GROQ_API_KEY=… node services/relay/server.mjs
# → fovea relay on :8787
```

Point the app at it — this overrides the built-in default, so nothing needs
rebuilding:

```sh
FOVEA_RELAY_URL=http://localhost:8787 open build/Fovea.app
```

Then record a session **with no Sarvam key in Settings** and confirm it
transcribes. Kill the relay mid-session and confirm you still get a brief, from
on-device words.

## Shape

Three files, because the same logic has to run in two places:

| | |
|---|---|
| `relay.mjs` | every decision — routing, auth, rate limit, proxying. Knows nothing about a transport. |
| `lambda.mjs` | the AWS entry point |
| `server.mjs` | a `node:http` entry point, for local testing and containers |

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
| `FOVEA_LAMBDA_CONCURRENCY` | `5` reserved — a blast radius, not a quota |
| `FOVEA_REVOKED_TOKENS` | comma-separated device tokens to refuse |

Then verify — and check `transcription`, not just `ok`:

```sh
curl -s https://<id>.lambda-url.<region>.on.aws/health
# {"ok":true,"transcription":true,"summary":true}
```

A relay with no key answers `ok` happily and then 503s every real request.

## Deploying — anywhere else

`Dockerfile` and `fly.toml` are still here and still work:
`docker build . && docker run -e SARVAM_API_KEY=… -p 8787:8787`, or
`fly launch --no-deploy && fly secrets set … && fly deploy`. Both run
`server.mjs`, which is the same `relay.mjs` behind a port.

| Variable | |
|---|---|
| `SARVAM_API_KEY` | required for `/v1/transcribe` |
| `GROQ_API_KEY` | required for `/v1/summarize` |
| `PORT` | default 8787 |
| `FOVEA_REVOKED_TOKENS` | comma-separated device tokens to refuse |

Then set `defaultRelayURL` in `apps/capture/Sources/FoveaCapture/Credentials.swift`
to the deployed origin. It is `nil` until you do — deliberately, because a relay
that fails on every session is worse than no relay: the on-device fallback is
silent and the failure is not.

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

An opaque per-install identifier, minted on first use and kept in the app's
preferences. It lets you rate-limit and revoke one abusive install without
stopping everybody.

**Deliberately not in the keychain.** It used to be, and that cost every user a
login-password prompt on their first session after every app update: a keychain
read decrypts, decryption is checked against an ACL pinned to one exact binary,
and an update always changes the binary. Since this is a random identifier
rather than a secret — anyone holding the app can read it out either way —
the keychain was buying nothing and charging a prompt. A user who updates now
simply gets a new token, which is indistinguishable from a new install.

**It is not authentication.** A token that ships inside a client can be read
out of it by anyone who wants to. Real per-user identity means accounts — a
product decision, not a line of code. Until then the mitigations are the rate
limit, the revocation list, and watching your provider bill.

**The rate limit is weaker on Lambda than it looks**, and that is worth saying
plainly rather than leaving you to assume you are covered. It counts in memory,
so on Lambda it is per warm container: a determined caller gets a fresh
container and a fresh counter. It catches a client stuck in a loop and nothing
more.

What actually bounds your spend is **reserved concurrency** (5 by default — at
most five transcriptions in flight at once), the revocation list, and watching
the Sarvam dashboard in the first week. A real quota means a shared store —
DynamoDB with a TTL would do it for pennies — and is worth adding the moment
this serves anybody outside the team.

## The privacy promise changes when you turn this on

Without a relay: narration audio goes to Sarvam, and to nobody else.

With one: narration audio goes to **Fovea's server**, which forwards it and
keeps nothing. That is a materially different claim, and the app must say so
where people read it before they start — Settings says it next to the Sarvam
field that opts out of it, and a user with their own key never touches this
service at all.
