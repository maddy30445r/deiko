#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# FLOW CHECK — the whole brief pipeline, end to end, on a throwaway board
#
#   make flow-check
#
# Copies a handful of real sessions into a temp dir, starts this checkout's
# relay on a local port (keys from .env, never printed), and runs each brief
# oldest first through render → classify → render, exactly as the app and
# `make reclassify` do. Then it checks every finished brief has a prompt and a
# filing, prints how each was filed, and deletes the temp dir.
#
# The real board is only ever read. FLOW_BOARD, FLOW_STAMPS, FLOW_ENV and
# FLOW_PORT override the defaults.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=${FLOW_BOARD:-$HOME/Documents/Deiko}
ENV_FILE=${FLOW_ENV:-$REPO/.env}
PORT=${FLOW_PORT:-8791}
# The pricing thread, the three briefs 0.5.0 mis-joined to it, and one
# recording that never rendered.
STAMPS=${FLOW_STAMPS:-"20260915-234710 20260915-234940 20260916-013910 20260916-212724 20260918-155836 20260918-161814 20260918-162251 20260918-162340 20260918-163139"}

TMP=$(mktemp -d)
RELAY=""
cleanup() { [ -n "$RELAY" ] && kill "$RELAY" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

BOARD="$TMP/board"
mkdir -p "$BOARD"
for s in $STAMPS; do
  [ -d "$SRC/$s" ] || { echo "✗ no session $s in $SRC"; exit 1; }
  cp -R "$SRC/$s" "$BOARD/"
  # File from scratch: drop the old filing and the one-shot marker.
  rm -f "$BOARD/$s/context.json" "$BOARD/$s/classify.sent"
done
[ -d "$SRC/personas" ] && cp -R "$SRC/personas" "$BOARD/"

(set -a; [ -f "$ENV_FILE" ] && . "$ENV_FILE"; set +a; PORT=$PORT exec node "$REPO/services/relay/local.mjs") >"$TMP/relay.log" 2>&1 &
RELAY=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/health" && break
  sleep 0.1
done

fail=0
for s in $STAMPS; do
  d="$BOARD/$s"
  if [ ! -f "$d/brief.json" ]; then
    # An unfinished recording: the pipeline must leave it alone without crashing.
    DEIKO_SORT_BRIEFS=1 DEIKO_CLASSIFY_URL="http://127.0.0.1:$PORT" DEIKO_CLASSIFY_TOKEN="dev_flowcheck0000000000000000" node "$REPO/scripts/classify.mjs" "$d" >/dev/null 2>"$TMP/$s.err" \
      || { echo "✗ $s (unfinished) crashed classify:"; tail -3 "$TMP/$s.err"; fail=1; }
    continue
  fi
  node "$REPO/scripts/render-brief.mjs" "$d" >/dev/null 2>"$TMP/$s.err" || { echo "✗ $s render failed:"; tail -3 "$TMP/$s.err"; fail=1; continue; }
  DEIKO_SORT_BRIEFS=1 DEIKO_CLASSIFY_URL="http://127.0.0.1:$PORT" DEIKO_CLASSIFY_TOKEN="dev_flowcheck0000000000000000" node "$REPO/scripts/classify.mjs" "$d" >/dev/null 2>"$TMP/$s.err" \
    || { echo "✗ $s classify failed:"; tail -3 "$TMP/$s.err"; fail=1; continue; }
  node "$REPO/scripts/render-brief.mjs" "$d" >/dev/null 2>"$TMP/$s.err" || { echo "✗ $s re-render failed:"; tail -3 "$TMP/$s.err"; fail=1; continue; }
done

node --input-type=module - "$BOARD" $STAMPS <<'EOF' || fail=1
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
const [board, ...stamps] = process.argv.slice(2);
let bad = 0;
const rows = [];
for (const s of stamps) {
  const d = join(board, s);
  if (!existsSync(join(d, "brief.json"))) { rows.push([s, "(unfinished)", "", "", ""]); continue; }
  const prompt = existsSync(join(d, "prompt.txt")) ? readFileSync(join(d, "prompt.txt"), "utf8") : "";
  const ctx = existsSync(join(d, "context.json")) ? JSON.parse(readFileSync(join(d, "context.json"), "utf8")) : null;
  if (!prompt.trim()) { console.log(`✗ ${s} has no prompt`); bad = 1; }
  if (!ctx) { console.log(`✗ ${s} was not filed`); bad = 1; continue; }
  const conf = ctx.confidence?.task ?? "";
  rows.push([s, ctx.task ?? "-", ctx.collection ?? "-", ctx.decidedBy ?? "-", String(conf)]);
}
const tasks = existsSync(join(board, "tasks.json")) ? JSON.parse(readFileSync(join(board, "tasks.json"), "utf8")) : [];
const title = (id) => tasks.find((t) => t.id === id)?.title ?? "";
console.log("stamp            task                 project   by    conf  title");
for (const [s, t, c, by, conf] of rows) console.log(`${s}  ${t.padEnd(19)}  ${c.padEnd(8)}  ${by.padEnd(4)}  ${conf.slice(0, 4).padEnd(4)}  ${title(t).slice(0, 50)}`);
process.exit(bad);
EOF

# An upstream 5xx that classify's own retry recovered from is noise, not a
# broken flow — the filings above already say whether it recovered. Crashes
# inside the relay are not.
grep -E "^unhandled" "$TMP/relay.log" | head -5 && fail=1 || true
grep -cE " 5[0-9][0-9] " "$TMP/relay.log" | awk '$1 > 0 { print "· the relay answered " $1 " request(s) with a 5xx (retried)" }' || true
# What the upstream said when it failed — status and host only, never a body.
grep -E "^upstream .* answered" "$TMP/relay.log" | sort | uniq -c | sed 's/^/· /' || true

if [ "$fail" = 0 ]; then echo "✓ flow intact"; else echo "✗ flow broken — see above"; fi
exit "$fail"
