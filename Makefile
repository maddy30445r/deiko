.DEFAULT_GOAL := help
.PHONY: help setup build test bundle bundle-unsigned sign install dmg dist release guard-clean \
	resources icon signing-setup reset-permissions clean relay-deploy relay-dev site-deploy \
	models-publish record transcribe brief summarize classify task-notes reclassify \
	meaning-backfill eval ground flow-check

MACOS       := apps/macos
CORE        := packages/core
DEBUG_BIN   := $(MACOS)/.build/debug/deiko-capture
RELEASE_BIN := $(MACOS)/.build/release/deiko-capture
APP         := build/Deiko.app
RES         := $(APP)/Contents/Resources
VERSION     := $(shell cat VERSION 2>/dev/null || echo 0.0.0)
BUILD       := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
DMG         := build/Deiko-$(VERSION).dmg

# Sign with a stable certificate when one exists. An ad-hoc signature pins the
# binary's hash, so macOS drops every permission grant on each rebuild.
# `find-identity` without -v: a self-signed identity signs fine untrusted.
SIGN_NAME  ?= Deiko Local
SIGN_FOUND := $(shell security find-identity -p codesigning 2>/dev/null | grep -c '"$(SIGN_NAME)"')
SIGN_ID    := $(if $(filter 0,$(SIGN_FOUND)),-,$(SIGN_NAME))
# Notarization requires a secure timestamp and the hardened runtime.
SIGN_EXTRA := $(if $(findstring Developer ID,$(SIGN_ID)),--timestamp --options runtime,)

# Stamped values default from .env (parsed by the shell, as everywhere else).
# `?=` keeps an explicit `make install RELAY_URL=` meaning "none".
env-default = $(shell set -a; [ -f .env ] && . ./.env; set +a; printf %s "$$$(1)")
RELAY_URL     ?= $(call env-default,RELAY_URL)
SITE_URL      ?= $(call env-default,SITE_URL)
BUY_URL       ?= $(call env-default,BUY_URL)
SUPPORT_EMAIL ?= $(call env-default,SUPPORT_EMAIL)

# The app's "Sort briefs into tasks" switch, as passed by the app or as saved.
SORT_BRIEFS = DEIKO_SORT_BRIEFS="$${DEIKO_SORT_BRIEFS-$$(defaults read com.deiko.capture DEIKO_SORT_BRIEFS 2>/dev/null)}"
ROOT ?= $(HOME)/Library/Application Support/Deiko
NODE_BIN := $(shell zsh -lc 'command -v node' 2>/dev/null)

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | expand -t22

# ── Build ──────────────────────────────────────────────────────────────────

setup: ## Install Node dependencies
	@npm install

