/**
 * Deictic words: the ones that point.
 *
 * "Add a status key to *this* response" is only interpretable if you know what
 * "this" was aimed at. Detecting these words is what turns cursor settles into
 * referents: a settle with "yeh" landing on it is a pointing act, a settle
 * inside three seconds of silence is a resting hand.
 *
 * The lexicon is bilingual: users think out loud in mixed English and Hindi
 * ("yeh wala key expose karna hai"), and an English-only lexicon would score
 * such an utterance as having no pointing words.
 */

/** English pointing words. */
const ENGLISH = [
  "this",
  "that",
  "these",
  "those",
  "here",
  "there",
  "it",
] as const;

/**
 * Hindi/Hinglish pointing words, in the Latin spellings people type and
 * code-switching ASR returns. Several spellings map to one word on purpose
 * (`yeh`/`ye`/`yah`): ASR output for transliterated Hindi is not
 * orthographically stable.
 */
const HINGLISH = [
  // yeh / this
  "yeh", "ye", "yah", "yehi", "yahi",
  // woh / that
  "wo", "woh", "vo", "voh", "wahi", "vahi",
  // yahan / here
  "yahan", "yaha", "idhar", "yahaan",
  // wahan / there
  "wahan", "waha", "udhar", "wahaan",
  // isko / iska / ismein — oblique forms of "this"
  // ("issko" is a spelling ASR actually produces)
  "isko", "issko", "iska", "iski", "ise", "inko", "inka", "inhe",
  "ismein", "isme", "ismei",
  // usko / uska / usmein — oblique forms of "that"
  "usko", "ussko", "uska", "uski", "unko", "unka", "unhe",
  "usmein", "usme", "usmei",
] as const;

/**
 * Deliberately excluded, though they are genuine Hindi deictics: `is`, `us`,
 * `use`. Each is a homograph of a very common English word ("the padding IS too
 * big", "show US the response", "USE this endpoint") and this lexicon runs over
 * code-switched speech. In Hinglish they are almost always spoken joined anyway
 * (`iska`, `isko`, `usko`), and those forms are kept above. A missed binding
 * costs one referent; a false one steals a referent from the utterance that
 * deserved it.
 */
const EXCLUDED_HOMOGRAPHS = ["is", "us", "use"] as const;

/**
 * The same words in Devanagari. The script returned depends on the recogniser
 * and its mode, and matching only Latin would silently score a real Hinglish
 * session as having no pointing words.
 */
const DEVANAGARI = [
  // yeh / this
  "यह", "ये", "यही",
  // woh / that
  "वह", "वो", "वही",
  // yahan / here
  "यहां", "यहाँ", "इधर",
  // wahan / there
  "वहां", "वहाँ", "उधर",
  // oblique forms of this
  "इसमें", "इसको", "इसका", "इसकी", "इसे", "इनको", "इनका",
  // oblique forms of that
  "उसमें", "उसको", "उसका", "उसकी", "उसे", "उनको", "उनका",
] as const;

/**
 * Mandarin pointing words, as Whisper tokenises them.
 *
 * Chinese has no spaces, so a "word" is whatever the recogniser emits as one
 * timed token. whisper-large-v3 returns `这个` as one token and splits the noun
 * after it character by character, so both the two-character forms and the bare
 * demonstratives are listed.
 *
 * `该` and `其` are deliberately absent: `该` is far more often the modal
 * "should", the same homograph trap `EXCLUDED_HOMOGRAPHS` guards for English.
 */
const CHINESE = [
  // 这 / this
  "这", "这个", "这些", "这里", "这儿", "这边", "这块",
  // 那 / that
  "那", "那个", "那些", "那里", "那儿", "那边", "那块",
  // 此 / this (formal, but it does get said)
  "此", "此处",
] as const;

export const DEICTIC_WORDS: ReadonlySet<string> = new Set<string>([
  ...ENGLISH,
  ...HINGLISH,
  ...DEVANAGARI,
  ...CHINESE,
]);

/** Guards the exclusion above against being undone by a careless edit. */
for (const word of EXCLUDED_HOMOGRAPHS) {
  if (DEICTIC_WORDS.has(word)) {
    throw new Error(
      `"${word}" is an English homograph and must not be deictic — see EXCLUDED_HOMOGRAPHS`,
    );
  }
}

/**
 * Strip punctuation and case so `"this,"` and `"This"` both match.
 *
 * `\p{M}` (combining marks) is kept: Devanagari vowel signs and anusvara are
 * marks, not letters, so dropping them would mangle words (`इसमें` becomes
 * `इसम`) or collapse one word into another (`यहां` into `यह`), which is worse
 * than a miss.
 */
export function normalizeWord(word: string): string {
  return word.toLowerCase().replace(/[^\p{L}\p{N}\p{M}]/gu, "");
}

export function isDeictic(word: string): boolean {
  return DEICTIC_WORDS.has(normalizeWord(word));
}

const CJK = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;

/**
 * Words back into a sentence. A space between tokens is right for scripts
 * written with spaces but wrong for CJK, where Whisper returns a character or
 * two at a time and `join(" ")` would turn 这个按钮 into "这个 按 钮". No space
 * where both sides are CJK or CJK is followed by punctuation; a space
 * everywhere else, so "这个 button" keeps its gap.
 */
export function joinWords(words: readonly string[]): string {
  let out = "";
  for (const word of words) {
    if (!word) continue;
    if (!out) { out = word; continue; }
    const tight = CJK.test(out[out.length - 1]!) && (CJK.test(word[0]!) || /^\p{P}/u.test(word));
    out += (tight ? "" : " ") + word;
  }
  return out;
}
