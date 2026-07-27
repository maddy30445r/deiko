.PHONY: dev build test probe watch region clean setup

CAPTURE_DIR := apps/capture
DEBUG_BIN   := $(CAPTURE_DIR)/.build/debug/fovea-capture
RELEASE_BIN := $(CAPTURE_DIR)/.build/release/fovea-capture

## dev — build the capture binary and verify the Swift→Node stdio contract
dev: $(DEBUG_BIN)
	@node scripts/hello.mjs

$(DEBUG_BIN): $(wildcard $(CAPTURE_DIR)/Sources/FoveaCapture/*.swift) $(CAPTURE_DIR)/Package.swift
	@swift build --package-path $(CAPTURE_DIR)

## build — release binary
build:
	@swift build --package-path $(CAPTURE_DIR) -c release
	@echo "built $(RELEASE_BIN)"

## test — TypeScript workspace tests
test:
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

bundle: $(DEBUG_BIN)
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS
	@cp $(CAPTURE_DIR)/Sources/FoveaCapture/Info.plist $(APP)/Contents/Info.plist
	@cp $(DEBUG_BIN) $(APP)/Contents/MacOS/fovea-capture
	@/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string fovea-capture" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" $(APP)/Contents/Info.plist >/dev/null 2>&1 || true
	@codesign --force --deep --sign - $(APP) 2>/dev/null
	@echo "built $(APP)"
	@echo "launch it:  open $(APP)      (menu-bar app; permissions attach to Fovea)"
	@echo "subcommand: $(APP)/Contents/MacOS/fovea-capture <cmd>"

clean:
	@rm -rf $(CAPTURE_DIR)/.build node_modules packages/*/dist build

## record — push-to-talk session recorder (hold Right Option)
## Events go to sessions/<stamp>/events.jsonl, crops to sessions/<stamp>/crops.
record: $(DEBUG_BIN)
	@stamp=$$(date +%Y%m%d-%H%M%S); \
	dir=sessions/$$stamp; \
	mkdir -p $$dir/crops; \
	echo "session → $$dir"; \
	$(DEBUG_BIN) record --out $$dir --session $$stamp > $$dir/events.jsonl

## transcribe — narration → words on the session clock (needs SARVAM_API_KEY)
transcribe:
	@node scripts/transcribe.mjs $(SESSION)

## align — run the T0.2 gate harness over a transcribed session
align:
	@npm run build -w @fovea/alignment --silent
	@node scripts/align-session.mjs $(SESSION)
