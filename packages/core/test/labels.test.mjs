import { test } from "node:test";
import assert from "node:assert/strict";

import { EMPTY_KEYS, KINDS, briefKeys, browserTitle, normaliseLabel, repoHints, splitTitle } from "../src/lib/labels.mjs";

test("a title loses its count and splits on any separator", () => {
  assert.deepEqual(splitTitle("(3) Signups — build"), ["Signups", "build"]);
  assert.deepEqual(splitTitle("Pricing | build"), ["Pricing", "build"]);
  assert.deepEqual(splitTitle("Orders · build (12)"), ["Orders", "build"]);
  assert.deepEqual(splitTitle("Card Library - Free Demo (Community) – Figma"), ["Card Library", "Free Demo (Community)", "Figma"]);
});

test("Chrome's own tail and the profile suffix come off a window title", () => {
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
  assert.equal(normaliseLabel("https://x.dev/reset/AbCdEf1234567890GhIjKlMnOpQr", "url"), "x.dev/reset/*",
    "a token in the path is still caught");
});

test("a token-shaped path segment becomes a wildcard; a slug of words and dates stays", () => {
  for (const [url, want] of [
    ["localhost:8000/reset/MQ/c3x7ml-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d/", "localhost:8000/reset/MQ/*"],
    ["localhost:3000/invite/Xk9f2LmQpR7sT1uV", "localhost:3000/invite/*"],
    ["app.acme.com/share/9fKq2LmZ8xYt", "app.acme.com/share/*"],
    ["https://hooks.slack.com/services/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", "hooks.slack.com/services/T024BE7LD/B024BE7LH/*"],
    ["https://docs.google.com/document/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms/edit", "docs.google.com/document/d/*/edit"],
    ["blog.dev/posts/2026-09-25-memory-v3", "blog.dev/posts/2026-09-25-memory-v3"],
    ["localhost:3000/signups/weekly", "localhost:3000/signups/weekly"],
  ]) assert.equal(normaliseLabel(url, "url"), want, url);
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
  assert.deepEqual(keys.pages, [], "a placeholder is not a page either — dropped, not shared as a label");
});

test("a long mixed-case name redact() opaques never becomes a shared '<REDACTED>' label", () => {
  // `redact` turns these into "<REDACTED>": a real name, not a secret, but a
  // placeholder shared across unrelated briefs is worse than no label.
  assert.equal(normaliseLabel("UserProfileSettingsV2.tsx", "file"), "<REDACTED>", "redact still runs");
  const keys = briefKeys({ referents: [
    { app: { name: "Code" }, window: "UserProfileSettingsV2.tsx — acme-portal", text: { ax: [], ocr: [] } },
    { app: { name: "Code" }, window: "console-2026-09-18T23-26-49-693Z.log — acme-portal", text: { ax: [], ocr: [] } },
  ] });
  assert.deepEqual(keys.files, [], "neither long mixed-case name is shared as the placeholder");
  // A redacted URL path segment is kept: it is a deliberate wildcard, like an
  // id segment.
  assert.deepEqual(
    briefKeys({ referents: [{ app: {}, page: { url: "https://x.dev/reset/AbCdEf1234567890GhIjKlMnOpQr" } }] }).urls,
    ["x.dev/reset/*"],
  );
});

test("a mis-paired app still yields the window's own browser title", () => {
  // The candidate's app and the probe's window title pair asynchronously
  // (session.ts), so a losing app can carry a plainly browser window title.
  const keys = briefKeys({ referents: [
    { app: { name: "MongoDB Compass" }, window: "Signups — build - Google Chrome – Alex", text: { ax: [], ocr: [] } },
  ] });
  assert.deepEqual(keys.pages, ["Signups"]);
  assert.deepEqual(keys.sites, ["build"]);
  assert.deepEqual(keys.docs, [], "never read as a document named after the app");
});

