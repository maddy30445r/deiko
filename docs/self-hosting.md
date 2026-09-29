# Self-hosting

Deiko works without Deiko's servers. Pick how much you want to run yourself.

## Your own Groq key

Paste a [Groq](https://console.groq.com) API key in Settings. Transcription and
summaries then go straight from your Mac to Groq on your account, with no cap.
Filing still uses the relay configured in the build, if any.

## Your own relay

The relay (`services/relay`) adds filing through Jev, metering and a shared
key for a team. Run it locally:

```sh
cp .env.example .env     # set GROQ_API_KEY, and OPENROUTER_API_KEY for filing
make relay-dev           # http://localhost:8787, meters in memory
```

Point a development build at it:

```sh
make install RELAY_URL=http://localhost:8787
```

To deploy it to AWS Lambda with a DynamoDB usage table, set AWS credentials and
run `make relay-deploy`; the script is idempotent and prints the function URL.
[services/relay/README.md](../services/relay/README.md) lists every setting.

## Building the app

See [CONTRIBUTING.md](../CONTRIBUTING.md). A build made without `RELAY_URL`
transcribes with your own Groq key or on-device, and files briefs locally.
