/**
 * A minimal MCP client over stdio, for talking to the bridge without an editor.
 *
 * Small enough to have been inlined in `bridge-smoke.mjs`, and it was — until a
 * second script needed the same twenty lines. Newline-delimited JSON is all the
 * stdio transport speaks, so this is the whole protocol surface we need; using
 * the SDK's client here would mean the test shares an implementation with the
 * thing it is testing.
 */

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
export const SERVER = join(ROOT, "apps", "bridge", "src", "server.mjs");

/**
 * Spawn the bridge and complete the MCP handshake.
 *
 * Returns `{ call, close }`. `call` rejects on a JSON-RPC error or after
 * `timeoutMs` — a hung server should fail a script, not hang it.
 */
export async function connect({ server = SERVER, timeoutMs = 10_000 } = {}) {
  const child = spawn("node", [server], { stdio: ["pipe", "pipe", "inherit"] });

  let buffer = "";
  const waiting = new Map();
  child.stdout.on("data", (chunk) => {
    buffer += chunk;
    for (let nl = buffer.indexOf("\n"); nl !== -1; nl = buffer.indexOf("\n")) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (!line) continue;
      const msg = JSON.parse(line);
      waiting.get(msg.id)?.(msg);
      waiting.delete(msg.id);
    }
  });

  let nextId = 1;
  const call = (method, params = {}) => {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${method} timed out`)), timeoutMs);
      waiting.set(id, (msg) => {
        clearTimeout(timer);
        msg.error ? reject(new Error(`${method}: ${msg.error.message}`)) : resolve(msg.result);
      });
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  };

  const init = await call("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "fovea-scripts", version: "0" },
  });
  // The transport requires this before the server will serve anything. It is a
  // notification, so it carries no id and gets no reply.
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");

  return { init, call, close: () => child.kill() };
}
