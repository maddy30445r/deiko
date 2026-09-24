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
 * assembled prompt — narration, screenshot paths each labelled with the
 * sentence it was drawn during, the withheld note, the fenced screen text.
 * `evidence` is narrower: the redacted narration and those redacted quotes,
 * then the redacted screen-text lines in the same fenced block `text` uses
 * (fences omitted when there's no screen text) — nothing else, no headings,
 * no paths.
 *
 * The split exists because `assertNoSecrets` has to run on `evidence`, never
 * on `text`. The guard's subject is captured screen content — narration and
 * what a referent's accessibility/OCR text says — because that is the only
 * place a secret can appear that this code did not put there itself. The
 * screenshot paths in `text` are strings Deiko minted, not content it
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

/** Whitespace and case folded away — the two differences between "what was
 *  recognised" and "what the developer retyped" that carry no meaning. */
const normalizeSpoken = (text) => String(text ?? "").toLowerCase().replace(/\s+/g, " ").trim();

/**
 * May this screenshot's label still travel?
 *
 * A label is a sentence sliced out of the raw transcript, and the review window
 * lets the developer rewrite that transcript. The promise the window makes is
 * that only the narration they approved leaves the Mac — so a label may ship
 * only if its words are still IN that approved text. Edit a typo somewhere else
 * and this stays true for every other label; delete the sentence a label was
 * built from and the label goes with it.
 *
 * Substring rather than equality because a label is one utterance out of a
 * longer narration. Normalised because retyping a word changes spacing and case
 * without changing what was said, and holding a label back over a double space
 * would be the over-strict mirror of shipping words somebody deleted.
 */
export function quoteSurvives(utterance, narration) {
  const quote = normalizeSpoken(utterance);
  if (quote.length === 0) return false;
  // ON WORD BOUNDARIES, not raw characters. A plain `includes` matched across
  // them — `quoteSurvives("on the", "python theory")` was true, on
  // `pyth[on the]ory` — which let a label ship on the strength of letters that
  // are not the words anybody said. Padding both sides with a space turns
  // "contains these characters" into "contains this run of whole words", which
  // is what the promise actually claims.
  return ` ${normalizeSpoken(narration)} `.includes(` ${quote} `);
}

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

/**
 * Asked, not assumed, and asked EVERY time rather than only when the narration
 * looks non-English.
 *
 * Sarvam transcribes Hinglish as Hinglish, which is the right call — the
 * narration is primary evidence and paraphrasing it into English would replace
 * what the developer said with a machine's reading of it. But a model handed
 * Hinglish tends to answer in Hinglish, and the answer is not evidence; it is
 * the work.
 *
 * Unconditional because the alternative is a language heuristic, and a
 * heuristic that guesses "this is English" wrong fails SILENTLY — the line is
 * simply absent and nobody learns why the reply came back in Hindi. One
 * sentence a developer would plausibly type themselves costs nothing on a
 * session that was already in English.
 */
// "Same as I speak" (DEIKO_NARRATION=native) writes the brief in whatever was
// spoken, so the ask has to follow — an agent told "Reply in English" under a
// Chinese brief answers in the one language its author did not choose.
const REPLY_LANGUAGE = process.env.DEIKO_NARRATION === "native"
  ? "Reply in the same language as this brief."
  : "Reply in English.";

/** The verb each stroke kind earns in the prompt. The wire's `mark.kind` comes
 *  from Swift's StrokeKind — an unknown value (a newer app than this script)
 *  degrades to "marked" rather than dropping the line. */
const MARK_VERB = {
  point: "pointed at",
  lasso: "circled",
  connector: "swept across",
  trace: "traced through",
  emphasis: "scribbled over",
};

/** A connector's endpoint texts, redacted and truncated. These are real
 *  captured accessibility text — from `probe.startSnapshot`/`probe.snapshot`,
 *  same as any other referent's `ax` — not strings this module minted, so
 *  they get the same treatment as a quote before they reach the label or the
 *  guard. Redacted BEFORE truncation: a credential sitting past character 60
 *  must not be sliced off and forgotten about, it has to be stripped either
 *  way. Null unless both ends resolved. */
function connectorEndpoints(r) {
  if (r.mark?.kind !== "connector") return null;
  const from = r.text?.axStart?.[0];
  const to = r.text?.ax?.[0];
  if (!from || !to) return null;
  return { from: redact(from).trim().slice(0, 60), to: redact(to).trim().slice(0, 60) };
}

/** `[2] swept across` — or, when both endpoint texts exist for a connector,
 *  `[2] swept from "fetchUser()" to "OrderList"`. Null for unmarked referents,
 *  which keep the pre-mark copy so old sessions re-render byte-identical. */
function markLabel(r, endpoints) {
  if (!r.mark) return null;
  if (endpoints) return `[${r.mark.number}] swept from "${endpoints.from}" to "${endpoints.to}"`;
  return `[${r.mark.number}] ${MARK_VERB[r.mark.kind] ?? "marked"}`;
}

/**
 * `attached` — whether the screenshots themselves are being handed over.
 *
 * A path is only readable by a model on this machine. Claude Code opens one
 * with its own `Read` tool; a browser chat has no filesystem, so
 * `/Users/…/h01-r008.png` is a string it cannot follow and may quietly claim
 * to have looked at. When the delivery pastes the image bytes instead, the
 * paths stop being useful and start being a lie, so this drops them and
 * numbers the images in the order they were attached.
 *
 * Both variants are rendered up front because the renderer runs long before
 * anybody knows where the coin will land.
 */
export function buildPrompt({
  narration, referents, attached = false, personaPath = null,
  task = null, maybe = null, outcomePath = null, quickHint = false,
}) {
  const narrationRedacted = redact(narration ?? "").trim();
  const out = [narrationRedacted, "", REPLY_LANGUAGE];

  // Each path carries the sentence it was drawn during. Without it the agent is
  // handed two screenshots and a paragraph and has to guess which is which —
  // and Deiko already KNOWS, from word timings, having bound `r8` to "what does
  // this code do" and `r13` to "learn about route 53 here" in the session that
  // exposed this. Computing that and then dropping it threw away the one thing
  // pointing-while-talking produces that a screenshot alone does not.
  //
  // The full bound utterance, not a phrase trimmed to the deictic's
  // neighbourhood: `align` already scopes it to one sentence, and trimming
  // further would put words in the developer's mouth.
  //
  // LABELLED, not spliced into the narration at the word that named it. That
  // would read better and would break: `narration.override.txt` — the
  // developer's own correction from the review window — has no word timings at
  // all, so any inline form collapses the moment somebody fixes a mis-heard
  // identifier. A missing quote here just omits a clause.
  const shots = referents.filter((r) => r.cropPath);
  // Redacted once, here, and reused for both `text` and `evidence`. A quote is
  // SPEECH, not something this module minted, so the guard has to see it — and
  // it is not covered by the narration: `said` comes from the raw transcript
  // while the narration may be the developer's hand-typed correction, so an
  // identifier they edited out of one still travels in the other.
  const quotes = new Map(
    shots.filter((r) => r.said).map((r) => [r, redact(r.said).trim()]),
  );
  // A connector's endpoint texts are screen content spliced into the label
  // below (see `connectorEndpoints`) — collected here so they also reach
  // `evidence`'s fenced block, the only place `assertNoSecrets`'s stronger
  // check looks. Already redacted per-string by `connectorEndpoints`.
  const connectorLines = [];
  if (shots.length) {
    // "marked" copy only when EVERY shot carries a mark — a mix of marked and
    // unmarked referents is a session recorded partway through the rollout,
    // and half-committing to the new wording would misdescribe the ones that
    // aren't badged. Legacy sessions (no referent ever has `mark`) keep the
    // "circled" copy verbatim so they re-render byte-identical.
    const allMarked = shots.every((r) => r.mark);
    out.push(
      "",
      attached
        ? shots.length === 1
          ? allMarked
            ? "The screenshot above is what I marked:"
            : "The screenshot above is what I circled:"
          : allMarked
            ? `The ${shots.length} screenshots above are what I marked, in this order:`
            : `The ${shots.length} screenshots above are what I circled, in this order:`
        : shots.length === 1
          ? allMarked
            ? "Screenshot of what I marked:"
            : "Screenshot of what I circled:"
          : allMarked
            ? "Screenshots of what I marked (badge numbers match):"
            : "Screenshots of what I circled:",
      ...shots.map((r, i) => {
        const quote = quotes.get(r);
        const endpoints = connectorEndpoints(r);
        if (endpoints) connectorLines.push(endpoints.from, endpoints.to);
        const label = markLabel(r, endpoints);
        if (attached) {
          // Numbered, because the image is no longer named by a path and its
          // position in the message is the only thing identifying it — which
          // also means every one needs a line, including the ones nothing was
          // said over, or the numbering stops matching the attachments.
          const head = label ? `${i + 1}. ${label}` : `${i + 1}.`;
          if (quote) {
            // Only the labelled head gets the em-dash join ("[1] pointed at —
            // while I said"); the legacy unlabelled line keeps its original
            // direct join ("1. while I said") so old sessions render byte-
            // identical.
            return label ? `${head} — while I said "${quote}"` : `${i + 1}. while I said "${quote}"`;
          }
          return label ? head : `${i + 1}. (I wasn't saying anything while I drew this one)`;
        }
        const head = label ? `- ${label}: ${r.cropPath}` : `- ${r.cropPath}`;
        return quote ? `${head} — while I said "${quote}"` : head;
      }),
    );
  }

  // Stated, never silent. Saying nothing would read as "no screenshot was
  // taken", which is a different fact from "one exists and you may not have it".
  const note = withheldNote(referents);
  if (note) out.push("", note);

  // TEXT ONLY WHERE THERE IS NO IMAGE, and only for something the narration
  // actually reached.
  //
  // A circled region ships its screenshot, and the agent reads those pixels
  // directly — OCR of the same pixels is a second, worse copy. Including it
  // cost a real session everything: 14 referents contributed ~250 lines, the
  // cap filled with one file's comment block in referent order, and the Route
  // 53 sidebar the developer had circled and named never appeared at all. What
  // did arrive was gutter fragments (`15+`, `//`, `8`) and OCR garbage
  // (`HICALUVLLULo`).
  //
  // So: a referent contributes text only if it has no screenshot AND the
  // aligner bound speech to it. A pause nobody was talking through is not
  // something the developer pointed at, and the recorder over-captures on
  // purpose precisely so the narration can be the filter.
  const seen = new Set();
  const lines = [];
  for (const r of referents) {
    if (r.cropPath || !r.said) continue;
    // Accessibility text is the literal string the app rendered; OCR is a guess
    // off pixels that routinely substitutes lookalike characters. Where a
    // referent has both, only the exact one travels — carrying both would hand
    // over two spellings of the same identifier with nothing saying which is
    // real.
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
    // Not "Exact text" any more. With regions excluded, what is left is mostly
    // OCR — a guess off pixels — and the old heading asserted the opposite of
    // the truth about its own contents.
    out.push("", "Text from other things I pointed at:", "```", ...linesRedacted, "```");
  }

  // THE TASK THIS BRIEF CARRIES ON, when it has earlier briefs. Where it
  // stands, inline, because that is what the next step depends on; the
  // history by path, because an agent can read it and a paragraph of it
  // would bury the ask. A browser has no filesystem, so it gets what was
  // done last instead of a path.
  //
  // The lines are agent-written and another session's words, so they join
  // `evidence` below; the note path does not, like every path this mints.
  const earlierSpoken = [];
  const clean = (s) => redact(s ?? "").replace(/\s+/g, " ").trim();
  if (task) {
    const title = clean(task.title);
    const now = task.now.map(clean).filter(Boolean);
    const did = task.lastDid.map(clean).filter(Boolean);
    earlierSpoken.push(title, ...now, ...did);
    if (attached) {
      // "Last done: X" already said X; say only what it did besides.
      const more = did.filter((d) => !now.some((n) => n.includes(d)));
      out.push("", `This carries on from "${title}".`
        + (now.length ? ` Where it stands: ${now.join(" ")}` : "")
        + (more.length ? ` Last time: ${more.join(" ")}` : ""));
    } else {
      out.push(
        "",
        `This carries on from "${title}" (${task.count} brief${task.count === 1 ? "" : "s"} so far).`
          + (now.length ? " Where it stands:" : ""),
        ...now,
        `The full history is in ${task.notePath} — read what you need.`,
      );
    }
  } else if (maybe?.length) {
    // THE TASKS IT MIGHT CARRY ON, when the classifier could not tell which
    // (`decide`'s `candidates`). Named, not guessed: the agent asks if the
    // screenshots don't settle it. Same rules as the task above — words to
    // `evidence`, paths never, and no path for a browser.
    out.push("", "This might carry on from earlier work, one of these:");
    for (const m of maybe) {
      const title = clean(m.title);
      const now = m.now.map(clean).filter(Boolean);
      earlierSpoken.push(title, ...now);
      const line = `- "${title}"` + (now.length ? ` — where it stands: ${now.join(" ")}` : "");
      out.push(attached ? line : `${line}${/[.!?]$/.test(line) ? "" : "."} History: ${m.notePath}`);
    }
    out.push("If the screenshots don't make it clear which one I mean, ask me before you start.");
  }

  // No headings, no paths — just the redacted content a secret could actually
  // hide in. Speech first (the narration, then every quote that reached a path
  // line), then the screen text.
  //
  // The screen text keeps its fences (see the doc comment above):
  // `assertNoSecrets`'s stronger check only looks inside them, and dropping
  // them here would silently downgrade the guard to its weaker fallback.
  // Omitted entirely when there's no screen text — an empty fenced block
  // would just be noise for a value nobody reads.
  //
  // Connector endpoint texts join this block too, even though they never
  // appear in `text`'s "Text from other things I pointed at" section — they
  // already surfaced in `text` via the `[n] swept from … to …` label, and
  // this is what makes that captured screen content visible to the guard.
  const screenText = [...linesRedacted, ...connectorLines];
  const spoken = [narrationRedacted, ...quotes.values(), ...earlierSpoken];
  const evidence = screenText.length
    ? [...spoken, "```", ...screenText, "```"].join("\n")
    : spoken.join("\n");

  // HOW I WANT IT WRITTEN UP, as a path rather than as a wall of prose.
  //
  // The persona file is the paragraph the developer would otherwise retype at
  // the bottom of every brief. An agent that can open files reads it there,
  // which keeps their chat the length of what they actually said; the paths
  // this renderer mints are the same kind of string as a crop path, so this
  // rides in `text` beside them and stays out of `evidence` for the same
  // reason they do.
  //
  // NOT in the `attached` variant. That one is for a destination with no
  // filesystem — a path it cannot open is worse than nothing, because it looks
  // like an instruction it has followed. `Handoff` pastes the file's contents
  // there instead.
  if (personaPath && !attached) {
    out.push("", `How I want this written up is in ${personaPath} — read that first.`);
  }

  // ADVISORY, and it says so. Deiko never picks the model — the harness the
  // brief lands in does — so the most this can be is one soft sentence when
  // the classifier was confident the task is small. Both variants: a browser
  // chat's model picker is a person's decision too.
  if (quickHint) {
    out.push("", "This looks like a quick one and a fast model is probably enough. Judge for yourself.");
  }

  // THE WRITE-BACK, under four headings, because the task note is compiled
  // from them: Open becomes where the task stands, Decided is kept dated.
  // Asked again for a conversation that keeps going, or the next brief
  // carries on from where the first answer left it.
  if (outcomePath && !attached) {
    out.push("", `When you are done — and again if we keep going — write to ${outcomePath} under four headings — ## Did, ## Decided, ## Open, ## Files — a few lines each. Deiko folds it into this task's memory for the next brief.`);
  }

  return { text: out.join("\n") + "\n", evidence };
}
