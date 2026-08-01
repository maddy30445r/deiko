.PHONY: dev build test probe watch region clean setup bundle resources dist record transcribe align ground brief summarize send bridge-install bridge-test show-brief signing-setup reset-permissions

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

bundle: $(DEBUG_BIN) resources
	@cp $(CAPTURE_DIR)/Sources/FoveaCapture/Info.plist $(APP)/Contents/Info.plist
	@cp $(DEBUG_BIN) $(APP)/Contents/MacOS/fovea-capture
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

## record — push-to-talk session recorder (hold Right Option, Ctrl-C to stop)
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
	@npm run build -w @fovea/alignment -w @fovea/referents --silent
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

## bridge-test — drive the bridge over raw JSON-RPC, no Claude Code needed
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
## Needs BOTH packages built: the script imports alignment's aligner and
## referents' session loader from their dist/ directories.
align:
	@npm run build -w @fovea/alignment -w @fovea/referents --silent
	@node scripts/align-session.mjs $(SESSION)
