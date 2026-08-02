# Fovea

**Point at things on your screen and talk. Fovea turns that into a brief your
coding agent can act on** — with the screenshots and the exact text you pointed
at, and your own words as the task.

Describing a bug in prose is slow and lossy. Pointing at it is neither.

```
double-tap Right Option        start
                               talk, and point at what you mean
hold Left Option + drag        lasso a region
tap Right Option               stop

                               → a small orb appears with what Fovea heard
drag the coin onto your        → the brief lands in that live session, and the
Claude Code window               command is typed and submitted for you
```

---

## Install

1. Open the DMG and drag **Fovea** to Applications.
2. **Before launching**, clear the quarantine:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Fovea.app
   ```
3. Launch it. A first-run window walks you through four permissions.
4. Connect your coding agent in Settings, and you're done.

### Why step 2, and why that way round

Fovea is signed with a **self-signed certificate**, not an Apple Developer ID.
Anything downloaded without one is quarantined, and macOS says *"Fovea can't be
opened because the developer cannot be verified."*

The GUI route — **System Settings → Privacy & Security → Open Anyway** — does
let the app start, and it is fine if you prefer clicking. But quarantine is set
on **every file** in the download, and Fovea ships its own Node runtime inside
the bundle to transcribe your sessions. Clearing the app you launched does not
obviously clear a nested binary the app later spawns, and the failure shows up
much later as a session stuck at *"Transcribing…"*. `xattr -dr` clears the whole
tree in one go, which is why it leads.

Right-click → Open is **not** enough on current macOS.

Being straight about what this means: you are choosing to run an app Apple has
not vetted, on the basis that you trust whoever handed you the DMG. That is a
real decision. Only the $99/yr Developer Program removes this wall.

## The four permissions

Each is used for exactly one thing, and nothing is captured unless you start a
session.

| | |
|---|---|
| **Accessibility** | reads the label under your cursor, and watches for the hotkey |
| **Screen Recording** | crops a screenshot of what you point at |
| **Microphone** | records your narration while you point |
| **Speech Recognition** | turns your words into text, on this Mac |

**Screen Recording needs a relaunch** before it takes effect. Fovea offers you
the button when that moment arrives.

If a permission is missing, the menu-bar mark wears an orange `!` — the hotkey
does nothing without all four, and an app that looked ready while silently
ignoring you would be worse.

## What leaves your Mac

**Your narration audio, and nothing else.** Screenshots, OCR text, window
titles and accessibility text have never left the device and there is no
setting that makes them.

- **The recording is deleted the moment your brief is made.** It has one use
  and no reader after that.
- A red bar sits at the top of the screen for the whole time a session is
  capturing. It does not fade or auto-hide, and clicking it stops the session.
- If a credential is visible in a screenshot, that screenshot is **withheld**
  and the brief says so rather than sending it.

Transcription picks the first of these that is available:

1. **your own Sarvam API key**, if you add one in Settings — your key, your
   bill, and Fovea's servers never see the audio;
2. **Fovea's service**, which forwards the audio to a transcription provider
   and keeps nothing;
3. **this Mac alone** — no upload at all. Accuracy is lower, especially for
   mixed-language speech.

## Connecting a coding agent

Settings has a row per agent. Connecting registers Fovea's bridge so the agent
can fetch a brief you hand it.

| | |
|---|---|
| **Claude Code** | `~/.claude.json` — both the CLI and the VS Code extension |
| **Cursor** | `~/.cursor/mcp.json` |
| **Antigravity** | `~/.gemini/config/mcp_config.json` |
| **Codex CLI** | `~/.codex/config.toml` |

Fovea reads the file, changes one key, and writes everything else back
untouched — with a one-time backup beside it, and a read-back to confirm. If it
cannot parse the file, it refuses rather than overwriting it.

Claude Code turns the brief into the slash command `/fovea:brief`. The others
are tool-first, so Fovea types a sentence asking for the brief instead.

## Using it

**Talk while you point.** The narration *is* the task — Fovea deliberately
does not write a summary of it for the agent, because you already said what you
wanted out loud.

Pointing only counts while you are speaking. A cursor that comes to rest while
you are silent is not recorded, which is what keeps a session from filling up
with everything you happened to scroll past.

When you stop, the orb appears with Fovea's reading of what it heard. Then:

- **drag the coin** onto the window running your agent — the brief is sent, the
  app is brought forward, and the command is typed and submitted;
- **click the coin** to review — the transcript is editable there, and it is
  the one thing worth correcting, because a mis-heard identifier does more
  damage than anything else in the document;
- **double-tap Right Option again** while the orb is up to add more to the same
  session;
- **× or Escape** puts it away. The session stays on disk.

## Building from source

```sh
make setup      # node deps
make bundle     # build/Fovea.app
make dmg        # build/Fovea-<version>.dmg
make test
```

`make signing-setup` creates the local certificate once. Without it the app is
ad-hoc signed and **macOS drops all four permissions on every rebuild**.

## Shipping a new version to the team

```sh
# 1. bump the version — one file, everything else reads it
echo 0.2.0 > VERSION

# 2. commit; the release refuses to run on a dirty tree
git commit -am "…"

# 3. build, tag, and publish the DMG in one step
make release RELAY_URL=https://<your-relay>.lambda-url.ap-south-1.on.aws
```

`make release` refuses a dirty tree or an existing tag, because a release whose
contents do not match a commit is worse than no release. It stamps the version
and the relay URL into the bundle, builds the DMG, and creates the GitHub
Release with generated notes that lead with the quarantine step.

**Always pass `RELAY_URL`.** It is not remembered between releases — a build
made without it silently falls back to on-device words, which is a quieter
failure than a relay that is down. Confirm it landed before sharing the link:

```sh
/Applications/Fovea.app/Contents/MacOS/fovea-capture diagnostics | grep -i transcri
# must say: Fovea relay (https://…) — not "on-device only"
```

**Access is repo access.** The repository is private, so a release asset
returns **404** to anyone who is not a collaborator — not a login page, a plain
404, which reads like a broken link. Sharing the URL is therefore not enough:
add each teammate under Settings → Collaborators first, or
`gh api -X PUT repos/<owner>/Fovea/collaborators/<user> -f permission=pull`.
Whoever can see the repo can fetch the build, and nobody else can — which is
the access list you want while the app is unsigned anyway.

**What a teammate does to update:** quit Fovea, drag the new build over the old
one in Applications, and clear quarantine again
(`xattr -dr com.apple.quarantine /Applications/Fovea.app`). The four
permissions survive, because the app keeps the same signing identity. Anyone
who pasted their own Sarvam key gets one login-password prompt on their first
session after updating — see below.

### The one rough edge in updates

macOS guards a keychain item with an ACL pinned to one exact binary, and every
update is a new binary, so the first read after an update asks for the login
password. "Always Allow" quiets it until the next update.

Fovea keeps this as small as it can: everything that only needs to know
*whether* a key is set uses an attributes-only query that never prompts, and
the relay device token was moved out of the keychain entirely because it is an
identifier rather than a secret. What remains is the API keys themselves, so
**only teammates using their own Sarvam or Groq key ever see the prompt.**
Anyone on the default relay path never does.

Removing it completely needs an Apple Developer ID ($99/yr), which changes the
ACL from "this exact binary" to "this team" and therefore survives updates.

## Licence

Not yet chosen. Every third-party dependency is permissively licensed (MIT,
ISC, BSD, Apache-2.0); there is no copyleft anywhere in the tree.
