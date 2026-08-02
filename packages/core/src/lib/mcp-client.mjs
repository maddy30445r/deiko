/**
 * Talking to the bridge without an editor.
 *
 * This used to be sixty lines of hand-rolled JSON-RPC — newline framing, id
 * correlation, a timeout — written on the theory that a test sharing a library
 * with the thing it tests proves less. But the bridge is a *server* and this is
 * a *client*: they share a package, not an implementation, and the SDK is
 * already a dependency. Sixty lines of framing that nothing else exercises was
 * the likelier place for a bug than the SDK's own client.
 */

import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
export const SERVER = join(ROOT, "apps", "bridge", "src", "server.mjs");

/**
 * Spawn the bridge and complete the MCP handshake.
 *
 * Returns `{ client, close }`. Requests carry `timeoutMs` — a hung server
 * should fail a script, not hang it.
 */
export async function connect({ server = SERVER, timeoutMs = 10_000 } = {}) {
  const transport = new StdioClientTransport({ command: "node", args: [server] });
  const client = new Client({ name: "fovea-scripts", version: "0" }, { capabilities: {} });
  await client.connect(transport, { timeout: timeoutMs });
  return { client, timeoutMs, close: () => client.close() };
}
