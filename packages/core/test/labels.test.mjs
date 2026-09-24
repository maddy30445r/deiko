import { test } from "node:test";
import assert from "node:assert/strict";

import { EMPTY_KEYS, KINDS, briefKeys, browserTitle, normaliseLabel, repoHints, splitTitle } from "../lib/labels.mjs";

test("a title loses its count and splits on any separator", () => {
  assert.deepEqual(splitTitle("(3) Signups — build"), ["Signups", "build"]);
  assert.deepEqual(splitTitle("Pricing | build"), ["Pricing", "build"]);
  assert.deepEqual(splitTitle("Orders · build (12)"), ["Orders", "build"]);
  assert.deepEqual(splitTitle("Card Library - Free Demo (Community) – Figma"), ["Card Library", "Free Demo (Community)", "Figma"]);
});

test("Chrome's own tail and the profile suffix come off a window title", () => {
  // Real titles from the owner's board.
  assert.equal(browserTitle("Signups — build - Google Chrome – Sam (example.com)"), "Signups — build");
  assert.equal(browserTitle("Pricing — build - Google Chrome – Alex"), "Pricing — build");
  assert.equal(browserTitle("localhost:8801/Cliento Landing.dc.html - Google Chrome"), "localhost:8801/Cliento Landing.dc.html");
  assert.equal(browserTitle("Deiko: show, don’t type"), "Deiko: show, don’t type");
});

test("an address keeps host and path, ids become a wildcard, the query never survives", () => {
  assert.equal(normaliseLabel("https://build.example.com/users/8812?token=abc#top", "url"), "build.example.com/users/*");
  assert.equal(normaliseLabel("build.example.com/users/77", "url"), "build.example.com/users/*");
  assert.equal(normaliseLabel("http://localhost:3000/signups", "url"), "localhost:3000/signups");
  assert.equal(normaliseLabel("http://localhost:5173/signups", "url"), "localhost:5173/signups", "two local projects stay two");
  assert.equal(normaliseLabel("https://example.com:8443/a/3f2a9c1e-1d2b-4c3d-9e8f-0123456789ab/", "url"), "example.com/a/*");
  assert.equal(normaliseLabel("https://x.dev/c/9f86d081884c7d659a2feaa0c55ad015", "url"), "x.dev/c/*");
  assert.equal(normaliseLabel("http://127.0.0.1:8801/", "url"), "127.0.0.1:8801");
  assert.equal(normaliseLabel("https://x.dev/reset/AbCdEf1234567890GhIjKlMnOpQr", "url"), "x.dev/reset/<REDACTED>",
    "a token in the path is still caught");
});

test("titles that name no real page are not labels", () => {
  for (const t of ["New Tab", "Dashboard", "Home", "Untitled", "Loading…", "(2) Home"]) {
    assert.equal(normaliseLabel(t, "page"), null, t);
  }
  assert.equal(normaliseLabel("build", "page", { site: "build" }), null, "the bare site name");
  assert.equal(normaliseLabel("(3) Signups", "page", { site: "build" }), "Signups");
});

test("an error keeps its shape and loses its particulars", () => {
  assert.equal(normaliseLabel("TypeError: can't read 'price' of undefined at line 42", "error"), "TypeError: can't read … of undefined");
  assert.equal(normaliseLabel("Error: ENOENT: no such file or directory, open '/Users/x/y.json'", "error"),
    "Error: ENOENT: no such file or directory, open …");
});

test("a file is a file name, whatever the editor wraps round it", () => {
  assert.equal(normaliseLabel("sitemap.xml (Working Tree) (sitemap.xml)", "file"), "sitemap.xml");
  assert.equal(normaliseLabel("file:///Users/dev/acme-portal/src/App.tsx", "file"), "App.tsx");
  assert.equal(normaliseLabel("Deiko site improvements …", "file"), null);
});

test("a brief's labels come from what the recorder saw and what was said", () => {
  const keys = briefKeys({
    narration: "same as ENG-142, and the UTF-8 thing is fine",
    referents: [
      {
        app: { name: "Google Chrome" },
        window: "(3) Signups — build - Google Chrome – Sam (example.com)",
        page: { title: "Signups — build", url: "localhost:3000/signups?ref=x", headings: ["Weekly signups"] },
        text: { ax: [], ocr: ["TypeError: can't read 'price' of undefined at line 42"] },
      },
      { app: { name: "Code" }, window: "App.tsx — acme-portal", text: { ax: [], ocr: [] } },
      { app: { name: "Figma" }, window: "Card Library - Free Demo (Community)", text: { ax: [], ocr: [] } },
      { app: { name: "Discord" }, window: "@Shivaji Singh - Discord", text: { ax: [], ocr: [] } },
      { app: { name: "Terminal" }, window: "dev@mac: ~/work/acme-api — -zsh — 80×24", text: { ax: [], ocr: [] } },
    ],
  });
  assert.deepEqual(keys.pages, ["Signups"]);
  assert.deepEqual(keys.sites, ["build"]);
  assert.deepEqual(keys.urls, ["localhost:3000/signups"]);
  assert.deepEqual(keys.files, ["App.tsx"]);
  assert.deepEqual(keys.repo, ["acme-api", "acme-portal"]);
  assert.deepEqual(keys.docs, ["Card Library"]);
  assert.deepEqual(keys.components, ["Weekly signups"]);
  assert.deepEqual(keys.errors, ["TypeError: can't read … of undefined"]);
  assert.deepEqual(keys.tickets, ["ENG-142"]);
  assert.deepEqual(Object.keys(keys), KINDS);
});

test("a secret in a title never becomes a label", () => {
  const keys = briefKeys({ referents: [{ app: { name: "Google Chrome" }, window: "AKIAIOSFODNN7EXAMPLE — build - Google Chrome", text: { ax: [], ocr: [] } }] });
  assert.equal(JSON.stringify(keys).includes("AKIAIOSFODNN7EXAMPLE"), false);
});

test("nothing captured is no labels, not an error", () => {
  assert.deepEqual(briefKeys({}), { ...EMPTY_KEYS });
});

test("repo hints moved here unchanged", () => {
  assert.deepEqual(repoHints(["index.ts — search-api", "Notes — research — Arc", "Pull requests — acme-portal — Bitbucket"]).sort(),
    ["acme-portal", "research", "search-api"]);
});
