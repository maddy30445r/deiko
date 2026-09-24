import assert from "node:assert/strict";
import { test } from "node:test";

import { loadSession } from "../src/referents/session.js";

const probe = (extra: Record<string, unknown>, elements: unknown[]) => ({
  type: "probe", t: 100, shape: { kind: "point", origin: { x: 1, y: 1 } },
  app: { name: "Google Chrome" }, windowTitle: "Signups — build - Google Chrome",
  snapshot: { elements }, ...extra,
});

test("a probe's page name, address, document, headings and element ids ride on its referent", () => {
  const [r] = loadSession([probe({ pageURL: "localhost:3000/signups", document: "/Users/dev/app/App.tsx" }, [
    { role: "AXStaticText", value: "12%", domIdentifier: "chart", ancestors: [{ role: "AXGroup" }, { role: "AXWebArea", title: "Signups — build" }] },
    { role: "AXHeading", title: "Weekly signups", ancestors: [] },
  ])] as any).all();
  assert.ok(r);
  assert.deepEqual(r.page, {
    title: "Signups — build", url: "localhost:3000/signups", document: "/Users/dev/app/App.tsx",
    headings: ["Weekly signups"], domIds: ["chart"],
  });
});

test("a probe with none of it has no page at all", () => {
  const [r] = loadSession([probe({}, [{ role: "AXButton", title: "Save", ancestors: [] }])] as any).all();
  assert.ok(r);
  assert.equal("page" in r, false);
});
