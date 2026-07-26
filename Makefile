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

clean:
	@rm -rf $(CAPTURE_DIR)/.build node_modules packages/*/dist

## record — push-to-talk session recorder (hold Right Option)
## Events go to sessions/<stamp>/events.jsonl, crops to sessions/<stamp>/crops.
record: $(DEBUG_BIN)
	@stamp=$$(date +%Y%m%d-%H%M%S); \
	dir=sessions/$$stamp; \
	mkdir -p $$dir/crops; \
	echo "session → $$dir"; \
	$(DEBUG_BIN) record --out $$dir --session $$stamp > $$dir/events.jsonl
