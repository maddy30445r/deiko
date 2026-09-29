# Security policy

Deiko reads your screen and your voice, so security reports get priority.

## Reporting a vulnerability

Please do not open a public issue. Email **support@deiko.app** with a
description, steps to reproduce and the Deiko version. You will get a reply
within three working days, and a fix or a plan within fourteen.

Use [GitHub's private vulnerability reporting](https://github.com/maddy30445r/deiko/security/advisories/new)
if you prefer.

## Scope

- The macOS app (`apps/macos`) and its bundled pipeline (`packages/core`)
- The relay (`services/relay`)
- deiko.app and its download endpoints

Secret redaction is a security feature: a brief that carries a credential
from your screen to an agent is a vulnerability, and reports of one are welcome.
