/**
 * Stripping credentials out of anything destined for a model.
 *
 * Extracted from the brief renderer because it is no longer the only consumer:
 * the bridge appends crop paths AFTER the renderer's fail-closed guard has run,
 * so what actually reaches Claude Code was never the thing that got checked.
 * A guard that covers a draft rather than the delivered payload is decoration.
 *
 * This is not defensive tidiness — it is a hard requirement. Fovea reads the
 * screen, and screens have secrets on them. Session 20260728-112323 captured a
 * live Azure Storage account key into `events.jsonl` (via BOTH accessibility and
 * OCR) and burned it into its crops, purely because the developer pointed at a
 * Discord thread.
 */

// ── Redaction ───────────────────────────────────────────────────────────────

/**
 * Strip credentials before anything leaves the machine.
 *
 * This is not defensive tidiness — it is a hard requirement. Fovea reads the
 * screen, and screens have secrets on them. Session 20260728-112323 captured a
 * live Azure Storage account key into `events.jsonl` (via BOTH accessibility and
 * OCR) and burned it into all twelve crops, purely because the developer pointed
 * at a Discord thread. A brief is destined for a cloud model.
 */
/**
 * Anything that announces a credential is nearby. Matching one of these makes
 * the WHOLE LINE suspect, which is the only approach that survives OCR.
 *
 * Pattern-matching the secret itself does not work. OCR substituted a Cyrillic
 * `І` (U+0406) into the middle of a base64 key, shattering it into fragments
 * that all fell below any sane length threshold — and 22 characters of a live
 * key sailed through a redactor built on `{15,}` and `{40,}` runs. Markers are
 * robust because OCR mangles the *key*, not the English word next to it.
 */
const SECRET_MARKER =
  /account\s*key|shared\s*access\s*signature|connection\s*string|\bsecrets?\b|\bpasswords?\b|\bpasswd\b|\bapi[_ -]?keys?\b|\btokens?\b|\bcredentials?\b|\bbearer\b|PRIVATE KEY/i;

/**
 * Does this token look like an opaque blob rather than a word or identifier?
 *
 * Tuned against real captures to keep what a brief needs and drop what it must
 * not carry. Kept: `acmecompanionportal` (no case mix, no digits),
 * `DefaultEndpointsProtocol`, `generateUserSessionSummary`,
 * `acme_topic_completed_event_2026-04-09`. Dropped: `UzvkZx7oHzB3Kj`,
 * `MQULF+AStdFr/lA==`.
 */
function looksOpaque(token) {
  if (token.length < 12) return false;
  if (/[+/]/.test(token)) return true; // base64 punctuation
  const hasUpper = /[A-Z\u0400-\u04FF]/.test(token);
  const hasLower = /[a-z]/.test(token);
  const hasDigit = /\d/.test(token);
  return hasUpper && hasLower && hasDigit;
}

