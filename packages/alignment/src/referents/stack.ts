import type { Referent } from "./types.js";


/**
 * The session store. Ordered, queryable, and it survives app switches — which
 * sounds trivial until you notice that no screen-aware assistant on the market
 * keeps one, and it is the only reason a phrase like "that key we showed
 * earlier" has anything to resolve against.
 */
export class ReferentStack {
  private items: Referent[] = [];

  /**
   * Append a referent. The id is assigned here rather than by the caller, so
   * ordering is a property of the stack and cannot be got wrong by whoever is
   * feeding it.
   *
   * There used to be an `index` and a `visit` here too — a per-app excursion
   * counter, so a Compass → VS Code → Compass session could be rendered as
   * three visits rather than two apps. Nothing ever rendered it: the brief
   * groups referents by whether they look deliberate, and `all()` is already
   * chronological, which is the only ordering any consumer asked for.
   */
  add(referent: Omit<Referent, "id"> & { id?: string }): Referent {
    const stored: Referent = {
      ...referent,
      id: referent.id ?? `r${this.items.length + 1}`,
    };
    this.items.push(stored);
    return stored;
  }

  all(): readonly Referent[] {
    return this.items;
  }
}
