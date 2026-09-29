/** Run: node supabase/functions/_shared/domain/reconcile.test.ts */
import assert from "node:assert/strict";
import { reconcile } from "./reconcile.ts";
import { parseFinnishBarcode } from "../adapters/barcode/finnish.ts";
import { test, report } from "../testing/harness.ts";

const V4 =
  "4" + "2112345600000785" + "000048" + "20" + "000" + "00000000000000012344" + "261015";

const engineSaid = (over: Record<string, unknown> = {}) => ({
  amountCents: 4820,
  referenceNumber: "12344",
  iban: "FI2112345600000785",
  dueDate: "2026-10-15",
  ...over,
});

console.log("");
console.log("reconciliation");

test("with no barcode, the engine's reading stands", () => {
  const r = reconcile(null, engineSaid({ amountCents: 1234 }));
  assert.equal(r.source, "engine");
  assert.equal(r.amountCents, 1234);
  assert.deepEqual(r.disagreements, []);
});

test("the barcode wins when the engine misreads the amount", () => {
  const r = reconcile(parseFinnishBarcode(V4)!, engineSaid({ amountCents: 4520 }));
  assert.equal(r.amountCents, 4820);
  assert.equal(r.source, "mixed");
  assert.deepEqual(r.disagreements, ["amountCents"]);
});

test("agreement is recorded as a clean barcode read", () => {
  const r = reconcile(parseFinnishBarcode(V4)!, engineSaid());
  assert.equal(r.source, "barcode");
  assert.deepEqual(r.disagreements, []);
});

test("a zero barcode amount falls through to the engine", () => {
  const zero = V4.slice(0, 17) + "000000" + "00" + V4.slice(25);
  const r = reconcile(parseFinnishBarcode(zero)!, engineSaid({ amountCents: 999 }));
  assert.equal(r.amountCents, 999);
});

test("a due date only the engine saw is kept", () => {
  const noDate = parseFinnishBarcode(V4.slice(0, 48) + "000000")!;
  assert.equal(reconcile(noDate, engineSaid()).dueDate, "2026-10-15");
});

report();
