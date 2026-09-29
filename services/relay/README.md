# Deiko relay

A small HTTP service that lets the app transcribe, summarise and file briefs
without the user holding any API keys. It forwards requests to the model
providers with the operator's keys, meters free usage per install, and keeps
nothing.

| Route | Upstream | Purpose |
|---|---|---|
| `POST /v1/transcribe` | Groq, `whisper-large-v3` | Narration audio → text |
| `POST /v1/summarize` | Groq, `openai/gpt-oss-20b` | Transcript → a short summary |
| `POST /v1/classify` | Jev via OpenRouter (or TypeSafe directly) | Which task a brief belongs to |
| `GET /v1/quota` | — | The caller's remaining allowance |
| `GET /health` | — | Which routes are configured |

The `/v1/playground/*` routes serve the demo on deiko.app.

## Layout

| File | Role |
|---|---|
| `src/relay.mjs` | Routing, auth, request validation and proxying; transport-agnostic |
| `src/quota.mjs` | Pure tier, cap and allow/refuse logic, tested without a database |
| `src/usage.mjs` | DynamoDB counters and cached licence checks (Polar) |
| `src/lambda.mjs` | AWS Lambda entry point |
| `src/server.mjs` | `node:http` entry point for local runs and containers |
| `src/local.mjs` | `server.mjs` with in-memory metering, for development |

## Run it locally

```sh
make relay-dev                                   # reads .env; http://localhost:8787
DEIKO_RELAY_URL=http://localhost:8787 open build/Deiko.app
```

## Deploy to AWS Lambda

```sh
make relay-deploy        # keys from .env
```

`deploy.sh` uses only the AWS CLI and is idempotent. It creates or updates the
function, its role, its function URL and the DynamoDB usage table. It refuses
to deploy without the Groq key, a classifier key and the playground secret,
refuses to drop a setting the live function has (`DEIKO_ALLOW_ENV_DROP=1` to
do so on purpose), allows invocation only through the function URL, and checks
`/health` afterwards.

```sh
curl -s https://<id>.lambda-url.<region>.on.aws/health
# {"ok":true,"transcription":true,"summary":true,"classify":true,"playground":true,"metering":true}
```

Point a build at it with `make install RELAY_URL=https://…`; the URL is stamped
into the app's `Info.plist`.

## Configuration

| Variable | Default | |
|---|---|---|
| `GROQ_API_KEY` | — | Required for transcription and summaries |
| `OPENROUTER_API_KEY` or `TYPESAFE_API_KEY` | — | Required for filing |
| `DEIKO_PLAYGROUND_SECRET` | — | Signs the site demo's tickets |
| `AWS_REGION` | `ap-south-1` | |
| `DEIKO_USAGE_TABLE` | `deiko-usage` | DynamoDB table for all counters |
| `DEIKO_LAMBDA_CONCURRENCY` | `5` | Reserved concurrency |
| `DEIKO_GLOBAL_DAILY_SECONDS` | `43200` | Ceiling on the whole service's audio per day |
| `DEIKO_SUMMARIES_PER_DAY` | `2000` | Daily summary budget |
| `DEIKO_CLASSIFIES_PER_DAY` | `1000` | Daily filing budget |
| `DEIKO_SUMMARIES_PER_CALLER_PER_DAY`, `DEIKO_CLASSIFIES_PER_CALLER_PER_DAY` | `200` | One install's share |
| `DEIKO_TEXT_CALLS_PER_IP_PER_DAY` | `400` | One address's share per text route |
| `DEIKO_REVOKED_TOKENS` | | Comma-separated tokens to refuse |
| `DEIKO_PRO_BENEFIT_IDS` | | Polar benefit ids that grant Pro; unset means any live licence |
| `POLAR_API_BASE` | production | `https://sandbox-api.polar.sh` for Polar's sandbox |
| `PORT` | `8787` | `server.mjs` only |

## Guarantees

- **No content on disk.** Request bodies are read into memory and forwarded.
- **No content in logs.** A log line is a timestamp, method, path, status,
  duration and a 12-character fingerprint of the caller's token.
- **No screen content.** Screenshots, OCR and accessibility text never reach
  the relay. `/v1/classify` accepts window and page titles and the labels read
  from them (web addresses as host and path only), plus open-document names.
- **Strict uploads.** `/v1/transcribe` accepts only the app's own WAV (16 kHz
  mono PCM, at most 40 seconds) and fixed form fields, so the metered duration
  is the real one.

## Tokens

An install is identified by `dev_` plus a salted SHA-256 of the Mac's hardware
id; the id itself is never stored or sent. A Pro licence is sent as `lic_` plus
the Polar licence key and validated with Polar. Neither is authentication: a
token that ships in a client can be read out of it. They decide which allowance
to meter against.

## Spend limits

In order: a per-container burst limit (30 requests a minute per token);
per-install quotas in DynamoDB (2 hours of audio a month for free installs,
10 hours a month for Pro; nothing under 5 seconds is metered); a global daily
ceiling that holds however many installs exist; separate daily budgets for the
text routes, with per-install and per-address shares; reserved concurrency;
and the revocation list. If the usage table can't be reached, transcription
fails closed and the app falls back to on-device recognition.

To stop all transcription immediately, set `DEIKO_GLOBAL_DAILY_SECONDS=0` on
the function (send every other variable in the same call, since the
environment is replaced, not merged) or re-deploy with it in `.env`. To stop
one install, add its `tok:` fingerprint from the logs to `DEIKO_REVOKED_TOKENS`.
