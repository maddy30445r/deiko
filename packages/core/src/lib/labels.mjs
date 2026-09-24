/**
 * LABELS — the exact names a brief is about: its page, site, web address,
 * file, code project, document, component, error and ticket. Read from what
 * the recorder already captured; no model, no network. Two briefs on page
 * "Signups" are far likelier the same job than two that both say "chart",
 * and a label is exact the way an email's reply thread is.
 *
 * Every value is cleaned so two visits to the same page match, and passed
 * through `redact`. `pages/sites/urls/files/repo/docs/errors/tickets` may
 * travel to the classifier — the same class as the window titles they come
 * from. `components` (headings and element ids read off the screen) stays on
 * this Mac.
 */
import { redact, redactBlock } from "./redact.mjs";

export const KINDS = ["pages", "sites", "urls", "files", "repo", "docs", "components", "errors", "tickets"];
export const EMPTY_KEYS = Object.freeze(Object.fromEntries(KINDS.map((k) => [k, Object.freeze([])])));
const ONE = { pages: "page", sites: "site", urls: "url", files: "file", repo: "repo", docs: "doc", components: "component", errors: "error", tickets: "ticket" };
const CAP = 10;

export const BROWSER = /^(google chrome|chrome|safari|arc|firefox|microsoft edge|brave browser|chromium|opera|vivaldi|zen)$/i;
export const EDITOR = /^(code|visual studio code|cursor|windsurf|zed|xcode|sublime text|nova|intellij idea|webstorm|pycharm|android studio)$/i;
export const TERMINAL = /^(terminal|iterm2?|warp|ghostty|kitty|alacritty|wezterm)$/i;
/// Apps whose window titles name a conversation or the system, never a document.
/// ponytail: a list; grow it when a real board shows another chat app as a project.
const NOT_A_DOC = /^(finder|dock|deiko|deiko capture|usernotificationcenter|screenshot|system settings|dictionary|discord|slack|messages|mail|spotlight|control center|notification center)$/i;

const GENERIC = new Set(["new tab", "dashboard", "home", "untitled", "loading", "loading…", "loading...", "index", "start page", "about:blank", "blank"]);
const SEPARATOR = / (?:—|–|-|\||·) /;
const COUNT = /^\(\d+\)\s*|\s*\(\d+\)$/g;
const ID_SEGMENT = /^(\d+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{16,})$/i;
const LOOKS_LIKE_URL = /^(https?:\/\/)?[\w.-]+(:\d+)?\/\S*/i;
const TICKET = /\b([A-Z][A-Z0-9]{1,9}-\d{1,6})\b|(?<![\w&])#(\d{1,6})\b/g;
/// Standards and encodings shaped like tickets. ponytail: a list.
const NOT_A_TICKET = /^(UTF|ISO|SHA|MD|RFC|TLS|SSL|GPT|ES|IPV|HTTP|COVID|WCAG|PEP)-/;
const ERROR_LINE = /\b[A-Z][A-Za-z]*(Error|Exception)\b|\bUncaught\b|\bTraceback\b|\bpanic:|^(error|Error|ERROR)\b/;
const BROWSER_TAIL = /\s[-–—]\s(Google Chrome|Mozilla Firefox|Firefox|Microsoft Edge|Brave|Chromium|Opera|Vivaldi)\b.*$/;

export function splitTitle(title) {
  return String(title ?? "")
    .replace(COUNT, "")
    .split(SEPARATOR)
    .map((s) => s.replace(COUNT, "").trim())
    .filter(Boolean);
}

export function browserTitle(windowTitle) {
  const t = String(windowTitle ?? "").replace(BROWSER_TAIL, "").trim();
  return t || null;
}

