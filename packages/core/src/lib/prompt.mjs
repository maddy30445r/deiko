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
 */

import { redact, redactBlock } from "./redact.mjs";

/** How many lines of screen text are worth carrying. Past this it stops being
 *  corroboration and starts being a paste of somebody's window. */
const MAX_TEXT_LINES = 40;

/** One rendered line's ceiling — matches what the old renderer's fences used. */
const MAX_LINE_LENGTH = 500;

export function buildPrompt({ narration, referents }) {
  const out = [redact(narration ?? "").trim()];

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
  const withheld = referents.filter((r) => r.cropWithheld).length;
  if (withheld) {
    out.push(
      "",
      withheld === 1
        ? "(one screenshot left out — a credential was visible)"
        : `(${withheld} screenshots left out — a credential was visible)`,
    );
  }

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
  if (lines.length) {
    out.push(
      "",
      "Exact text from the things I pointed at:",
      "```",
      ...redactBlock(lines.slice(0, MAX_TEXT_LINES)),
      "```",
    );
  }

  return out.join("\n") + "\n";
}
