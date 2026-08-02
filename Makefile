.PHONY: dev build test probe watch region clean setup bundle install icon dmg release guard-clean relay-deploy relay-dev site-deploy resources dist record transcribe align ground brief summarize send bridge-install bridge-test show-brief signing-setup reset-permissions

# Code-signing identity for the bundle.
#
# This matters far more than it looks. TCC stores a permission grant against the
# app's code-signing requirement, and for an AD-HOC signature that requirement
# pins the binary's cdhash — which changes on every single rebuild. The result
# is that all four permissions silently die every time you run `make bundle`,
# and the Accessibility entry stays visibly ticked while being dead.
#
# Signing with a stable self-signed certificate instead keys the grant to the
# certificate, so the permissions survive rebuilds. See `make signing-setup`.
#
# Deliberately NOT `find-identity -v`. The -v flag lists only certificates macOS
# considers valid, which for a self-signed one means added to your trust store —
# an authorisation prompt and a root certificate, bought for nothing, since
# codesign signs perfectly well with an untrusted local identity.
SIGN_NAME  ?= Fovea Local
SIGN_FOUND := $(shell security find-identity -p codesigning 2>/dev/null | grep -c '"$(SIGN_NAME)"')

CAPTURE_DIR := apps/capture
DEBUG_BIN   := $(CAPTURE_DIR)/.build/debug/fovea-capture
RELEASE_BIN := $(CAPTURE_DIR)/.build/release/fovea-capture

## dev — build the capture binary and verify the Swift→Node stdio contract
dev: $(DEBUG_BIN)
	@node scripts/hello.mjs