function cleanUrl(text) {
  let s = String(text).trim().replace(/^[a-z][a-z0-9+.-]*:\/\//i, "");
  s = s.split(/[?#]/)[0];
  const slash = s.indexOf("/");
  const hostPort = (slash === -1 ? s : s.slice(0, slash)).toLowerCase();
  const [name, port] = hostPort.split(":");
  if (!name || !/^[a-z0-9.-]+$/.test(name)) return null;
  // The port only where it tells two projects apart: localhost:3000 and :5173.
  const host = port && (name === "localhost" || name === "127.0.0.1") ? `${name}:${port}` : name;
  const segments = (slash === -1 ? "" : s.slice(slash)).split("/").filter(Boolean)
    .map((seg) => (ID_SEGMENT.test(seg) ? "*" : seg));
  return segments.length ? `${host}/${segments.join("/")}` : host;
}

/** Sentry-style: the first line, no location, no quoted values, no numbers. */
function cleanError(text) {
  const line = String(text).split("\n")[0].replace(/\s+at\s.*$/, "");
  return line
    .replace(/(^|\s)(['"`])[^'"`]*\2(?=$|[\s.,:;)])/g, "$1…")
    .replace(/\b0x[0-9a-f]+\b/gi, "")
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "")
    .replace(/\d+/g, "")
    .replace(/\s+/g, " ")
    .replace(/\s+([.,:;])/g, "$1")
    .trim()
    .slice(0, 120) || null;
}

function cleanFile(text) {
  let s = String(text).trim().split(/[\\/]/).pop() ?? "";
  while (/\s*\([^()]*\)\s*$/.test(s)) s = s.replace(/\s*\([^()]*\)\s*$/, "");
  return /^[\w.@+-]+\.[A-Za-z0-9]{1,8}$/.test(s) ? s : null;
}

export function normaliseLabel(text, kind, { site = null } = {}) {
  if (typeof text !== "string" || !text.trim()) return null;
  let out;
  switch (kind) {
    case "url": out = cleanUrl(text); break;
    case "file": out = cleanFile(text); break;
    case "error": out = cleanError(text); break;
    case "ticket": out = text.trim().toUpperCase(); break;
    case "repo": out = /\s/.test(text.trim()) ? null : text.trim(); break;
    default: {
      out = text.replace(COUNT, "").replace(/\s+/g, " ").trim();
      const low = out.toLowerCase();
      if (GENERIC.has(low) || (site && low === String(site).toLowerCase())) out = null;
    }
  }
  if (!out) return null;
  // AN ADDRESS IS REDACTED SEGMENT BY SEGMENT. Whole, any path of 24+
  // characters reads as one opaque run ("/" is base64 punctuation) and the
  // label is lost; per segment, a token in the path is still caught.
  return kind === "url" ? out.split("/").map(redact).join("/") : redact(out);
}

/** App/browser names that are never a repo, so they can be discarded. */
/// Whole words, so `search-api` and `research` are not "Arc".
const NOT_A_REPO =
  /\b(google chrome|safari|firefox|arc|bitbucket|github|gitlab|jira|discord|slack|visual studio code|cursor|finder|terminal|iterm2?|warp|screen recording)\b/i;

/**
 * Guess repo names from window titles. Editors render `App.tsx — acme-portal`
 * (EM dash, U+2014); browsers render `Pull requests — acme-api-service —
 * Bitbucket - Google Chrome – Alex`, where the trailing en dash is the Chrome
 * profile. So: split on em dashes, drop segments naming an app, take what's left.
 * (Moved here unchanged from render-brief.mjs.)
 */
export function repoHints(titles) {
  const hints = new Map();
  for (const title of titles) {
    if (!title) continue;
    const parts = title
      .split("—")
      .map((p) => p.trim())
      .filter((p) => p && !NOT_A_REPO.test(p));
    if (parts.length < 2) continue;
    // The last surviving segment is the workspace; earlier ones are the file.
    const name = parts[parts.length - 1].replace(/\s*\(.*\)\s*$/, "").trim();
    if (!name || name.includes(" ")) continue; // repo names do not have spaces
    hints.set(name, (hints.get(name) ?? 0) + 1);
  }
  return [...hints.entries()].sort((a, b) => b[1] - a[1]).map(([name]) => name);
}

export function briefKeys({ referents = [], narration = "" } = {}) {
  const found = Object.fromEntries(KINDS.map((k) => [k, []]));
  const add = (kind, text, opts) => {
    const v = normaliseLabel(text, ONE[kind], opts);
    if (v && !found[kind].some((x) => x.toLowerCase() === v.toLowerCase())) found[kind].push(v);
  };
  const pageTitle = (title) => {
    if (!title) return;
    if (LOOKS_LIKE_URL.test(title.trim())) return add("urls", title);
    const parts = splitTitle(title);
    const site = parts.length > 1 ? parts.at(-1) : null;
    if (site) add("sites", site);
    add("pages", parts[0], { site });
  };
  for (const r of referents) {
    const app = r.app?.name ?? "";
    const window = r.window ?? "";
    pageTitle(r.page?.title);
    if (BROWSER.test(app)) {
      pageTitle(browserTitle(window));
    } else if (EDITOR.test(app)) {
      const parts = window.split("—").map((p) => p.trim()).filter(Boolean);
      if (parts.length > 1) add("files", parts[0]);
    } else if (TERMINAL.test(app)) {
      const path = window.match(/(?:~|\/)[^\s—–:]*[^\s—–:/]/)?.[0];
      if (path) add("repo", path.split("/").pop());
    } else if (window && !NOT_A_DOC.test(app)) {
      add("docs", splitTitle(window)[0]);
    }
    if (r.page?.url) add("urls", r.page.url);
    if (r.page?.document) add("files", r.page.document);
    for (const h of r.page?.headings ?? []) add("components", h);
    for (const d of r.page?.domIds ?? []) add("components", d);
    const err = redactBlock([...(r.text?.ax ?? []), ...(r.text?.ocr ?? [])]).find((l) => ERROR_LINE.test(l));
    if (err) add("errors", err);
  }
  // Editor and browser titles only: a terminal's "— -zsh — 80×24" is not a repo.
  const titled = referents.filter((r) => BROWSER.test(r.app?.name ?? "") || EDITOR.test(r.app?.name ?? ""));
  for (const name of repoHints(titled.map((r) => r.window).filter(Boolean))) add("repo", name);
  for (const text of [narration, ...referents.map((r) => r.window ?? "")]) {
    for (const m of String(text ?? "").matchAll(TICKET)) {
      const t = m[1] ?? `#${m[2]}`;
      if (!NOT_A_TICKET.test(t)) add("tickets", t);
    }
  }
  return Object.fromEntries(KINDS.map((k) => [k, found[k].slice(0, CAP)]));
}
