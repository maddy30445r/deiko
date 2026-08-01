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

## Deploying

Any host that runs Node and terminates TLS. It is one file, has no
dependencies, and holds no state worth persisting. A `Dockerfile` and a
`fly.toml` are here because those are the two shortest routes.

**Fly.io**, from this directory:

```sh
fly launch --no-deploy --name fovea-relay
fly secrets set SARVAM_API_KEY=… GROQ_API_KEY=…
fly deploy
curl https://fovea-relay.fly.dev/health
```

It scales to zero, so an idle day costs nothing; the first session after a
quiet spell pays a second or two of cold start, which is well inside the
client's timeout.

**Anything else** — Render, Railway, a VPS behind Caddy — is
`docker build . && docker run -e SARVAM_API_KEY=… -p 8787:8787`.

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

An opaque per-install identifier, minted on first launch and kept in the
login keychain. It lets you rate-limit and revoke one abusive install without
stopping everybody.

**It is not authentication.** A token that ships inside a client can be read
out of it by anyone who wants to. Real per-user identity means accounts — a
product decision, not a line of code. Until then the mitigations are the rate
limit, the revocation list, and watching your provider bill.

The rate limit is in memory and therefore per-instance: a speed bump, not a
quota system. Running more than one instance needs a shared store.

## The privacy promise changes when you turn this on

Without a relay: narration audio goes to Sarvam, and to nobody else.

With one: narration audio goes to **Fovea's server**, which forwards it and
keeps nothing. That is a materially different claim, and the app must say so
where people read it before they start — Settings says it next to the Sarvam
field that opts out of it, and a user with their own key never touches this
service at all.