# Every Sources subtree, not just FoveaCapture — the pure targets (FoveaGesture,
# FoveaVoice, FoveaGrounding) are where the testable logic lives, and a rule that
# does not watch them silently runs the old binary against the new tests.
$(DEBUG_BIN): $(wildcard $(CAPTURE_DIR)/Sources/*/*.swift) $(CAPTURE_DIR)/Package.swift
	@swift build --package-path $(CAPTURE_DIR)

## build — release binary
build:
	@swift build --package-path $(CAPTURE_DIR) -c release
	@echo "built $(RELEASE_BIN)"

## test — Swift gesture tests + TypeScript workspace tests
test:
	@swift test --package-path $(CAPTURE_DIR)
	@npm test --workspaces --if-present

## setup — install node deps
setup:
	@npm install

## probe — single AX probe at the cursor, 3s after you hit enter
probe: $(DEBUG_BIN)
	@$(DEBUG_BIN) ax-probe --delay 3 --verbose

## watch — probe on every cursor settle. The tool for the T0.1 app matrix.
watch: $(DEBUG_BIN)
	@$(DEBUG_BIN) ax-probe --watch --verbose

## region — same, but probes a circular lasso around the cursor
region: $(DEBUG_BIN)
	@$(DEBUG_BIN) ax-probe --watch --region 90 --verbose

## bundle — assemble Fovea.app around the binary
##
## Needed because TCC will not honour usage descriptions from a bare SwiftPM
## executable: requesting Speech Recognition from one is killed with SIGABRT,
## and `tccutil` does not even recognise its identifier. Linking the plist in as
## a __TEXT,__info_plist section satisfies codesign but not TCC.
##
## It is also where the product is going regardless — a menu-bar app (PRD §7) —
## and it fixes the permission model: permissions attach to Fovea.app instead of
## to whichever terminal happened to launch the binary.
APP := build/Fovea.app
RES := $(APP)/Contents/Resources

# ONE version in the product. `VERSION` is the source; it is stamped into the
# bundle below, and `FoveaVersion` reads it back out at runtime. There used to
# be two hardcoded literals with nothing keeping them in sync.
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.0)
# The build number distinguishes two shipped copies of one version. A commit
# count is monotonic, requires nothing to be maintained by hand, and is 1 in a
# tarball with no git — which is honest rather than wrong.
BUILD := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

# Where the landing site's built static files are. Overridable because the
# generator has not been chosen yet.
SITE_DIR ?= site

bundle: $(DEBUG_BIN) resources
	@cp $(CAPTURE_DIR)/Sources/FoveaCapture/Info.plist $(APP)/Contents/Info.plist
	@cp $(DEBUG_BIN) $(APP)/Contents/MacOS/fovea-capture
	@cp $(CAPTURE_DIR)/Sources/FoveaCapture/Fovea.icns $(RES)/Fovea.icns
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :FoveaRelayURL $(RELAY_URL)" $(APP)/Contents/Info.plist
ifneq ($(RELAY_URL),)
	@echo "  relay: $(RELAY_URL)"
else
	@echo "  relay: none — sessions fall back to on-device words"
endif
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string fovea-capture" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
ifeq ($(SIGN_FOUND),0)
	@codesign --force --deep --sign - $(APP) 2>/dev/null
	@echo "built $(APP)  ⚠ AD-HOC SIGNED"
	@echo "   macOS will drop all four permissions on the next rebuild."
	@echo "   Fix it once:  make signing-setup"
else
	@codesign --force --deep --sign "$(SIGN_NAME)" $(APP) 2>/dev/null
	@echo "built $(APP)  (signed: $(SIGN_NAME) — permissions survive rebuilds)"
endif
	@echo "launch it:  open $(APP)      (menu-bar app; permissions attach to Fovea)"
	@echo "subcommand: $(APP)/Contents/MacOS/fovea-capture <cmd>"

## install — put this build in /Applications and restart it
##
## `cp -R build/Fovea.app /Applications/` is the obvious command and it is
## wrong twice over. It MERGES into the existing bundle rather than replacing
## it, so files the old build had and the new one does not simply survive; and
## it rewrites the app underneath Finder, which caches the icon it sees
## mid-copy. That produced a prohibited-sign icon once and a blank placeholder
## once, in the same evening, on an app that was working perfectly both times —
## an hour lost to a cosmetic artifact with a valid signature behind it.
##
## So: quit first, replace wholesale, then make the icon caches let go.
##
## THE CACHE PURGE AND THE RESTARTS ARE THE LOAD-BEARING PART, and `lsregister`
## alone is NOT enough — this target shipped without them and reproduced the
## blank icon on its very first run. Finder and Dock each hold their own
## rendered copy, keyed by path, and neither re-reads the bundle just because
## LaunchServices was told to. Restarting them is what actually clears it.
## They both relaunch immediately; the cost is a Finder window blinking.
install: bundle
	@osascript -e 'quit app "Fovea"' 2>/dev/null || true
	@sleep 1
	@rm -rf /Applications/Fovea.app
	@cp -R $(APP) /Applications/
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R /Applications/Fovea.app
	@touch /Applications/Fovea.app /Applications/Fovea.app/Contents/Info.plist
	@find "$$(getconf DARWIN_USER_CACHE_DIR)" -name com.apple.dock.iconcache -delete 2>/dev/null || true
	@find "$$(getconf DARWIN_USER_CACHE_DIR)" -maxdepth 2 -name com.apple.iconservices -type d -exec rm -rf {} + 2>/dev/null || true
	@killall Dock 2>/dev/null || true
	@killall Finder 2>/dev/null || true
	@sleep 2
	@open /Applications/Fovea.app
	@echo "installed and running: /Applications/Fovea.app  (Dock + Finder restarted)"
	@echo "verify: /Applications/Fovea.app/Contents/MacOS/fovea-capture diagnostics | grep relay"

## dmg — the thing you actually hand to somebody
##
## `hdiutil` rather than `create-dmg`, because it ships with macOS: a release
## step that first needs a Homebrew install is a release step that fails on the
## one machine you did not set up.
##
## Built from `dist`, not `bundle` — the Node runtime is what makes this work on
## a Mac that has never had Node, which is most Macs.
##
## THE README IN THE WINDOW IS NOT DECORATION. The app is signed with a
## self-signed certificate, so the first thing that happens after the drag is
## macOS refusing to open it. Somebody who does not find the bypass concludes
## the app is broken, and they are not wrong to.
DMG := build/Fovea-$(VERSION).dmg

dmg: dist
	@rm -rf build/dmg $(DMG)
	@mkdir -p build/dmg
	@cp -R $(APP) build/dmg/
	@ln -s /Applications build/dmg/Applications
	@cp README.md build/dmg/
	@printf '%s\n' \
		'Fovea $(VERSION)' \
		'' \
		'1. Drag Fovea onto the Applications folder.' \
		'' \
		'2. BEFORE LAUNCHING, run this once in Terminal:' \
		'' \
		'     xattr -dr com.apple.quarantine /Applications/Fovea.app' \
		'' \
		'   Fovea is signed with a self-signed certificate rather than an' \
		'   Apple Developer ID, so macOS quarantines everything you just' \
		'   downloaded. This clears the whole bundle -- including the Node' \
		'   runtime inside it that Fovea spawns to transcribe your sessions.' \
		'' \
		'   The GUI route (System Settings -> Privacy & Security -> "Open' \
		'   Anyway") lets the app start, but may leave that nested runtime' \
		'   quarantined -- which turns up later as a session stuck at' \
		'   "Transcribing...". The command above avoids that.' \
		'' \
		'   Right-click -> Open is NOT enough on current macOS.' \
		'' \
		'3. Launch it. Fovea lives in the menu bar, and a first-run window' \
		'   explains the four permissions it needs and why.' \
		'' \
		'4. Settings -> connect your coding agent.' \
		'' \
		'Full documentation: README.md, beside this file.' \
		> 'build/dmg/Read me first.txt'
	@hdiutil create -volname "Fovea $(VERSION)" -srcfolder build/dmg \
		-ov -format UDZO -quiet $(DMG)
	@echo "built $(DMG)  ($$(du -h $(DMG) | cut -f1))"
	@echo "  the app inside is SELF-SIGNED — the receiver must bypass Gatekeeper."
	@echo "  'Read me first.txt' in the window tells them how."

## release — cut a GitHub Release with the DMG attached
##
##   make release RELAY_URL=https://fovea-relay.fly.dev
##
## A PRIVATE repo is the access list. Whoever can see `maddy30445r/Fovea` can
## download the build and nobody else can — no bucket to secure, no link to
## leak, and the same permission the code already lives behind.
##
## Refuses on a dirty tree or an existing tag. A release whose contents do not
## correspond to a commit is worse than no release: the first bug report cites
## a version that cannot be checked out.
release: guard-clean
	@test -z "$$(git tag -l v$(VERSION))" \
		|| (echo "✗ tag v$(VERSION) already exists — bump VERSION first"; exit 1)
	@$(MAKE) --no-print-directory dmg RELAY_URL=$(RELAY_URL)
	@printf '%s\n' \
		'## Install' \
		'' \
		'1. Open the DMG and drag **Fovea** to Applications.' \
		'2. Clear the download quarantine — **do this before launching**:' \
		'   ```' \
		'   xattr -dr com.apple.quarantine /Applications/Fovea.app' \
		'   ```' \
		'   Fovea is signed with a self-signed certificate rather than an Apple' \
		'   Developer ID, so macOS quarantines it. This one command clears the' \
		'   whole bundle, including the Node runtime inside it that the app' \
		'   spawns to transcribe.' \
		'' \
		'   The GUI route (System Settings → Privacy & Security → Open Anyway)' \
		'   lets the app launch, but may leave that nested runtime quarantined —' \
		'   which shows up later as a session stuck at "Transcribing…".' \
		'' \
		'3. Launch it. A first-run window covers the four permissions.' \
		'4. Settings → connect your coding agent.' \
		'' \
		'Full documentation is in README.md in the repo.' \
		'' \
		'Built from $(shell git rev-parse --short HEAD).' \
		> build/release-notes.md
	@gh release create v$(VERSION) $(DMG) \
		--title "Fovea $(VERSION)" \
		--notes-file build/release-notes.md
	@echo "✓ https://github.com/$$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/v$(VERSION)"

## Refuse to build a release out of uncommitted work.
guard-clean:
	@test -z "$$(git status --porcelain)" \
		|| (echo "✗ working tree is dirty — commit before releasing"; \
		    git status --short; exit 1)

## relay-deploy — the transcription relay onto AWS Lambda
##
##   SARVAM_API_KEY=… GROQ_API_KEY=… make relay-deploy
##
## Lambda because the service is idle most of the day by design — nobody is
## recording — and it is the only option that costs nothing while idle. See
## services/relay/deploy-aws.sh; it is idempotent, so this is also how you ship
## a code change.
relay-deploy:
	@./services/relay/deploy-aws.sh

## relay-dev — run the relay locally, for testing the app against it
##
##   make relay-dev
##   FOVEA_RELAY_URL=http://localhost:8787 open build/Fovea.app
relay-dev:
	@node services/relay/server.mjs

## site-deploy — the landing site onto S3 + CloudFront
##
##   make site-deploy SITE_DIR=site
site-deploy:
	@./scripts/deploy-site.sh $(SITE_DIR)

## icon — regenerate Fovea.icns from the fovea mark
##
## The .icns is COMMITTED, so `make bundle` needs nothing but a copy. Run this
## only after changing the geometry in Sources/FoveaCapture/Iconset.swift.
##
## Drawn by the binary rather than by a script: the coin, the menu bar and the
## icon are one shape, and keeping the third renderer in the same target as the
## other two is what stops it drifting.
icon: $(DEBUG_BIN)
	@$(DEBUG_BIN) icon --out build/Fovea.iconset
	@iconutil -c icns build/Fovea.iconset -o $(CAPTURE_DIR)/Sources/FoveaCapture/Fovea.icns
	@echo "✓ $(CAPTURE_DIR)/Sources/FoveaCapture/Fovea.icns"

## resources — the pipeline, inside the bundle
##
## MIRRORS THE REPO LAYOUT, and that is the whole trick. The scripts import
## their packages by relative path (`../packages/alignment/dist/src/align.js`)
## and the bridge reaches back for `../../../scripts/lib/redact.mjs`; Node also
## finds `node_modules` by walking up from the script it is running. Reproduce
## the shape and every one of those resolves unchanged — no rewriting imports,
## no bundler, nothing to keep in sync.
##
## The dependency closure is COPIED rather than tree-shaken with esbuild. It is
## 24MB against the 106MB Node runtime that ships beside it, so bundling would
## optimise the small half — and esbuild on an SDK with dynamic requires is a
## real chance of a break that only shows up in the shipped app.
##
## `make bundle` runs this every time: it is a few hundred KB of scripts and
## built packages, and a bundle whose Resources lag its binary is a bug you find
## in the DMG. `node_modules` is rebuilt only when the bridge's manifest changes.
resources: build/bridge-deps/node_modules
	@rm -rf $(RES)
	@mkdir -p $(RES)/apps $(APP)/Contents/MacOS
	@npm run build --workspaces --if-present --silent >/dev/null
	@rsync -a --delete scripts $(RES)/
	@rsync -a --delete --prune-empty-dirs \
		--include='*/' --include='dist/***' --include='package.json' --exclude='*' \
		packages $(RES)/
	@rsync -a --delete apps/bridge $(RES)/apps/
	@rsync -a --delete build/bridge-deps/node_modules $(RES)/
	@echo "  resources: scripts + packages/dist + bridge + node_modules"

## The bridge's PRODUCTION dependency closure, staged once.
##
## A separate tree from the repo's own `node_modules` (49MB, dev deps and all)
## because a shipped app should carry what the bridge needs and nothing else.
## Make rebuilds it only when `apps/bridge/package.json` is newer.
build/bridge-deps/node_modules: apps/bridge/package.json
	@mkdir -p build/bridge-deps
	@cp apps/bridge/package.json build/bridge-deps/
	@cd build/bridge-deps && npm install --omit=dev --silent --no-audit --no-fund
	@touch $@

## dist — the shippable bundle: everything in `bundle`, plus the Node runtime
##
## Node is NOT in `make bundle` on purpose. It is 106MB, and a developer's app
## resolves the pipeline from the checkout beside it anyway (see `Layout`), so
## copying it on every rebuild would cost the fast local loop and buy nothing.
## Here it is the point: `NodeRuntime` prefers a bundled runtime over anything
## on PATH, so this is what makes the app work on a Mac with no Node at all.
NODE_BIN := $(shell zsh -lc 'command -v node' 2>/dev/null)

dist: bundle
	@test -n "$(NODE_BIN)" || (echo "✗ no node found to bundle"; exit 1)
	@cp "$(NODE_BIN)" $(RES)/node
	@echo "  node: $(NODE_BIN) → $(RES)/node  ($$(du -h "$(NODE_BIN)" | cut -f1))"
	@echo "⚠ signing is still the LOCAL cert — see Phase 5 for Developer ID + notarisation"
	@echo "built $(APP) with a bundled runtime  ($$(du -sh $(APP) | cut -f1))"

## signing-setup — create the local signing certificate (idempotent)
##
## Creates it rather than telling you to open Keychain Access, because that app
## was removed in macOS 26 and the certificate assistant went with it.
signing-setup:
	@bash scripts/create-signing-cert.sh "$(SIGN_NAME)"
	@echo "  next:  make reset-permissions && make bundle"

## reset-permissions — clear Fovea's TCC grants
##
## Needed ONCE when moving off ad-hoc signing: the old grants are pinned to a
## cdhash that no longer exists, so they linger as entries that look granted and
## behave as denied. Also the way out if the permission state ever gets stuck.
reset-permissions:
	@for svc in Accessibility ScreenCapture Microphone SpeechRecognition; do \
		tccutil reset $$svc com.fovea.capture >/dev/null 2>&1 \
			&& echo "  reset $$svc" || echo "  reset $$svc (nothing to reset)"; \
	done
	@echo "now: open $(APP)  →  Grant permissions…"

clean:
	@rm -rf $(CAPTURE_DIR)/.build node_modules packages/*/dist build

## record — session recorder (double-tap Right Option to start, tap to stop)
##
## The binary mints and names the session directory itself now (sessions/<stamp>),
## on the FIRST hold — so a run where you never record leaves nothing behind.
## It writes events.jsonl into that directory, hence no shell redirect here.
record: $(DEBUG_BIN)
	@$(DEBUG_BIN) record --out sessions

## transcribe — narration → words on the session clock (needs SARVAM_API_KEY)
## Builds alignment first: the script imports the deictic normaliser from its
## dist/, and a fresh clone (or a `make clean`) has no dist at all.
transcribe:
	@npm run build -w @fovea/alignment --silent
	@node scripts/transcribe.mjs $(SESSION)

## brief — render a transcribed session into the brief a coding agent consumes
##
## Credentials are stripped and the renderer refuses to write if any survive —
## Fovea reads the screen, and screens have secrets on them.
brief:
	@npm run build -w @fovea/alignment --silent
	@node scripts/render-brief.mjs $(SESSION)

## summarize — three lines about the session, FOR YOUR SCREEN ONLY
##
## Written to review-summary.txt, which `send` does not copy: the coding agent
## receives evidence and states its own reading back, and an interpretation
## shipped alongside would undo that. Never fatal — no key, no summary, no fuss.
summarize:
	@node scripts/summarize.mjs $(SESSION)

## send — hand a rendered brief to Claude Code (the approval step)
##
## Nothing reaches your editor until you run this. A tool that injected itself
## the moment you stopped talking is a tool you would stop trusting.
send:
	@node scripts/send-brief.mjs $(SESSION)

## bridge-install — register the MCP server with Claude Code, once
bridge-install:
	@claude mcp add fovea --scope user -- node "$(CURDIR)/apps/bridge/src/server.mjs"
	@echo "  then, in any repo:  /fovea:brief  (VS Code)  ·  /mcp__fovea__brief  (CLI)"

## bridge-test — drive the bridge over MCP, no Claude Code needed
bridge-test:
	@node scripts/bridge-smoke.mjs

## show-brief — print exactly what the bridge would hand Claude Code
##
## Not the same as the session's brief.md: the server appends the crop section
## at delivery. That section is what tells the agent how to treat screenshots,
## so it is the part you want when asking why it did or didn't open one.
##
##   make show-brief              → stdout
##   make show-brief OUT=/tmp/b.md → a file
show-brief:
	@node scripts/show-brief.mjs $(OUT)

## ground — score how well a session resolved its referents, and check M1
##
## The companion to `align`: that one scores which utterance bound to which
## referent, this one scores whether the referent knows what it is. Needs no
## transcript — grounding is decided at capture time.
ground:
	@node scripts/ground-report.mjs $(SESSION)

## align — run the T0.2 gate harness over a transcribed session
## Needs @fovea/alignment built: the script imports both the aligner and the
## session loader from its dist/.
align:
	@npm run build -w @fovea/alignment --silent
	@node scripts/align-session.mjs $(SESSION)
