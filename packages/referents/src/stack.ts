import type { Referent } from "./types.js";


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
