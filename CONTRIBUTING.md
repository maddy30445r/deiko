# Contributing to Deiko

Thanks for helping. Bug reports, fixes and ideas are all welcome; for anything
larger than a small fix, open an issue first so we can agree on the approach.

## Requirements

- macOS 14 or later on Apple silicon
- Xcode 16 or later (Swift 6)
- Node.js 22 or later

## Getting started

```sh
git clone https://github.com/maddy30445r/deiko.git
cd deiko
make setup           # install Node dependencies
make signing-setup   # once: a local signing certificate, so permissions survive rebuilds
make install         # build, sign and install to /Applications, then launch
```

`make help` lists every target. Copy `.env.example` to `.env` to use your own
Groq key or a local relay; every variable there is optional.

A build installed from a checkout runs the pipeline scripts straight from
`packages/core/src`, so a change to a script takes effect on the next brief
without rebuilding the app.

## Repository layout

| Path | What it is |
|---|---|
| `apps/macos` | The menu-bar app (Swift package): capture, gestures, voice, the board and hand-off |
| `packages/core` | The Node pipeline the app runs: transcription, briefs, filing, task memory and the memory MCP server |
| `packages/alignment` | Matches spoken words to what you pointed at (TypeScript) |
| `services/relay` | The hosted relay for transcription, summaries and filing (AWS Lambda) |
| `evals` | Quality evaluations for filing, search and memory |
| `scripts` | Maintainer scripts: release, deploy, installer |
| `docs` | Architecture, privacy and self-hosting notes |

Start with [docs/architecture.md](docs/architecture.md).

## Tests

```sh
make test                                # everything
npm test                                 # Node packages, relay and evals
swift test --package-path apps/macos     # the app's libraries
make flow-check                          # end to end against a local relay (needs keys in .env)
```

Add a test with every behaviour change. Tests that describe a behaviour in
their title are preferred over ones named after a function.

## Code style

- Match the surrounding code. JavaScript uses ES modules, two-space indents
  and no build step; Swift follows the standard library's conventions.
- Comments explain *why*: a constraint, an invariant, a platform quirk. Don't
  narrate history or restate the code; that belongs in the commit message.
- Keep dependencies to a minimum. The pipeline ships inside the app, so every
  package adds to its size.

## Commits and pull requests

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org):

```
type(scope): imperative summary, 72 characters or fewer
```

Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci`, `chore`.
Scopes: `app`, `gesture`, `voice`, `grounding`, `handoff`, `board`, `core`,
`memory`, `filing`, `relay`, `web`, `eval`, `release`.

Keep a pull request to one change, make sure CI passes, and describe how you
tested it.

## Privacy

Deiko handles screenshots, voice and whatever was on screen. Never commit
captured sessions, and keep the redaction tests passing: a brief must not
carry a credential from the screen to an agent. See [SECURITY.md](SECURITY.md)
to report a vulnerability.