$(DEBUG_BIN): $(wildcard $(MACOS)/Sources/*/*.swift) $(MACOS)/Package.swift
	@swift build --package-path $(MACOS)

build: ## Build the release binary
	@swift build --package-path $(MACOS) -c release
	@echo "built $(RELEASE_BIN)"

test: ## Run the Swift and Node test suites
	@swift test --package-path $(MACOS)
	@npm test

bundle: bundle-unsigned sign ## Assemble and sign build/Deiko.app (dev loop)

bundle-unsigned: $(DEBUG_BIN) resources
	@cp $(MACOS)/Sources/DeikoCapture/Info.plist $(APP)/Contents/Info.plist
	@cp $(DEBUG_BIN) $(APP)/Contents/MacOS/deiko-capture
	@cp $(MACOS)/Sources/DeikoCapture/Deiko.icns $(RES)/Deiko.icns
	@cp $(MACOS)/Sources/DeikoCapture/Bricolage.ttf $(MACOS)/Sources/DeikoCapture/Bricolage-OFL.txt $(RES)/
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :DeikoRelayURL $(RELAY_URL)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :DeikoSiteURL $(SITE_URL)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :DeikoBuyURL $(BUY_URL)" $(APP)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :DeikoSupportEmail $(SUPPORT_EMAIL)" $(APP)/Contents/Info.plist
	@echo "  relay: $(if $(RELAY_URL),$(RELAY_URL),none — sessions fall back to on-device words)"
	@echo "  site: $(if $(SITE_URL),$(SITE_URL),none — no update check)"
	@echo "  buy: $(if $(BUY_URL),$(BUY_URL),none — Pro is not purchasable in this build)"
	@echo "  support: $(if $(SUPPORT_EMAIL),$(SUPPORT_EMAIL),none — no feedback affordance)"
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string deiko-capture" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@echo "assembled $(APP)  (unsigned)"

# The bundle keeps the pipeline at Resources/scripts: agents' MCP configs hold
# that absolute path, so it must not move between releases.
resources:
	@rm -rf $(RES)
	@mkdir -p $(RES)/scripts $(RES)/node_modules/@deiko/alignment $(RES)/node_modules/@huggingface $(APP)/Contents/MacOS
	@npm run build --workspaces --if-present --silent >/dev/null
	@rsync -a --delete $(CORE)/src/ $(RES)/scripts/
	@rsync -a --exclude 'test/' packages/alignment/package.json packages/alignment/dist $(RES)/node_modules/@deiko/alignment/
	@test -f node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64/onnxruntime_binding.node \
	  || (echo "✗ onnxruntime-node's macOS binary is missing — run npm ci"; exit 1)
	@rsync -a --delete node_modules/onnxruntime-node node_modules/onnxruntime-common $(RES)/node_modules/
	@rsync -a --delete node_modules/@huggingface/tokenizers $(RES)/node_modules/@huggingface/
	@# Keep only the macOS arm64 runtime, and drop the unused versioned dylib copy.
	@find $(RES)/node_modules/onnxruntime-node/bin -mindepth 2 -maxdepth 2 -type d ! -name darwin -exec rm -rf {} +
	@find $(RES)/node_modules/onnxruntime-node/bin -mindepth 3 -maxdepth 3 -type d ! -name arm64 -exec rm -rf {} +
	@rm -f $(RES)/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64/libonnxruntime.1.30.0.dylib
	@rsync -a --delete $(MACOS)/licenses $(RES)/
	@echo "  resources: pipeline, alignment, onnxruntime (darwin arm64), tokenizers, licences"

# Signing runs last so the seal covers every byte. Nested code that is already
# signed (the bundled Node) keeps its own signature: no --deep when signing,
# but --deep when verifying.
sign: ## Sign the bundle and verify the seal
	@find $(RES)/node_modules \( -name '*.node' -o -name '*.dylib' \) -type f 2>/dev/null \
	  | while read -r f; do codesign --force --sign "$(SIGN_ID)" $(SIGN_EXTRA) "$$f" 2>/dev/null \
	  || { echo "✗ could not sign $$f"; exit 1; }; done
ifeq ($(SIGN_FOUND),0)
	@codesign --force --sign - $(APP) 2>/dev/null
	@echo "signed $(APP)  ⚠ ad-hoc: macOS drops permissions on every rebuild — run make signing-setup"
else
	@codesign --force --sign "$(SIGN_NAME)" $(APP) 2>/dev/null
	@echo "signed $(APP)  ($(SIGN_NAME))"
endif
	@codesign --verify --strict --deep $(APP) \
	  || (echo "✗ the seal does not match the bundle — something was added after signing"; exit 1)
	@echo "  seal verified"

# Replaces the app wholesale (cp -R would merge into the old bundle), then
# restarts Finder and the Dock, which otherwise keep a stale icon.
install: bundle ## Install the build into /Applications and relaunch it
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
	@echo "installed and running: /Applications/Deiko.app"

# The shippable bundle: release binary plus a Node runtime, so the app works on
# a Mac without Node. The runtime is the maintainer's; refuse obvious mistakes.
dist: build bundle-unsigned ## Build the shippable bundle with its Node runtime
	@test -n "$(NODE_BIN)" || (echo "✗ no node found to bundle"; exit 1)
	@test "$$($(NODE_BIN) -p 'process.versions.node.split(".")[0]')" -ge 22 \
	  || (echo "✗ bundled node is $$($(NODE_BIN) -v), the scripts need >= 22"; exit 1)
	@file "$(NODE_BIN)" | grep -q arm64 \
	  || (echo "✗ bundled node is not arm64: $$(file '$(NODE_BIN)')"; exit 1)
	@cp $(RELEASE_BIN) $(APP)/Contents/MacOS/deiko-capture
	@cp "$(NODE_BIN)" $(RES)/node
	@echo "  node: $(NODE_BIN) ($$($(NODE_BIN) -v), arm64)"
	@$(MAKE) --no-print-directory sign
	@echo "built $(APP) with a bundled runtime  ($$(du -sh $(APP) | cut -f1))"

dmg: dist ## Build build/Deiko-<version>.dmg
	@rm -rf build/dmg $(DMG)
	@mkdir -p build/dmg
	@cp -R $(APP) build/dmg/
	@ln -s /Applications build/dmg/Applications
	@cp docs/install.md 'build/dmg/Read me first.md'
	@hdiutil create -volname "Deiko $(VERSION)" -srcfolder build/dmg -ov -format UDZO -quiet $(DMG)
	@echo "built $(DMG)  ($$(du -h $(DMG) | cut -f1))"

# ── Release ────────────────────────────────────────────────────────────────

# A release must name its URLs on the command line: they are baked into a
# shipped plist and can never be corrected remotely, so .env is not enough.
release: guard-clean ## Publish a DMG to the site and tag the commit
	@test '$(origin SITE_URL)' = 'command line' \
		|| (echo "✗ pass SITE_URL= explicitly — a release must not inherit .env"; exit 1)
	@test '$(origin RELAY_URL)' = 'command line' \
		|| (echo "✗ pass RELAY_URL= explicitly — a release must not inherit .env"; exit 1)
	@test -z "$$(git tag -l 'v$(VERSION)' -l '$(VERSION)')" \
		|| (echo "✗ $(VERSION) is already tagged — bump VERSION first"; exit 1)
	@test -n "$(BUY_URL)" || echo "  ! BUY_URL is empty — this build shows no way to buy Pro"
	@test -n "$(SUPPORT_EMAIL)" || echo "  ! SUPPORT_EMAIL is empty — this build shows no way to send feedback"
	@# Every install downloads the meaning model on launch, so the mirror must be
	@# complete first. VERIFY_ORIGIN checks it through another host of the same
	@# Pages project when a network intercepts the main domain.
	@for url in $$(node -e "import('./$(CORE)/src/lib/meaning.mjs').then(({ MODELS, DEFAULT_MODEL, MODEL_BASE_URL }) => { const base = process.env.VERIFY_ORIGIN ? process.env.VERIFY_ORIGIN.replace(/\/+$$/, '') + '/download/models' : MODEL_BASE_URL; for (const f of MODELS[DEFAULT_MODEL].files) console.log(base.replace(/\/+$$/, '') + '/' + DEFAULT_MODEL + '/' + f.path); } )"); do \
		curl -fsI "$$url" >/dev/null || { echo "✗ model mirror is missing $$url — upload it before releasing"; exit 1; }; \
	done
	@echo "  model mirror: all files present"
	@$(MAKE) --no-print-directory dmg RELAY_URL='$(RELAY_URL)' SITE_URL='$(SITE_URL)' BUY_URL='$(BUY_URL)' SUPPORT_EMAIL='$(SUPPORT_EMAIL)'
	@SITE_URL=$(SITE_URL) ./scripts/publish-release.sh $(DMG) $(VERSION)
	@git tag v$(VERSION)
	@git push origin v$(VERSION)
	@echo "✓ v$(VERSION) tagged and published"

guard-clean:
	@test -z "$$(git status --porcelain)" \
		|| (echo "✗ working tree is dirty — commit before releasing"; git status --short; exit 1)

models-publish: ## Upload the meaning model to the download mirror
	@set -a; [ -f .env ] && . ./.env; set +a; ./scripts/publish-models.sh

site-deploy: ## Deploy the website (a separate checkout at apps/web)
	@test -x apps/web/deploy.sh || (echo "✗ the website is a separate repository; check it out at apps/web"; exit 1)
	@./apps/web/deploy.sh

relay-deploy: ## Deploy the relay to AWS Lambda (keys from .env)
	@set -a; [ -f .env ] && . ./.env; set +a; ./services/relay/deploy.sh

relay-dev: ## Run the relay locally (meters in memory)
	@set -a; [ -f .env ] && . ./.env; set +a; node services/relay/src/local.mjs

# ── Maintenance ────────────────────────────────────────────────────────────

icon: $(DEBUG_BIN) ## Regenerate Deiko.icns from the drawn mark
	@$(DEBUG_BIN) icon --out build/Deiko.iconset
	@iconutil -c icns build/Deiko.iconset -o $(MACOS)/Sources/DeikoCapture/Deiko.icns
	@echo "✓ $(MACOS)/Sources/DeikoCapture/Deiko.icns"

signing-setup: ## Create the local signing certificate (once)
	@bash scripts/create-signing-cert.sh "$(SIGN_NAME)"
	@echo "  next:  make reset-permissions && make bundle"

reset-permissions: ## Clear Deiko's macOS permission grants
	@for svc in Accessibility ScreenCapture Microphone SpeechRecognition; do \
		tccutil reset $$svc com.deiko.capture >/dev/null 2>&1 \
			&& echo "  reset $$svc" || echo "  reset $$svc (nothing to reset)"; \
	done

clean: ## Remove build output and dependencies
	@rm -rf $(MACOS)/.build node_modules packages/*/dist build

# ── Pipeline (the app runs these in a development checkout) ────────────────

record: $(DEBUG_BIN) ## Record a session from the command line
	@$(DEBUG_BIN) record --out sessions

transcribe: ## Transcribe SESSION
	@npm run build -w @deiko/alignment --silent
	@node $(CORE)/src/transcribe.mjs $(SESSION)

brief: ## Render SESSION into a brief
	@npm run build -w @deiko/alignment --silent
	@node $(CORE)/src/render-brief.mjs $(SESSION)

summarize: ## Write SESSION's review summary
	@node $(CORE)/src/summarize.mjs $(SESSION)

classify: ## File SESSION into a project and task
	@$(SORT_BRIEFS) node $(CORE)/src/classify.mjs $(SESSION)

task-notes: ## Rebuild every task note under the board SESSION
	@node $(CORE)/src/task-notes.mjs $(SESSION)

reclassify: ## Re-render and re-file every brief under ROOT, oldest first
	@npm run build -w @deiko/alignment --silent
	@for d in "$(ROOT)"/2*-*; do \
		node $(CORE)/src/render-brief.mjs "$$d" >/dev/null 2>&1 || echo "· $$d did not render"; \
		$(SORT_BRIEFS) node $(CORE)/src/classify.mjs "$$d"; \
		node $(CORE)/src/render-brief.mjs "$$d" >/dev/null 2>&1 || true; \
	done

meaning-backfill: ## Write missing meaning vectors under ROOT
	@node $(CORE)/src/meaning.mjs backfill "$(ROOT)"

# ── Quality ────────────────────────────────────────────────────────────────

eval: ## Score filing against an answer key (ARGS=…)
	@set -a; [ -f .env ] && . ./.env; set +a; $(SORT_BRIEFS) node evals/filing.mjs $(ARGS)

ground: ## Score how well SESSION resolved what was pointed at
	@node evals/grounding.mjs $(SESSION)

flow-check: ## Render and file real briefs end to end against a local relay
	@./scripts/flow-check.sh
