import assert from "node:assert/strict";
import { test } from "node:test";

import { isDeictic, joinWords, normalizeWord } from "../src/deictic.js";

test("Mandarin pointing words are deictic in the forms Whisper emits", () => {
  // whisper-large-v3 returns `这个` as one timed token, then the noun after it
  // one character at a time, so the bare demonstrative and the two-character
  // form both have to count.
  for (const word of ["这个", "这", "那个", "那", "这里", "那儿", "这边"]) {
    assert.ok(isDeictic(word), `${word} should point`);
  }
});

test("Chinese nouns and the modal 该 do not point", () => {
  for (const word of ["按钮", "状态", "弹窗", "该", "菜单"]) {
    assert.ok(!isDeictic(word), `${word} must not point`);
  }
});

test("joinWords spaces Latin and closes up CJK, as each script is written", () => {
  assert.equal(joinWords(["this", "button", "resets"]), "this button resets");
  assert.equal(joinWords(["这个", "按", "钮", "点", "了", ","]), "这个按钮点了,");
  assert.equal(joinWords(["这个", "button", "有", "问题"]), "这个 button 有问题");
  assert.equal(joinWords(["", "a", "", "b"]), "a b");
});

test("normalizeWord keeps CJK letters and drops the punctuation Whisper attaches", () => {
  assert.equal(normalizeWord("这个,"), "这个");
  assert.equal(normalizeWord("那个。"), "那个");
});
