<h1 align="center">
  <a href="https://deiko.app">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.png">
      <img src="docs/assets/logo-light.png" alt="Deiko" width="300">
    </picture>
  </a>
</h1>

<h3 align="center">Point at it. Say it. Your agent remembers it.</h3>

<p align="center">
  Show your coding agent what you mean by pointing, drawing and talking,<br>
  and manage every task's context in a free board that lives on your Mac.<br>
  For Claude Code, Cursor, Codex and any MCP agent. Free and open source.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4a5bac" alt="MIT licence"></a>
  <a href="https://github.com/maddy30445r/deiko/releases"><img src="https://img.shields.io/github/v/release/maddy30445r/deiko?color=4a5bac&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-161618?logo=apple&logoColor=white" alt="macOS 14 or later">
  <a href="https://github.com/maddy30445r/deiko/actions/workflows/ci.yml"><img src="https://github.com/maddy30445r/deiko/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/MCP-memory%20server-4a5bac" alt="MCP memory server">
</p>

<p align="center">
  <a href="#show-your-agent-what-you-mean">Show</a> •
  <a href="#keep-every-tasks-context-on-your-mac">Remember</a> •
  <a href="#install">Install</a> •
  <a href="#how-it-works">How it works</a> •
  <a href="#privacy">Privacy</a> •
  <a href="docs/self-hosting.md">Self-hosting</a> •
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

---

Coding agents have two blind spots. They can't see what you're looking at, so
you type paragraphs about a screen they never saw. And they forget: every new
chat starts from zero, so you explain Tuesday's work again on Friday. Deiko
fixes both, on your Mac.

## Show your agent what you mean

<p align="center">
  <img src="docs/assets/demo.gif" alt="The same bug reported two ways: typed out, and shown with Deiko" width="440">
</p>

1. **Double-tap Right Option** to start. A red bar shows while Deiko listens.
2. **Point and talk.** Rest the cursor on what you mean, or hold Left Option and
   draw around it. Say what should change, in any language you mix.
3. **Tap Right Option** to stop. A coin appears with Deiko's reading of what you said.
4. **Drag the coin onto your agent.** The brief is pasted into that chat and sent.

The brief carries the crops, the exact text under your cursor and your words,
lined up so the agent knows which "this" you meant. Secrets on screen are
redacted; a screenshot that shows a credential is withheld.

## Keep every task's context, on your Mac

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/board-dark.png">
  <img src="docs/assets/board-light.png" alt="The Deiko board: briefs grouped into tasks, each with what happened">
</picture>

Every brief is filed into the piece of work it continues, and each task keeps
a note of where it stands, what was decided and what each agent reported back.
The next brief on that work carries it, so a new chat starts where the last one
stopped. It all lives in a free board on your Mac:

- **See and steer it.** Every task and brief in one window. Move briefs, answer
  "Same work?", edit or forget any note, pin project rules, search by meaning,
  and hand a task off as Markdown.
- **Your agents can use it.** The memory server gives MCP agents five tools:
  `search_briefs`, `list_tasks`, `get_task`, `get_brief` and `save_outcome`.
  One click in Settings connects Claude Code, Codex, Cursor, Gemini CLI,
  VS Code and Antigravity.
- **Agents report back.** When an agent finishes a brief it saves what it did,
  decided and left open, in any agent. In Claude Code a Stop hook makes sure it
  does.

More in [docs/memory.md](docs/memory.md).

## Install

```sh
curl -fsSL https://deiko.app/install.sh | sh
```

Needs macOS 14 or later on Apple silicon. The script installs the latest
release to `/Applications` and launches it ([read it first](scripts/install.sh)).
A first-run window asks for four permissions and explains each one. For the
disk image, updating and uninstalling, see [docs/install.md](docs/install.md).

## How it works

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/architecture-dark.png">
  <img src="docs/assets/architecture-light.png" alt="How Deiko works: capture, brief, filing, board and memory server on your Mac; the brief goes to your agent; an optional relay handles transcription and filing">
</picture>

Speech is transcribed by Whisper (through Deiko's relay, or your own Groq key)
or by Apple's on-device recogniser. Filing uses a keyword and meaning search on
your Mac, then asks Jev which task a brief continues. The pipeline, the memory
server and the relay are all in this repository; see
[docs/architecture.md](docs/architecture.md).

## Works with

**Any agent you can type to.** Drop the coin on its window and the brief is
pasted and sent: Claude Code in a terminal or an IDE, Cursor, Codex, or ChatGPT
and Claude.ai in the browser. Browser chats can't call tools, so their briefs
carry the task's history inline.

**Task memory over MCP** connects in one click to Claude Code, Codex, Cursor,
Gemini CLI, VS Code and Antigravity, and any other MCP client can run the
server directly.

## Privacy

| | |
|---|---|
| **Stored** | Only on your Mac, in `~/Library/Application Support/Deiko`. Recordings are deleted once the brief is made. |
| **Sent for processing** | Your voice to Whisper (Groq), the transcript for a summary, and titles and summaries for filing (Jev via OpenRouter). Nothing is kept. |
| **Never sent** | Screenshots, OCR and accessibility text, except inside the brief you hand to your own agent. |

The relay's code is in this repository, so you can check it, or
[run your own](docs/self-hosting.md). Full details: [docs/privacy.md](docs/privacy.md).

## Pricing

Deiko is free and open source. Everything, Pro included, is free until
**24 October 2026**. After that, Pro is **$7.99 a month, $79 a year or $159
once**, and adds ten hours a month of Deiko's hosted transcription. Without Pro,
Deiko stays free to use: 30 minutes of hosted transcription, then Apple's
on-device recogniser, or your own Groq key with no limit.

## Build from source

```sh
make setup           # Node dependencies
make signing-setup   # once, so macOS permissions survive rebuilds
make install         # build, sign, install and launch
make test            # Swift and Node test suites
```

Requires Xcode 26 and Node 22. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
repository layout and conventions.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md);
report security issues privately as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE). Bundled third-party components keep their own licences; see
[apps/macos/licenses](apps/macos/licenses).

<p align="center">
  <a href="https://deiko.app">deiko.app</a> •
  <a href="CHANGELOG.md">Changelog</a> •
  <a href="https://github.com/maddy30445r/deiko/issues">Issues</a>
</p>
