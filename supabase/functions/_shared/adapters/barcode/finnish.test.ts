/** Run: node supabase/functions/_shared/adapters/barcode/finnish.test.ts */
import assert from "node:assert/strict";
import { isValidFinnishReference, isValidIban, parseFinnishBarcode } from "./finnish.ts";
import { test, report } from "../../testing/harness.ts";

//   4 | 2112345600000785 | 000048 | 20 | 000 | 00000000000000012344 | 261015
export const V4 =
  "4" + "2112345600000785" + "000048" + "20" + "000" + "00000000000000012344" + "261015";

console.log("");
console.log("virtuaaliviivakoodi");

test("the fixture is 54 digits", () => assert.equal(V4.length, 54));

test("IBAN mod-97 accepts a valid Finnish IBAN", () =>
  assert.equal(isValidIban("FI2112345600000785"), true));

test("IBAN mod-97 rejects a corrupted one", () =>
  assert.equal(isValidIban("FI2112345600000786"), false));

test("viitenumero check digit accepts a valid reference", () =>
  assert.equal(isValidFinnishReference("12344"), true));

test("viitenumero check digit rejects a transposed reference", () =>
  assert.equal(isValidFinnishReference("12345"), false));

test("parses every field of a version 4 barcode", () => {
  const b = parseFinnishBarcode(V4);
  assert.ok(b);
  assert.equal(b.version, 4);
  assert.equal(b.iban, "FI2112345600000785");
  assert.equal(b.amountCents, 4820);
  assert.equal(b.reference, "12344");
  assert.equal(b.dueDate, "2026-10-15");
  assert.equal(b.ibanValid, true);
  assert.equal(b.referenceValid, true);
});

test("tolerates whitespace from the scanner", () =>
  assert.equal(parseFinnishBarcode(V4.slice(0, 20) + " " + V4.slice(20))?.amountCents, 4820));

test("treats 000000 as no due date", () =>
  assert.equal(parseFinnishBarcode(V4.slice(0, 48) + "000000")?.dueDate, null));

test("rejects an impossible calendar date", () =>
  assert.equal(parseFinnishBarcode(V4.slice(0, 48) + "260231")?.dueDate, null));

test("returns null for anything that is not a bank barcode", () => {
  assert.equal(parseFinnishBarcode("hello"), null);
  assert.equal(parseFinnishBarcode("9".repeat(54)), null);
});

report();
