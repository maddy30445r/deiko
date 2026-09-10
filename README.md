# Deiko

**Point at things on your screen and talk. Deiko turns that into a brief your
coding agent can act on** — with the screenshots and the exact text you pointed
at, and your own words as the task.

Describing a bug in prose is slow and lossy. Pointing at it is neither.

```
double-tap Right Option        start
                               talk, and point at what you mean
hold Left Option + drag        lasso a region
tap Right Option               stop

                               → a small orb appears with what Deiko heard
drag the coin onto your        → your prompt is pasted into that live session
Claude Code window               and submitted for you
```

---

## Install

Requires macOS 14 or later.

```sh
curl -fsSL https://<site>/install.sh | sh
```

That fetches the latest release, copies it to `/Applications`, clears the
download quarantine and launches it. [Read it first](scripts/install.sh) — it is
short, and piping a stranger's script into `sh` deserves a look.

The site has no domain yet, so there is no `<site>` to paste. Until there is,
builds are handed over as a DMG directly and installed by hand:

### By hand

1. Open the DMG and drag **Deiko** to Applications.
2. **Before launching**, clear the quarantine:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Deiko.app
   ```
3. Launch it. A first-run window walks you through four permissions, and
   you're done — the gesture above is all it takes from there.

### Why step 2, and why that way round

Deiko is signed with a **self-signed certificate**, not an Apple Developer ID.
Anything downloaded without one is quarantined, and macOS says *"Deiko can't be
opened because the developer cannot be verified."*

The GUI route — **System Settings → Privacy & Security → Open Anyway** — does
let the app start, and it is fine if you prefer clicking. But quarantine is set
on **every file** in the download, and Deiko ships its own Node runtime inside
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

**Screen Recording needs a relaunch** before it takes effect. Deiko offers you
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

1. **your own Sarvam API key** — your key, your bill, and Deiko's servers never
   see the audio. Part of Pro; a checkout using a `.env` is never gated.
2. **Deiko's service**, which forwards the audio to a transcription provider and
   keeps nothing. Free installs get **30 minutes of it, once**; Pro gets five
   hours a month.
3. **this Mac alone** — no upload at all, using Apple's on-device recogniser.
   Accuracy is lower, especially for mixed-language speech.

**Running out is not an error.** When the free 30 minutes are gone, sessions keep
working on option 3 — the brief still renders, from Apple's words. Nothing breaks
and nothing stops; the accuracy is just the accuracy Apple gives you.

## Plans

| | |
|---|---|
| **Free** | The whole app. 30 minutes of Deiko's transcription, once, then on-device forever. |
| **Pro — $3.99/mo or $29.99/yr** | Ten hours of transcription a month, or bring your own Sarvam key and use none of ours. |

A licence key is pasted into Settings. **There is no account** — no email, no
password, no profile, nothing to sign into and nothing of yours to breach. The
key is the whole thing.

The free trial is counted against your Mac using a one-way hash of its hardware
id. We never see or store the id itself, and it identifies a machine rather than
a person — but it is a stable pseudonym that survives reinstalling, and it would
be dishonest to say otherwise.

## Using it

**Talk while you point.** The narration *is* the task — Deiko deliberately
does not write a summary of it for the agent, because you already said what you
wanted out loud.

Pointing only counts while you are speaking. A cursor that comes to rest while
you are silent is not recorded, which is what keeps a session from filling up
with everything you happened to scroll past.

When you stop, the orb appears with Deiko's reading of what it heard. Then:

- **drag the coin** onto the window running your agent — the app is brought
  forward, and your prompt is pasted in and submitted;
- **click the coin** to review — the transcript is editable there, and it is
  the one thing worth correcting, because a mis-heard identifier does more
  damage than anything else in the document;
- **double-tap Right Option again** while the orb is up to add more to the same
  session;
- **× or Escape** puts it away. The session stays on disk.

## Building from source

```sh
make setup      # node deps
make bundle     # build/Deiko.app
make install    # …and put it in /Applications, restarted
make dmg        # build/Deiko-<version>.dmg
make test
```

Use `make install` rather than copying by hand. `cp -R build/Deiko.app
/Applications/` merges into the existing bundle instead of replacing it, and
rewrites the app underneath Finder, which then caches whatever half-state it
saw — a prohibited-sign or blank icon on an app that is running fine and
correctly signed. `make install` quits, replaces wholesale, re-registers with
LaunchServices and relaunches.

`make signing-setup` creates the local certificate once. Without it the app is
ad-hoc signed and **macOS drops all four permissions on every rebuild**.

## Shipping a new version to the team

```sh
# 1. bump the version — one file, everything else reads it
echo 0.2.0 > VERSION

# 2. commit; the release refuses to run on a dirty tree
git commit -am "…"

# 3. build, tag, and publish the DMG in one step
make release \
  RELAY_URL=https://<your-relay>.lambda-url.ap-south-1.on.aws \
  SITE_URL=https://deiko.app \
  BUY_URL=https://buy.polar.sh/polar_cl_zzHzJtHnGwaUZhsQMEQX5CJ6rvrHytww5AaUx4J6WjF \
  SUPPORT_EMAIL=support@deiko.app
