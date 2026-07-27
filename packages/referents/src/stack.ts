import type { BackReference, Referent } from "./types.js";

/**
 * Words that make a phrase a back-reference but identify nothing: the deictics
 * and past markers themselves, plus ordinary filler. Excluded from content
 * matching — see `resolveBackReference`.
 */
const TRIGGER_WORDS = new Set([
  "that", "those", "the", "this", "these", "it",
  "earlier", "before", "previously", "showed", "saw", "were", "was",
  "wala", "wale", "jo", "woh", "usko", "uska", "pehle", "dikhaya", "tha",
  "humne", "maine", "karo", "hai", "and", "from", "with", "for",
]);

/**
 * The session store. Ordered, queryable, and it survives app switches — which
 * sounds trivial until you notice that no screen-aware assistant on the market
 * keeps one, and it is the only reason a phrase like "that key we showed
 * earlier" has anything to resolve against.
 */
export class ReferentStack {
  private items: Referent[] = [];
  private visitCounter = 0;
  private lastAppKey: string | undefined;

  /**
   * Append a referent. `index` and `visit` are assigned here rather than by the
   * caller, so ordering is a property of the stack and cannot be got wrong by
   * whoever is feeding it.
   */
  add(referent: Omit<Referent, "index" | "visit" | "id"> & { id?: string }): Referent {
    const appKey = referent.app.bundleId ?? referent.app.name ?? "unknown";
    // A visit is a RUN of consecutive referents in one app. Switching away and
    // back starts a new one, which is what makes the two Compass excursions in
    // a Compass → VS Code → Compass session distinguishable.
    if (appKey !== this.lastAppKey) {
      this.visitCounter += 1;
      this.lastAppKey = appKey;
    }

    const index = this.items.length;
    const stored: Referent = {
      ...referent,
      id: referent.id ?? `r${index + 1}`,
      index,
      visit: this.visitCounter,
    };
    this.items.push(stored);
    return stored;
  }

  all(): readonly Referent[] {
    return this.items;
  }

  get(id: string): Referent | undefined {
    return this.items.find((r) => r.id === id);
  }

  byHold(hold: number): Referent[] {
    return this.items.filter((r) => r.hold === hold);
  }

  /** Referents grouped into app visits, in order — how the plan prompt reads. */
  byVisit(): Array<{ visit: number; app: string; referents: Referent[] }> {
    const out: Array<{ visit: number; app: string; referents: Referent[] }> = [];
    for (const r of this.items) {
      const last = out[out.length - 1];
      if (last && last.visit === r.visit) last.referents.push(r);
      else out.push({ visit: r.visit, app: r.app.name ?? "unknown", referents: [r] });
    }
    return out;
  }

  /** Attach what the user said, once alignment has worked it out. */
  bind(
    id: string,
    binding: Pick<Referent, "utterance" | "confidence" | "reason">,
  ): void {
    const r = this.get(id);
    if (r) Object.assign(r, binding);
  }

  /**
   * Rank past referents for a back-reference phrase.
   *
   * Returns a SHORTLIST, never a verdict. Scoring can tell that a referent is
   * older, in a different app, and shares a word with the phrase; it cannot
   * tell that "the key" means the field called `identifier`. That last step
   * needs the model — so code narrows the field and the model chooses, and the
   * review UI can show what it was choosing between.
   */
  resolveBackReference(phrase: string, atTime: number, limit = 3): BackReference {
    // Strip the words that made this a back-reference in the first place.
    // "that key we showed earlier" is triggered by "that" and "earlier", but
    // the only word that IDENTIFIES anything is "key". Leaving the triggers in
    // divides the match score across filler, so matching the one distinctive
    // term scored lower than a mild recency difference — and a referent that
    // matched nothing won.
    const words = phrase
      .toLowerCase()
      .split(/\s+/)
      .map((w) => w.replace(/[^\p{L}\p{N}\p{M}]/gu, ""))
      .filter((w) => w.length > 2 && !TRIGGER_WORDS.has(w));

    // Only things indicated BEFORE the phrase can be referred back to.
    const past = this.items.filter((r) => r.t < atTime);
    if (past.length === 0) return { phrase, t: atTime, candidates: [] };

    const currentVisit = past[past.length - 1]!.visit;
    const newest = past[past.length - 1]!.t;
    const oldest = past[0]!.t;
    const timeSpan = Math.max(newest - oldest, 1);

    const scored = past.map((r) => {
      const why: string[] = [];

      // Recency is the WEAKEST term, and deliberately so: the phrase says
      // "earlier", which is an explicit instruction not to pick the newest
      // thing. It breaks ties between otherwise equal candidates, nothing more.
      const recency = (r.t - oldest) / timeSpan;
      let score = 0.15 * recency;

      // The visit rule. A phrase saying "earlier" while you are mid-visit is
      // almost never pointing at something from this same visit — you would
      // have just pointed at it instead of describing it.
      if (r.visit !== currentVisit) {
        score += 0.3;
        why.push("earlier visit");
      } else {
        score -= 0.15;
        why.push("same visit as the phrase");
      }

      // Word overlap against whatever we grounded. AX text is exact, so a hit
      // there is worth more than a hit in OCR's guesswork.
      const axText = r.text.ax.join(" ").toLowerCase();
      const ocrText = r.text.ocr.join(" ").toLowerCase();
      const axHits = words.filter((w) => axText.includes(w));
      const ocrHits = words.filter((w) => ocrText.includes(w) && !axText.includes(w));
      // Content match dominates everything else: if you named the thing, that
      // is far stronger evidence than when or where you were standing.
      if (words.length > 0 && axHits.length) {
        score += 0.5 * Math.min(axHits.length / words.length, 1);
        why.push(`matches ${axHits.join(", ")} (ax)`);
      }
      if (words.length > 0 && ocrHits.length) {
        score += 0.25 * Math.min(ocrHits.length / words.length, 1);
        why.push(`matches ${ocrHits.join(", ")} (ocr)`);
      }

      // A referent that grounded nothing is a poor thing to refer back to.
      if (r.text.ax.length === 0 && r.text.ocr.length === 0) {
        score -= 0.2;
        why.push("grounded nothing");
      }

      return { referentId: r.id, score: Math.max(score, 0), why: why.join("; ") };
    });

    return {
      phrase,
      t: atTime,
      candidates: scored.sort((a, b) => b.score - a.score).slice(0, limit),
    };
  }

  /** PRD §10: a session is discarded unless the user saves it. */
  discard(): void {
    this.items = [];
    this.visitCounter = 0;
    this.lastAppKey = undefined;
  }

  toJSON(): Referent[] {
    return this.items;
  }

  static fromJSON(referents: Referent[]): ReferentStack {
    const stack = new ReferentStack();
    stack.items = [...referents];
    stack.visitCounter = referents.reduce((max, r) => Math.max(max, r.visit), 0);
    stack.lastAppKey =
      referents[referents.length - 1]?.app.bundleId ??
      referents[referents.length - 1]?.app.name;
    return stack;
  }
}
