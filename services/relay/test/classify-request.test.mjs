import { test } from "node:test";
import assert from "node:assert/strict";

import { REFERENCE_CANDIDATES, classifyRequest } from "../src/relay.mjs";
import { REFERENCE } from "@deiko/core/lib/context.mjs";

const task = (n) => ({ id: `t-20260918-10000${n}`, title: `Task ${n}`, recent: ["x".repeat(390)] });

test("Jev is asked whether the brief points back, and at which of local search's top five", () => {
  const { questions, state } = classifyRequest({ v: 3, narration: "do you remember the pricing fixes? in that task make the page pink", tasks: [1, 2, 3, 4, 5, 6].map(task) });
  assert.equal(REFERENCE_CANDIDATES, REFERENCE.candidates, "the relay asks about exactly the tasks the app will consider");
  assert.equal(questions.refers_back.type, "noul");
  assert.deepEqual(Object.keys(questions).filter((k) => k.startsWith("ref_")), [1, 2, 3, 4, 5].map((n) => `ref_t-20260918-10000${n}`));
  assert.ok(questions["same_t-20260918-100006"], "every task still gets its same-work question");
  assert.equal(state.tasks["t-20260918-100001"].recent[0].length, 390, "a full multi-line summary fits");
});

test("with no earlier tasks, nothing is asked about pointing back", () => {
  const { questions } = classifyRequest({ v: 3, narration: "make the page pink", tasks: [] });
  assert.equal(questions.refers_back, undefined);
});
