.PHONY: dev build test probe watch region clean setup bundle install icon dmg release guard-clean relay-deploy relay-dev site-deploy resources dist record transcribe align ground brief summarize signing-setup reset-permissions

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
SIGN_NAME  ?= Deiko Local
SIGN_FOUND := $(shell security find-identity -p codesigning 2>/dev/null | grep -c '"$(SIGN_NAME)"')

CAPTURE_DIR := apps/capture
DEBUG_BIN   := $(CAPTURE_DIR)/.build/debug/deiko-capture
RELEASE_BIN := $(CAPTURE_DIR)/.build/release/deiko-capture

## dev — build the capture binary and verify the Swift→Node stdio contract
dev: $(DEBUG_BIN)
	@node scripts/hello.mjs

# Every Sources subtree, not just DeikoCapture — the pure targets (DeikoGesture,
# DeikoVoice, DeikoGrounding) are where the testable logic lives, and a rule that
# does not watch them silently runs the old binary against the new tests.
$(DEBUG_BIN): $(wildcard $(CAPTURE_DIR)/Sources/*/*.swift) $(CAPTURE_DIR)/Package.swift
	@swift build --package-path $(CAPTURE_DIR)

## build — release binary
build:
	@swift build --package-path $(CAPTURE_DIR) -c release
	@echo "built $(RELEASE_BIN)"

## test — Swift gesture tests + TypeScript workspace tests + scripts/ tests
test:
	@swift test --package-path $(CAPTURE_DIR)
	@npm test

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

## bundle — assemble Deiko.app around the binary
##
## Needed because TCC will not honour usage descriptions from a bare SwiftPM
## executable: requesting Speech Recognition from one is killed with SIGABRT,
## and `tccutil` does not even recognise its identifier. Linking the plist in as
## a __TEXT,__info_plist section satisfies codesign but not TCC.
##
## It is also where the product is going regardless — a menu-bar app (PRD §7) —
## and it fixes the permission model: permissions attach to Deiko.app instead of
## to whichever terminal happened to launch the binary.
APP := build/Deiko.app
RES := $(APP)/Contents/Resources

# ONE version in the product. `VERSION` is the source; it is stamped into the
# bundle below, and `DeikoVersion` reads it back out at runtime. There used to
# be two hardcoded literals with nothing keeping them in sync.
VERSION := $(shell cat VERSION 2>/dev/null || echo 0.0.0)
# The build number distinguishes two shipped copies of one version. A commit
# count is monotonic, requires nothing to be maintained by hand, and is 1 in a
# tarball with no git — which is honest rather than wrong.
BUILD := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

# Where the landing site's built static files are. Overridable because the
# generator has not been chosen yet.
SITE_DIR ?= site

# THE FOUR STAMPED VALUES DEFAULT FROM `.env`, and the reason is a shipped bug.
#
# `make install RELAY_URL=https://…` produced a correct app. The next plain
# `make install` re-stamped all four to EMPTY — `RELAY_URL` was never even
# declared here, so it expanded to nothing — and the app then reported "relay
# configured: none" while the brief it produced said `degraded: false`. A day of
# sessions came out of the on-device recogniser ("using Daku" for "using Deiko")
# and read as the alignment being broken. A default that is empty is a default
# that is wrong every time somebody forgets an argument.
#
# THE SHELL PARSES `.env`, NOT MAKE. Same read `scripts/deploy-site.sh` and
# `BriefPipeline.shell` already do, so a value containing `=`, quotes or spaces
# means what it means everywhere else and there is one parser rather than a
# second one written in sed. `[ -f .env ]` because a tarball has none.
#
# `?=`, NOT `:=` — this is what keeps the invariant below true. A variable given
# on the command line has origin `command line`, for which `?=` is a no-op, so
# `make install RELAY_URL=` still builds a relay-less app deliberately.
#
# ponytail: sourcing .env executes whatever is in it at parse time; the same
# exposure already exists in the two other paths that source the same file.
env-default = $(shell set -a; [ -f .env ] && . ./.env; set +a; printf %s "$$$(1)")

RELAY_URL     ?= $(call env-default,RELAY_URL)

# WHERE THE SITE IS SERVED FROM, once it has a domain.
#
# ONE download location, and it is the site — the same place the landing page,
# the pricing and the docs live. The app fetches `$(SITE_URL)/download/version.json`
# to find out whether it is out of date, and `install.sh` fetches the DMG from
# beside it.
#
# Empty is still a supported state: an app with no site URL simply never checks
# for updates, exactly as an app with no RELAY_URL transcribes on-device. Better
# than pointing at a host that does not answer. It is now something you ASK for
# — `make install SITE_URL=` — rather than something you get by forgetting.
#
# This deliberately does NOT use GitHub Releases. It would be free bandwidth,
# but it is a second place to publish and to keep in step, and its unauthenticated
# API allows 60 requests/hour PER IP — a team behind one NAT shares that budget
# for a check that should never be able to fail noisily. A static JSON on
# CloudFront has no such limit.
SITE_URL ?= $(call env-default,SITE_URL)

# WHERE SOMEBODY BUYS PRO, and where a bug report goes.
#
# Separate from SITE_URL on purpose, and the reason is not tidiness: as this is
# written the published site answers 404 on every path, including the
# `download/version.json` the update check reads. A checkout link derived from
# the site would therefore appear in builds where it cannot work — and a Get Pro
# button that 404s fails at the exact moment somebody decided to pay, which is
# the worst moment a product can look unfinished.
#
# Empty is a supported state for both: the app hides every buy affordance
# without a BUY_URL, and hides "Send feedback…" without a SUPPORT_EMAIL. Same
# discipline as RELAY_URL — a stamped constant beats a source literal that is
# wrong in somebody's local build, and absent beats broken. Both default from
# `.env` now; an explicit `BUY_URL=` still stamps empty.
BUY_URL ?= $(call env-default,BUY_URL)
SUPPORT_EMAIL ?= $(call env-default,SUPPORT_EMAIL)

## bundle — the dev loop's app: assemble, then sign.
##
## SIGNING IS ITS OWN TARGET AND IT RUNS LAST. It used to be the tail of this
## one, which was fine until `dist` started copying a 110MB Node runtime into
## Contents/Resources AFTER the seal had been computed over a bundle that did
## not contain it. Every DMG ever handed to anybody — 0.3.0, 0.4.0, 0.4.1 —
## failed `codesign --verify` with "a sealed resource is missing or invalid",
## and Gatekeeper rejected all three. Nothing caught it because nothing ever
## verified. Now assembling and sealing are separate steps, `dist` puts every
## byte in place before calling `sign`, and `sign` verifies or fails the build.
bundle: bundle-unsigned sign

bundle-unsigned: $(DEBUG_BIN) resources
	@cp $(CAPTURE_DIR)/Sources/DeikoCapture/Info.plist $(APP)/Contents/Info.plist
	@cp $(DEBUG_BIN) $(APP)/Contents/MacOS/deiko-capture
	@cp $(CAPTURE_DIR)/Sources/DeikoCapture/Deiko.icns $(RES)/Deiko.icns
	@# The title face. Registered per-process at launch (see Style.swift), so
	@# it is never installed on anybody's Mac; missing it only drops the app
	@# back to the system face.
	@cp $(CAPTURE_DIR)/Sources/DeikoCapture/Bricolage.ttf $(RES)/Bricolage.ttf
	@cp $(CAPTURE_DIR)/Sources/DeikoCapture/Bricolage-OFL.txt $(RES)/Bricolage-OFL.txt
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :DeikoRelayURL $(RELAY_URL)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :DeikoSiteURL $(SITE_URL)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :DeikoBuyURL $(BUY_URL)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :DeikoSupportEmail $(SUPPORT_EMAIL)" $(APP)/Contents/Info.plist
ifneq ($(RELAY_URL),)
	@echo "  relay: $(RELAY_URL)"
else
	@echo "  relay: none — sessions fall back to on-device words"
endif
	@# ALL FOUR, because the one that was wrong was the one nobody printed. Each
	@# decides whether a whole affordance exists — updates, the buy button,
	@# "Send feedback…" — and a blank here is the only warning before a build
	@# that silently lacks it.
	@echo "  site: $(if $(SITE_URL),$(SITE_URL),none — no update check)"
	@echo "  buy: $(if $(BUY_URL),$(BUY_URL),none — Pro is not purchasable in this build)"
	@echo "  support: $(if $(SUPPORT_EMAIL),$(SUPPORT_EMAIL),none — no feedback affordance)"
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string deiko-capture" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@echo "assembled $(APP)  (unsigned)"

## sign — seal the bundle, then prove the seal.
##
## NO `--deep` ON THE SIGNATURE. `--deep` re-signs everything nested inside,
## which for us means Contents/Resources/node — a binary that already carries
## Node Foundation's own Developer ID signature and hardened runtime. Replacing
## that with ours strips both and buys nothing; Apple deprecated `--deep` for
## signing for exactly this reason. Nested code that arrives already signed
## stays that way, and the outer seal simply records it.
##
## `--deep` on VERIFY is the opposite and is correct: it walks the nested code
## and checks it, which is what catches a resource added after sealing.
sign:
ifeq ($(SIGN_FOUND),0)
	@codesign --force --sign - $(APP) 2>/dev/null
	@echo "signed $(APP)  ⚠ AD-HOC"
	@echo "   macOS will drop all four permissions on the next rebuild."
	@echo "   Fix it once:  make signing-setup"
else
	@codesign --force --sign "$(SIGN_NAME)" $(APP) 2>/dev/null
	@echo "signed $(APP)  ($(SIGN_NAME) — permissions survive rebuilds)"
endif
	@codesign --verify --strict --deep $(APP) \
	  || (echo "✗ the seal does not match the bundle — something was added after signing"; exit 1)
	@echo "  seal verified"
	@echo "launch it:  open $(APP)      (menu-bar app; permissions attach to Deiko)"
	@echo "subcommand: $(APP)/Contents/MacOS/deiko-capture <cmd>"

## install — put this build in /Applications and restart it
##
## `cp -R build/Deiko.app /Applications/` is the obvious command and it is
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
	@osascript -e 'quit app "Deiko"' 2>/dev/null || true
	@sleep 1
	@rm -rf /Applications/Deiko.app
	@cp -R $(APP) /Applications/
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R /Applications/Deiko.app
	@touch /Applications/Deiko.app /Applications/Deiko.app/Contents/Info.plist
	@find "$$(getconf DARWIN_USER_CACHE_DIR)" -name com.apple.dock.iconcache -delete 2>/dev/null || true
	@find "$$(getconf DARWIN_USER_CACHE_DIR)" -maxdepth 2 -name com.apple.iconservices -type d -exec rm -rf {} + 2>/dev/null || true
	@killall Dock 2>/dev/null || true
	@killall Finder 2>/dev/null || true
	@sleep 2
	@open /Applications/Deiko.app
	@echo "installed and running: /Applications/Deiko.app  (Dock + Finder restarted)"
	@echo "verify: /Applications/Deiko.app/Contents/MacOS/deiko-capture diagnostics | grep relay"

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
DMG := build/Deiko-$(VERSION).dmg

dmg: dist
	@rm -rf build/dmg $(DMG)
	@mkdir -p build/dmg
	@cp -R $(APP) build/dmg/
	@ln -s /Applications build/dmg/Applications
	@cp README.md build/dmg/
	@# THE ONE-LINER ONLY APPEARS WHEN THERE IS A HOST TO FETCH IT FROM. Built
	@# with an empty SITE_URL it rendered as `curl -fsSL /install.sh | sh` —
	@# which is exactly what the 0.4.1 DMG on disk still offers, and it cannot
	@# work. `make release` requires SITE_URL, so a real release always carries
	@# the offer; a hand-built DMG gets the by-hand steps and no broken promise.
	@printf '%s\n' 'Deiko $(VERSION)' '' > 'build/dmg/Read me first.txt'
ifneq ($(SITE_URL),)
	@printf '%s\n' \
		'EASIEST: skip this disk image entirely. Paste this into Terminal and' \
		'it does all of the below for you:' \
		'' \
		'     curl -fsSL $(SITE_URL)/install.sh | sh' \
		'' \
		'' \
		>> 'build/dmg/Read me first.txt'
endif
	@printf '%s\n' \
		'BY HAND:' \
		'' \
		'1. Drag Deiko onto the Applications folder.' \
		'' \
		'2. BEFORE LAUNCHING, run this once in Terminal:' \
		'' \
		'     xattr -dr com.apple.quarantine /Applications/Deiko.app' \
		'' \
		'   Deiko is signed with a self-signed certificate rather than an' \
		'   Apple Developer ID, so macOS quarantines everything you just' \
		'   downloaded. This clears the whole bundle -- including the Node' \
		'   runtime inside it that Deiko spawns to transcribe your sessions.' \
		'' \
		'   The GUI route (System Settings -> Privacy & Security -> "Open' \
		'   Anyway") lets the app start, but may leave that nested runtime' \
		'   quarantined -- which turns up later as a session stuck at' \
		'   "Transcribing...". The command above avoids that.' \
		'' \
		'   Right-click -> Open is NOT enough on current macOS.' \
		'' \
		'3. Launch it. Deiko lives in the menu bar, and a first-run window' \
		'   explains the four permissions it needs and why.' \
		'' \
		'4. Double-tap Right Option, point at something and talk, tap Right' \
		'   Option to stop — then drag the resulting coin onto your Claude' \
		'   Code window.' \
		'' \
		'Requires macOS 14 or later.' \
		'' \
		'Full documentation: README.md, beside this file.' \
		>> 'build/dmg/Read me first.txt'
	@hdiutil create -volname "Deiko $(VERSION)" -srcfolder build/dmg \
		-ov -format UDZO -quiet $(DMG)
	@echo "built $(DMG)  ($$(du -h $(DMG) | cut -f1))"
	@echo "  the app inside is SELF-SIGNED — the receiver must bypass Gatekeeper."
	@echo "  'Read me first.txt' in the window tells them how."

## release — publish the DMG on the site and tag the commit it came from
##
##   make release RELAY_URL=https://… SITE_URL=https://…
##
## ONE download location, and it is the site. This used to cut a GitHub Release
## on the private source repo, which made repo access the access list: an asset
## returned a bare 404 to anyone who was not a collaborator, which reads like a
## broken link rather than a permission problem. Correct for a team of three,
## wrong for a stranger who wants to try the app.
##
## The TAG STILL LANDS HERE, on the source, because that is what a version has
## to be checkable against — the site holds the binary, this repo holds the
## commit that produced it.
##
## Refuses on a dirty tree or an existing tag. A release whose contents do not
## correspond to a commit is worse than no release: the first bug report cites
## a version that cannot be checked out.
release: guard-clean
	@# ORIGIN, NOT EMPTINESS. These four now default from `.env`, so `-n` stopped
	@# proving anybody meant it: a release would silently inherit whichever relay
	@# happened to be in the developer's dotfile. A release is the one build whose
	@# URLs are baked into a shipped plist and can never be corrected remotely, so
	@# it must say them out loud on the command line.
	@test '$(origin SITE_URL)' = 'command line' \
		|| (echo "✗ pass SITE_URL= explicitly — a release must not inherit .env"; exit 1)
	@# The same guard for the relay, because this failure is SILENT: PlistBuddy
	@# happily stamps an empty DeikoRelayURL, every install of that release
	@# falls back to on-device words forever, and a shipped plist can never be
	@# corrected remotely. `make dmg RELAY_URL=` stays possible on purpose —
	@# hand-delivered relay-less builds are a thing — but a RELEASE is not one.
	@test '$(origin RELAY_URL)' = 'command line' \
		|| (echo "✗ pass RELAY_URL= explicitly — a release must not inherit .env"; exit 1)
	@# BOTH SPELLINGS. Releases up to 0.3.0 were tagged `vX.Y.Z`, but `0.4.1`
	@# was cut by hand without the prefix — and a guard that only knew about
	@# `v0.4.1` waved that through and would have put a second tag on the same
	@# commit. Whatever shape a version was tagged in, it counts as released.
	@test -z "$$(git tag -l 'v$(VERSION)' -l '$(VERSION)')" \
		|| (echo "✗ $(VERSION) is already tagged — bump VERSION first"; exit 1)
	@# WARNED, not refused, unlike RELAY_URL and SITE_URL above. A release with
	@# no relay meters nothing and a release nobody can download is not a
	@# release; a release with no checkout link is merely one where the buy
	@# buttons stay hidden, which is the correct behaviour when there is nothing
	@# behind them. Same for feedback. Worth saying out loud all the same,
	@# because both are easy to forget once they DO exist.
	@test -n "$(BUY_URL)" \
		|| echo "  ! BUY_URL is empty — this build shows no way to buy Pro"
	@test -n "$(SUPPORT_EMAIL)" \
		|| echo "  ! SUPPORT_EMAIL is empty — this build shows no way to send feedback"
	@$(MAKE) --no-print-directory dmg RELAY_URL='$(RELAY_URL)' SITE_URL='$(SITE_URL)' BUY_URL='$(BUY_URL)' SUPPORT_EMAIL='$(SUPPORT_EMAIL)'
	@# SITE_URL travels in the environment: publish-release.sh stamps it into
	@# version.json, and without it that falls back to a hostname nobody types.
	@# install.sh is NOT stamped here any more — it ships with the site, from
	@# scripts/deploy-site.sh, because the only thing substituted into it is the
	@# origin and that is now a constant. Publishing it from both places would
	@# race, and the loser wins at whichever path was written last.
	@SITE_URL=$(SITE_URL) ./scripts/publish-release.sh $(DMG) $(VERSION)
	@git tag v$(VERSION)
	@git push origin v$(VERSION)
	@echo "✓ v$(VERSION) tagged and published"
	@echo "  the release notes live with the site, not here — this repo ships the binary."

## Refuse to build a release out of uncommitted work.
guard-clean:
	@test -z "$$(git status --porcelain)" \
		|| (echo "✗ working tree is dirty — commit before releasing"; \
		    git status --short; exit 1)

## relay-deploy — the transcription relay onto AWS Lambda
##
##   make relay-deploy                              # keys from .env
##   SARVAM_API_KEY=… GROQ_API_KEY=… make relay-deploy
##
## Lambda because the service is idle most of the day by design — nobody is
## recording — and it is the only option that costs nothing while idle. See
## services/relay/deploy-aws.sh; it is idempotent, so this is also how you ship
## a code change.
## The keys come from .env, which .env.example tells you to create and which
## nothing else loads. Running the script directly still takes them from the
## environment only, so that stays the way to deploy with a different key.
relay-deploy:
	@set -a; [ -f .env ] && . ./.env; set +a; ./services/relay/deploy-aws.sh

## relay-dev — run the relay locally, for testing the app against it
##
##   make relay-dev
##   DEIKO_RELAY_URL=http://localhost:8787 open build/Deiko.app
relay-dev:
	@set -a; [ -f .env ] && . ./.env; set +a; node services/relay/server.mjs

## site-deploy — the landing site onto S3 + CloudFront
##
##   make site-deploy SITE_DIR=site
site-deploy:
	@./scripts/deploy-site.sh $(SITE_DIR)

## icon — regenerate Deiko.icns from the Deiko mark
##
## The .icns is COMMITTED, so `make bundle` needs nothing but a copy. Run this
## only after changing the geometry in Sources/DeikoCapture/Iconset.swift.
##
## Drawn by the binary rather than by a script: the coin, the menu bar and the
## icon are one shape, and keeping the third renderer in the same target as the
## other two is what stops it drifting.
icon: $(DEBUG_BIN)
	@$(DEBUG_BIN) icon --out build/Deiko.iconset
	@iconutil -c icns build/Deiko.iconset -o $(CAPTURE_DIR)/Sources/DeikoCapture/Deiko.icns
	@echo "✓ $(CAPTURE_DIR)/Sources/DeikoCapture/Deiko.icns"

## resources — the pipeline, inside the bundle
##
## MIRRORS THE REPO LAYOUT, and that is the whole trick. The scripts import
## their packages by relative path (`../packages/alignment/dist/src/align.js`).
## Reproduce the shape and every one of those resolves unchanged — no
## rewriting imports, no bundler, nothing to keep in sync.
##
## `make bundle` runs this every time: it is a few hundred KB of scripts and
## built packages, and a bundle whose Resources lag its binary is a bug you
## find in the DMG.
##
## No `node_modules` in the bundle any more. The bridge was the only thing that
## needed a dependency closure; every remaining script imports node builtins,
## `packages/*/dist`, or its own sibling in `scripts/lib`.
resources:
	@rm -rf $(RES)
	@mkdir -p $(RES) $(APP)/Contents/MacOS
	@npm run build --workspaces --if-present --silent >/dev/null
	@rsync -a --delete scripts $(RES)/
	@rsync -a --delete --prune-empty-dirs \
		--include='*/' --include='dist/***' --include='package.json' --exclude='*' \
		packages $(RES)/
	@echo "  resources: scripts + packages/dist"

## dist — the shippable bundle: everything in `bundle`, plus the Node runtime
##
## Node is NOT in `make bundle` on purpose. It is 106MB, and a developer's app
## resolves the pipeline from the checkout beside it anyway (see `Layout`), so
## copying it on every rebuild would cost the fast local loop and buy nothing.
## Here it is the point: `NodeRuntime` prefers a bundled runtime over anything
## on PATH, so this is what makes the app work on a Mac with no Node at all.
NODE_BIN := $(shell zsh -lc 'command -v node' 2>/dev/null)

## The runtime that ships is whichever one the maintainer's shell happens to
## resolve — an nvm default, usually. That is a wide door for shipping a
## runtime nobody chose, so the three checks below refuse the obvious mistakes:
## too old for the scripts, or the wrong architecture entirely. Pinning a
## toolchain would be the thorough fix; refusing to ship a surprise is the
## cheap one, and it catches what actually goes wrong.
##
## `dist` builds the RELEASE binary. `bundle-unsigned` stages the debug one for
## the dev loop, and this overwrites it — before `sign` runs, which is the
## whole point of the ordering. Until this line existed `make build` produced a
## release binary that nothing ever consumed and every DMG shipped debug.
dist: build bundle-unsigned
	@test -n "$(NODE_BIN)" || (echo "✗ no node found to bundle"; exit 1)
	@test "$$($(NODE_BIN) -p 'process.versions.node.split(".")[0]')" -ge 22 \
	  || (echo "✗ bundled node is $$($(NODE_BIN) -v), the scripts need >= 22"; exit 1)
	@file "$(NODE_BIN)" | grep -q arm64 \
	  || (echo "✗ bundled node is not arm64: $$(file '$(NODE_BIN)')"; exit 1)
	@cp $(RELEASE_BIN) $(APP)/Contents/MacOS/deiko-capture
	@cp "$(NODE_BIN)" $(RES)/node
	@echo "  binary: release"
	@echo "  node: $(NODE_BIN) ($$($(NODE_BIN) -v), arm64) → $(RES)/node  ($$(du -h "$(NODE_BIN)" | cut -f1))"
	@$(MAKE) --no-print-directory sign
	@echo "⚠ signing is still the LOCAL cert — see Phase 5 for Developer ID + notarisation"
	@echo "built $(APP) with a bundled runtime  ($$(du -sh $(APP) | cut -f1))"

## signing-setup — create the local signing certificate (idempotent)
##
## Creates it rather than telling you to open Keychain Access, because that app
## was removed in macOS 26 and the certificate assistant went with it.
signing-setup:
	@bash scripts/create-signing-cert.sh "$(SIGN_NAME)"
	@echo "  next:  make reset-permissions && make bundle"

## reset-permissions — clear Deiko's TCC grants
##
## Needed ONCE when moving off ad-hoc signing: the old grants are pinned to a
## cdhash that no longer exists, so they linger as entries that look granted and
## behave as denied. Also the way out if the permission state ever gets stuck.
reset-permissions:
	@for svc in Accessibility ScreenCapture Microphone SpeechRecognition; do \
		tccutil reset $$svc com.deiko.capture >/dev/null 2>&1 \
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
	@npm run build -w @deiko/alignment --silent
	@node scripts/transcribe.mjs $(SESSION)

## brief — render a transcribed session into the brief a coding agent consumes
##
## Credentials are stripped and the renderer refuses to write if any survive —
## Deiko reads the screen, and screens have secrets on them.
brief:
	@npm run build -w @deiko/alignment --silent
	@node scripts/render-brief.mjs $(SESSION)

## summarize — three lines about the session, FOR YOUR SCREEN ONLY
##
## Written to review-summary.txt, which the pasted prompt does not copy: the
## coding agent receives evidence and states its own reading back, and an
## interpretation shipped alongside would undo that. Never fatal — no key, no
## summary, no fuss.
summarize:
	@node scripts/summarize.mjs $(SESSION)

## classify — which collection a brief belongs to and which earlier briefs it
## draws on, decided by Jev through the relay and written to context.json
##
## Never fatal, like summarize: no relay, a short narration, or a brief the
## developer already placed by hand, and nothing is written. `brief` reads the
## file if it is there.
classify:
	@node scripts/classify.mjs $(SESSION)

## ground — score how well a session resolved its referents, and check M1
##
## The companion to `align`: that one scores which utterance bound to which
## referent, this one scores whether the referent knows what it is. Needs no
## transcript — grounding is decided at capture time.
ground:
	@node scripts/ground-report.mjs $(SESSION)

## bakeoff — run every recogniser over one session's audio and compare
##
##   DEIKO_KEEP_AUDIO=1 open /Applications/Deiko.app   # …record…
##   make bakeoff SESSION=~/Documents/Deiko/<id> LANGUAGE=hi-IN
##
## Apple on-device at two locales and with the session's own screen vocabulary,
## Sarvam, and both Whisper sizes — over the SAME audio, through the same
## chunker, so the comparison is of the models. Needs the WAVs, which the app
## deletes the moment a brief renders: record with DEIKO_KEEP_AUDIO=1.
##
## Optional `reference.txt` (what was actually said) and `terms.txt` (the
## identifiers in it, one per line) in the session dir turn the transcripts into
## scores. Without them it prints transcripts, which for code-mixed speech is
## the evidence anyway. Keys come from .env.
bakeoff:
	@npm run build -w @deiko/alignment --silent
	@set -a; [ -f .env ] && . ./.env; set +a; \
		node scripts/bakeoff.mjs $(SESSION) --language $(or $(LANGUAGE),hi-IN)

## align — run the T0.2 gate harness over a transcribed session
## Needs @deiko/alignment built: the script imports both the aligner and the
## session loader from its dist/.
align:
	@npm run build -w @deiko/alignment --silent
	@node scripts/align-session.mjs $(SESSION)