```

**Pass all four.** `make release` refuses without `RELAY_URL` or `SITE_URL`, but
it only *warns* about the other two — and a build missing them ships with the
"Get Pro…" and "Send feedback…" affordances silently hidden, which looks like a
finished app that simply cannot be paid or written to. The one Polar link above
carries **both** SKUs, annual first, so the checkout opens on $29.99/yr with a
switcher down to $3.99/mo.

`make release` refuses a dirty tree or an existing tag — in either spelling,
`v0.4.1` or `0.4.1` — because a release whose contents do not match a commit is
worse than no release. It stamps the version, the relay URL, the site URL, the
checkout link and the support address into the bundle, builds the DMG, and
hands it to `scripts/publish-release.sh`,
which uploads the disk image to S3, writes the `version.json` the app's update
check reads, and publishes `install.sh` stamped with the host serving it. Then
it tags the commit here.

It does **not** create a GitHub Release; that was true once and the Makefile
explains at length why it no longer is — an asset behind repo access returns a
bare 404 to a stranger, which reads as a broken link rather than a permission
problem.

**Always pass `RELAY_URL`.** It is not remembered between releases — a build
made without it silently falls back to on-device words, which is a quieter
failure than a relay that is down. Confirm it landed before sharing the link:

```sh
/Applications/Deiko.app/Contents/MacOS/deiko-capture diagnostics | grep relay
```

That must print the URL, not `none — this build has no relay`.

Check `relay configured:`, **not** `transcription:`. The second line says which
transcriber would run, and your own Sarvam key outranks the relay — so on your
machine it reads "your own Sarvam key" whether the URL was stamped or not. It
cannot fail, which makes it the worse kind of check: the trusted kind.

**Builds go to the site, not to this repo.** `make release SITE_URL=…` puts the
DMG and a `version.json` under `/download` on the landing site, and tags *this*
repo, which stays private — the site holds the binary, this repo holds the
commit that produced it. "Who may read the code" and "who may download the app"
are separate questions; they were the same answer only because releases used to
be cut here, and an asset on a private repo returns a bare **404** to a
stranger, which reads like a broken link rather than a permission problem.

`make release` refuses when `SITE_URL` is empty. A build nobody can reach is
not a release.

**What somebody does to update:** re-run the install command — it replaces the
existing install and clears quarantine again. The four permissions survive,
because the app keeps the same signing identity. Anyone who pasted their own
Sarvam key gets one login-password prompt on their first session after updating
— see below.

Deiko checks for a newer release once at launch and, if there is one, grows an
**"Update to …"** item in its menu. It never installs anything by itself.

**Check that the site actually serves the file, every release.** The update
check fails *silently* by design — no site, no network, a 404 or a malformed
file all mean "carry on", because an app that interrupts a developer to report
it could not check for updates has made their day worse for nothing. The cost of
that design is that a broken publish is invisible from the app, and it has been
broken: 0.4.2 shipped stamped with a `DeikoSiteURL` whose
`download/version.json` returns 404, so every install of it checks and silently
learns nothing. One command says whether the release landed:

```sh
curl -fsS "$SITE_URL/download/version.json" && curl -fsSI "$SITE_URL/install.sh" >/dev/null \
  && echo "✓ the site is serving this release"
```

`make release` cannot do this for you — the upload finishes before the CDN has
the file — so it belongs in the announcement step, before the link is shared.

### The one rough edge in updates

macOS guards a keychain item with an ACL pinned to one exact binary, and every
update is a new binary, so the first read after an update asks for the login
password. "Always Allow" quiets it until the next update.

Deiko keeps this as small as it can: everything that only needs to know
*whether* a key is set uses an attributes-only query that never prompts, and
the relay device token was moved out of the keychain entirely because it is an
identifier rather than a secret. What remains is the API keys themselves, so
**only teammates using their own Sarvam or Groq key ever see the prompt.**
Anyone on the default relay path never does.

Removing it completely needs an Apple Developer ID ($99/yr), which changes the
ACL from "this exact binary" to "this team" and therefore survives updates.

## Uninstall

Dragging the app to the Trash leaves five things behind, because macOS keeps
them outside the bundle. In rough order of how much space they take:

```sh
# 1. Your sessions — briefs and screenshots. The recordings were already
#    deleted, one per brief, as each was made.
rm -rf ~/Documents/Deiko

# 2. Logs.
rm -rf ~/Library/Logs/Deiko

# 3. Preferences: licence key, cached plan, session key, first-run flag.
defaults delete com.deiko.capture

# 4. Any API keys you pasted in Settings.
security delete-generic-password -s com.deiko.capture -a SARVAM_API_KEY
security delete-generic-password -s com.deiko.capture -a GROQ_API_KEY

# 5. The four permission grants.
tccutil reset All com.deiko.capture
```

Turn off **Open Deiko at login** in Settings before you delete the app, or the
login item outlives it and macOS reports a missing application at every boot.

Reinstalling does **not** restore your free trial. It is counted against a
one-way hash of the Mac's hardware id, which is the same after a reinstall —
see [Plans](#plans) above, where that trade-off is stated in full.

## Licence

Not yet chosen. Every third-party dependency is permissively licensed (MIT,
ISC, BSD, Apache-2.0); there is no copyleft anywhere in the tree.