test("Chrome's tab-state suffix comes off before the site name is read", () => {
  assert.equal(browserTitle("Signups — build – Camera and microphone recording - Google Chrome – Alex"), "Signups — build");
  assert.equal(browserTitle("Pricing — build – Audio playing - Google Chrome – Alex"), "Pricing — build");
  const keys = briefKeys({ referents: [
    { app: { name: "Google Chrome" }, window: "Signups — build – Camera and microphone recording - Google Chrome – Alex", text: { ax: [], ocr: [] } },
  ] });
  assert.deepEqual(keys.sites, ["build"], "not the tab-state phrase");
});

test("video-call apps never name a document", () => {
  const keys = briefKeys({ referents: [
    { app: { name: "zoom.us" }, window: "Zoom Meeting", text: { ax: [], ocr: [] } },
    { app: { name: "FaceTime" }, window: "FaceTime", text: { ax: [], ocr: [] } },
    { app: { name: "Microsoft Teams" }, window: "General | Team - Microsoft Teams", text: { ax: [], ocr: [] } },
    { app: { name: "Webex" }, window: "Webex Meeting", text: { ax: [], ocr: [] } },
  ] });
  assert.deepEqual(keys.docs, []);
});

test("a plain word pair is not mistaken for an address, and a VS Code dirty marker keeps its file name", () => {
  const keys = briefKeys({ referents: [
    { app: { name: "Google Chrome" }, page: { title: "N/A — build" }, text: { ax: [], ocr: [] } },
    { app: { name: "Google Chrome" }, page: { title: "TCP/IP basics - Wikipedia" }, text: { ax: [], ocr: [] } },
    { app: { name: "Code" }, window: "● App.tsx — acme-portal", text: { ax: [], ocr: [] } },
  ] });
  assert.deepEqual(keys.urls, [], "neither 'N/A' nor 'TCP/IP' has a dotted host or a port");
  assert.deepEqual(keys.pages, ["N/A", "TCP/IP basics"]);
  assert.deepEqual(keys.files, ["App.tsx"]);
});

test("an error label is a line that starts with one, never a chat or mail message", () => {
  const errors = (app, line) => briefKeys({ referents: [{ app: { name: app }, window: "x", text: { ax: [], ocr: [line] } }] }).errors;
  assert.deepEqual(errors("Slack", "TypeError: can't read 'price' of undefined"), [], "a chat app's line is somebody's message");
  assert.deepEqual(errors("Mail", "Error in your invoice #4471 for Globex Corp"), []);
  assert.deepEqual(errors("Google Chrome", "hey getting a TypeError when Rahul Verma logs in, his email is rahul.verma@globex.com"), [],
    "mentioning an error is not one");
  assert.deepEqual(errors("Google Chrome", "  Uncaught (in promise) Error: boom"), ["Uncaught (in promise) Error: boom"]);
  assert.deepEqual(errors("Terminal", "panic: runtime error: index out of range"), ["panic: runtime error: index out of range"]);
});

test("standards shaped like tickets are not tickets", () => {
  const keys = briefKeys({ narration: "use AES-256 and RSA-2048, floats are IEEE-754, see CVE-2024 and ENG-7" });
  assert.deepEqual(keys.tickets, ["ENG-7"]);
});

test("a terminal names the folder it is in, spaces and all, but never a holding folder", () => {
  const repo = (window) => briefKeys({ referents: [{ app: { name: "Ghostty" }, window, text: { ax: [], ocr: [] } }] }).repo;
  assert.deepEqual(repo("~/Desktop/personal /Deiko"), ["Deiko"]);
  assert.deepEqual(repo("dev@mac: ~/work/acme-api — -zsh — 80×24"), ["acme-api"]);
  assert.deepEqual(repo("~/code/app (main)"), ["app"]);
  for (const w of ["alex@mac: ~/Downloads", "~/Desktop", "~", "~/Desktop/personal "]) assert.deepEqual(repo(w), [], w);
});

test("nothing captured is no labels, not an error", () => {
  assert.deepEqual(briefKeys({}), { ...EMPTY_KEYS });
});

test("repo hints moved here unchanged", () => {
  assert.deepEqual(repoHints(["index.ts — search-api", "Notes — research — Arc", "Pull requests — acme-portal — Bitbucket"]).sort(),
    ["acme-portal", "research", "search-api"]);
});
