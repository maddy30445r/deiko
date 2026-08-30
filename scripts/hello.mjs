#!/usr/bin/env node
// Verifies the Swift→Node contract: spawn the capture binary, read JSON Lines
// off stdout, parse the handshake. This is T0.3's done-when.
//
// It also reports Accessibility trust, because every other capability in the
// product is downstream of that one permission.

import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const binary = resolve(root, "apps/capture/.build/debug/deiko-capture");

const child = spawn(binary, ["hello"], { stdio: ["ignore", "pipe", "pipe"] });

child.stderr.on("data", (chunk) => process.stderr.write(chunk));
child.on("error", (err) => {
  console.error(`✗ could not spawn ${binary}\n  ${err.message}`);
  console.error("  run: make dev");
  process.exit(1);
});

const events = [];
const lines = createInterface({ input: child.stdout });

lines.on("line", (line) => {
  if (!line.trim()) return;
  try {
    events.push(JSON.parse(line));
  } catch {
    console.error(`✗ stdout was not JSON — the contract says stdout is data only:\n  ${line}`);
    process.exitCode = 1;
  }
});

child.on("close", (code) => {
  const hello = events.find((e) => e.type === "hello");

  if (code !== 0 || !hello) {
    console.error(`✗ handshake failed (exit ${code}, ${events.length} events)`);
    process.exit(1);
  }

  console.log(`✓ ${hello.binary} v${hello.version} — stdio contract OK (pid ${hello.pid}, t=${hello.t.toFixed(1)}ms)`);

  if (hello.axTrusted) {
    console.log("✓ Accessibility: trusted");
  } else {
    console.log(
      [
        "",
        "⚠ Accessibility: NOT trusted — ax-probe will refuse to run.",
        "",
        "  System Settings → Privacy & Security → Accessibility",
        "  Grant the TERMINAL you run this from (Terminal.app / Warp / iTerm),",
        "  not the binary. TCC permissions attach to the launching process.",
        "  Toggle it off and on again if it is already listed but stale.",
        "",
      ].join("\n"),
    );
  }
});
