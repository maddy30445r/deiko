/**
 * THE PAYLOAD — what the developer would have typed themselves.
 *
 * Everything upstream produces evidence; this turns it into a message. The
 * governing decision is that it reads as a person's own prompt with screenshots
 * attached, because that is what it is. It carries no explanation of how it was
 * made, no referent ids, no confidence marks, and no protocol — the document it
 * replaced spent 1500 words on those and the end user read every one of them in
 * their own chat.
 *
 * Screen text is FENCED rather than warned about. Quoting is the natural
 * containment for text that was read off somebody's screen and could say
 * anything; a paragraph instructing the agent to treat it as data is what made
 * the old payload read as machine output. A developer pasting their own
 * screenshot does not warn the agent about it either.
 *
 * Redaction happens HERE, not in the caller. There is no route to a prompt that
 * skipped it.
 *
 * Returns `{ text, evidence }`, not a bare string. `text` is the whole
 * assembled prompt — narration, screenshot paths, the withheld note, the
 * fenced screen text. `evidence` is narrower: the redacted narration, then
 * the redacted screen-text lines in the same fenced block `text` uses (fences
 * omitted when there's no screen text) — nothing else, no headings, no paths.
 *
 * The split exists because `assertNoSecrets` has to run on `evidence`, never
 * on `text`. The guard's subject is captured screen content — narration and
 * what a referent's accessibility/OCR text says — because that is the only
 * place a secret can appear that this code did not put there itself. The
 * screenshot paths in `text` are strings Fovea minted, not content it
 * captured, and an absolute POSIX path is a 40-character run of
 * `[A-Za-z0-9/_]`, which trips the long-opaque-string rule on sight. Widening
 * that rule to admit paths would blunt it for the content it exists to
 * police — an exemption the guard must honour is an exemption that OCR'd
 * screen text can imitate. So the boundary sits here, at what the guard is
 * handed, exactly as it did in the bridge server this renderer replaced.
 *
 * `evidence`'s screen text stays inside ``` fences — DO NOT "clean up" that
 * quoting because `evidence` is never written to disk. `assertNoSecrets` has
 * two checks, and the one it calls "the check that matters" — the one built
 * to catch an OCR-shattered key fragment sitting on a line with no marker of
 * its own — only inspects text inside fenced blocks. Unfence this and that
 * check stops running on screen text at all; only the weaker,
 * fence-independent 40-char rule is left, and the guard goes quiet on
 * exactly the case it exists for.
 */

import { redact, redactBlock } from "./redact.mjs";

/** How many lines of screen text are worth carrying. Past this it stops being
 *  corroboration and starts being a paste of somebody's window. */
const MAX_TEXT_LINES = 40;

/** One rendered line's ceiling — matches what the old renderer's fences used. */
const MAX_LINE_LENGTH = 500;

/**
 * Why a screenshot didn't make it, in the words the developer would plausibly
 * have typed themselves — never a system-notice tone, and never wrong about
 * the reason. `(n)` only matters for the pronoun at the end.
 */
const WITHHELD_PHRASE = {
  "credential visible in this capture": () => "a credential was visible",
  "never OCR'd — contents unverified": (n) =>
    `it was never checked, so I can't vouch for what's in ${n === 1 ? "it" : "them"}`,
};

/** One parenthetical per distinct reason, grouped so two reasons don't read
 *  as one muddled sentence. Order follows first appearance among referents. */
function withheldNote(referents) {
  const counts = new Map();
  for (const r of referents) {
    if (!r.cropWithheld) continue;
    counts.set(r.cropWithheld, (counts.get(r.cropWithheld) ?? 0) + 1);
  }
  if (!counts.size) return null;
  const clauses = [...counts.entries()].map(([reason, n]) => {
    const phrase = (WITHHELD_PHRASE[reason] ?? (() => reason))(n);
    const subject = n === 1 ? "one screenshot" : `${n} screenshots`;
    return `${subject} left out — ${phrase}`;
  });
  return `(${clauses.join("; ")})`;
}

export function buildPrompt({ narration, referents }) {
  const narrationRedacted = redact(narration ?? "").trim();
  const out = [narrationRedacted];

  const shots = referents.filter((r) => r.cropPath);
  if (shots.length) {
    out.push(
      "",
      shots.length === 1
        ? "Screenshot of what I circled:"
        : "Screenshots of what I circled:",
      ...shots.map((r) => `- ${r.cropPath}`),
    );
  }

  // Stated, never silent. Saying nothing would read as "no screenshot was
  // taken", which is a different fact from "one exists and you may not have it".
  const note = withheldNote(referents);
  if (note) out.push("", note);

  // Accessibility text is the literal string the app rendered; OCR is a guess
  // off pixels that routinely substitutes lookalike characters. Where a referent
  // has both, only the exact one travels — carrying both would hand over two
  // spellings of the same identifier with nothing saying which is real.
  const seen = new Set();
  const lines = [];
  for (const r of referents) {
    const source = r.text?.ax?.length ? r.text.ax : (r.text?.ocr ?? []);
    for (const line of source) {
      const text = line.trim().slice(0, MAX_LINE_LENGTH);
      if (!text || seen.has(text)) continue;
      seen.add(text);
      lines.push(text);
    }
  }
  const linesRedacted = lines.length ? redactBlock(lines.slice(0, MAX_TEXT_LINES)) : [];
  if (linesRedacted.length) {
    out.push("", "Exact text from the things I pointed at:", "```", ...linesRedacted, "```");
  }

  // No headings, no paths — just the redacted content a secret could actually
  // hide in. The screen text keeps its fences (see the doc comment above):
  // `assertNoSecrets`'s stronger check only looks inside them, and dropping
  // them here would silently downgrade the guard to its weaker fallback.
  // Omitted entirely when there's no screen text — an empty fenced block
  // would just be noise for a value nobody reads.
  const evidence = linesRedacted.length
    ? [narrationRedacted, "```", ...linesRedacted, "```"].join("\n")
    : narrationRedacted;

  return { text: out.join("\n") + "\n", evidence };
}