/** Split on whitespace and the separators credentials hide behind. */
const TOKEN_SPLIT = /([\s;,=<>"'`()[\]{}]+)/;

/**
 * Length at which a token is opaque enough to drop even with no credential
 * marker nearby. Above the marker threshold because ordinary code identifiers
 * live down here — `getUserProficiencyV2` must survive a brief.
 */
const UNMARKED_MIN = 24;

function redactTokens(line, suspect) {
  return line
    .split(TOKEN_SPLIT)
    .map((part) => {
      if (!looksOpaque(part)) return part;
      if (suspect) return "<REDACTED>";
      // Unmarked: only drop base64-shaped or very long runs.
      if (/[+]/.test(part) || part.length >= UNMARKED_MIN) return "<REDACTED>";
      return part;
    })
    .join("");
}

/** Credentials that carry their own signature and need no nearby marker. */
const STANDALONE = [
  [/\bAKIA[0-9A-Z]{16}\b/g, "<REDACTED-AWS-KEY-ID>"],
  [/\bgh[pousr]_[A-Za-z0-9]{20,}\b/g, "<REDACTED-GITHUB-TOKEN>"],
  [/\bxox[abprs]-[A-Za-z0-9-]{10,}\b/g, "<REDACTED-SLACK-TOKEN>"],
  [/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g, "<REDACTED-JWT>"],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, "<REDACTED-PRIVATE-KEY>"],
  // scheme://user:pass@host
  [/\b([a-z][a-z0-9+.-]*:\/\/[^\s:/@]+):[^\s@]+@/gi, "$1:<REDACTED>@"],
  // Long opaque runs anywhere, marker or not.
  [/[A-Za-z0-9+/=_|\u0400-\u04FF]{40,}/g, "<REDACTED-OPAQUE-STRING>"],
];

function stripStandalone(text) {
  let out = text;
  for (const [pattern, replacement] of STANDALONE) out = out.replace(pattern, replacement);
  return out;
}

/** Single string — a window title, an utterance. */
export function redact(text) {
  if (typeof text !== "string") return text;
  const stripped = stripStandalone(text);
  return redactTokens(stripped, SECRET_MARKER.test(stripped));
}

/**
 * A referent's captured text, redacted as ONE unit.
 *
 * The block is the right scope, not the line. OCR breaks a connection string
 * across visual lines at arbitrary points, so the line carrying the key's tail
 * (`MQULF+AStdFr/lA==;EndpointSuffix=…`) has no marker on it at all — 17
 * characters of a live key survived line-level redaction. A referent is one
 * screenshot: if a credential is visible anywhere in it, the whole thing is
 * suspect.
 */
export function redactBlock(lines) {
  const stripped = lines.map(stripStandalone);
  const suspect = SECRET_MARKER.test(stripped.join("\n"));
  return stripped.map((l) => redactTokens(l, suspect));
}

/**
 * Was a credential VISIBLE in this referent's capture?
 *
 * Distinct from redacting its text, and the distinction is the whole point.
 * Redaction protects the words in the brief; it cannot touch the PNG, where the
 * key is pixels. Session 20260728-112323 burned a live Azure Storage account key
 * into all twelve crops. So the moment a crop travels as a PATH — which is
 * exactly what the bridge does, so an agent can read it — the text redaction
 * stops being sufficient and this is what decides whether the path goes at all.
 *
 * Scoped to the referent, matching `redactBlock`: one referent is one
 * screenshot, and a credential anywhere in it makes the whole image unsafe.
 */
export function carriesSecret(r) {
  const text = [...(r?.text?.ax ?? []), ...(r?.text?.ocr ?? []), r?.window ?? ""].join("\n");
  const stripped = stripStandalone(text);
  // Either a marker word puts a credential nearby, or something matched a
  // standalone pattern — an AWS key id, a JWT, a private key block — which
  // announces itself without needing a marker.
  return SECRET_MARKER.test(stripped) || stripped !== text;
}

/**
 * Fail closed. Refuses to write if anything credential-shaped survived.
 *
 * The check that matters is the first one: on any line that *announces* a
 * secret, no opaque token may remain. That is the exact bug class the original
 * guard missed — it only looked for 40+ character runs, so OCR-shattered key
 * fragments passed straight through it.
 */
export function assertNoSecrets(markdown) {
  const fail = (why, sample) => {
    throw new Error(
      `redaction failed — ${why}:\n  ${String(sample).slice(0, 50)}…\n` +
        `  Refusing to write. Fix looksOpaque / SECRET_MARKER in scripts/render-brief.mjs.`,
    );
  };

  // Checked per fenced BLOCK, the same unit the redactor uses. Line-by-line is
  // what let an OCR-split key tail through: the line carrying it had no marker.
  let block = null;
  for (const line of markdown.split("\n")) {
    if (line.startsWith("```")) {
      if (block) {
        const text = block.join("\n");
        if (SECRET_MARKER.test(text)) {
          const survivor = text.split(TOKEN_SPLIT).find(looksOpaque);
          if (survivor) fail("opaque token survived in a block announcing a secret", survivor);
        }
        block = null;
      } else {
        block = [];
      }
      continue;
    }
    if (block) block.push(line);
  }

  for (const [pattern, label] of [
    [/\bAKIA[0-9A-Z]{16}\b/, "AWS access key id"],
    [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "private key block"],
    [/[A-Za-z0-9+/=_|\u0400-\u04FF]{40,}/, "long opaque string"],
    // Base64 punctuation anywhere. No identifier a brief needs contains '+'.
    [/[A-Za-z0-9\u0400-\u04FF]*\+[A-Za-z0-9+/\u0400-\u04FF]{8,}/, "base64-shaped run"],
  ]) {
    const hit = markdown.match(pattern);
    if (hit) fail(`${label} survived into the brief`, hit[0]);
  }
}
