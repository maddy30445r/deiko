/**
 * Detecting phrases that reach BACKWARD.
 *
 * The alignment engine handles pointing: "yeh" spoken while the cursor is
 * somewhere. This handles the other half — "that key we showed earlier" — where
 * the cursor is in a different app entirely and no gesture accompanies the
 * words. It is the founding example in VISION.md and the aligner alone misses
 * it completely, because there is nothing being pointed at to bind to.
 *
 * The signal is a deictic word paired with a PAST marker. "that key" on its own
 * is often just pointing; "that key we showed earlier" is unmistakably a
 * callback.
 */

/** Words that place a reference in the past, in both languages. */
const PAST_MARKERS = [
  // English
  "earlier", "before", "previously", "just now", "a moment ago",
  "we showed", "i showed", "we saw", "you saw", "we were", "that we",
  // Hinglish / Devanagari
  "pehle", "pehele", "abhi", "wo jo", "woh jo", "jo humne", "jo maine",
  "dikhaya", "dikhaya tha", "bataya tha",
  "पहले", "अभी", "जो हमने", "दिखाया",
];

/**
 * Deictics that can carry a back-reference. Note "this" is absent: "this key"
 * points at something present, "that key" reaches away. Hindi's `wo/woh` and
 * `usko/uska` family are the distal forms and behave the same way.
 */
const DISTAL = ["that", "those", "it", "wo", "woh", "vo", "usko", "uska", "uske", "unko", "वह", "वो", "उसको", "उसका"];

export interface DetectedBackReference {
  phrase: string;
  /** Session-clock time of the first word of the phrase. */
  t: number;
  /** What made us think this reaches backward — shown in the review UI. */
  trigger: string;
}

interface TimedWord {
  text: string;
  start: number;
  end: number;
}

/**
 * Scan a transcript for back-reference phrases.
 *
 * Deliberately conservative: it requires BOTH a distal deictic and a past
 * marker within a short window. A false positive steals a plan step's meaning
 * and points it at the wrong thing, which is worse than missing one — the user
 * can always re-point, but they cannot easily notice a confidently wrong
 * citation.
 */
export function detectBackReferences(
  words: TimedWord[],
  windowWords = 6,
): DetectedBackReference[] {
  const found: DetectedBackReference[] = [];
  const lower = words.map((w) => w.text.toLowerCase().replace(/[^\p{L}\p{N}\p{M}]/gu, ""));

  for (let i = 0; i < words.length; i++) {
    if (!DISTAL.includes(lower[i]!)) continue;

    // Look at the words around the deictic for a past marker. The marker
    // usually follows ("that key we showed earlier") but can precede
    // ("pehle jo dikhaya tha wo").
    const from = Math.max(0, i - windowWords);
    const to = Math.min(words.length, i + windowWords + 1);
    const window = lower.slice(from, to).join(" ");

    const marker = PAST_MARKERS.find((m) => window.includes(m.replace(/\s+/g, " ")));
    if (!marker) continue;

    // Don't emit overlapping detections for the same phrase.
    const start = words[from]!.start;
    if (found.some((f) => Math.abs(f.t - start) < 1500)) continue;

    found.push({
      phrase: words.slice(from, to).map((w) => w.text).join(" "),
      t: words[i]!.start,
      trigger: `"${lower[i]}" + "${marker}"`,
    });
  }

  return found;
}
