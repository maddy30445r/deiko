import type { Referent } from "./types.js";


/**
 * The session store: ordered, queryable, and it survives app switches, so a
 * phrase like "that key we showed earlier" has something to resolve against.
 */
export class ReferentStack {
  private items: Referent[] = [];

  /**
   * Append a referent. The id is assigned here, so ordering is a property of
   * the stack and cannot be got wrong by the caller.
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
