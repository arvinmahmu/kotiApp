/** Run: node supabase/functions/_shared/pipeline/registry.test.ts */
import assert from "node:assert/strict";
import { resolvePipeline } from "./registry.ts";
import { test, report } from "../testing/harness.ts";

const stub = {
  explainer: () => ({ id: "claude", explain: () => Promise.reject(new Error("unused")) }),
  extractor: () => ({ id: "tesseract", extract: () => Promise.reject(new Error("unused")) }),
  translator: () => ({ id: "opus-mt", translate: () => Promise.reject(new Error("unused")) }),
} as never;

const everything = {
  anthropicApiKey: "k",
  ocrServiceUrl: "http://ocr",
  translateServiceUrl: "http://mt",
};

console.log("");
console.log("engine selection");

test("the free floor reads nothing and costs nothing", () => {
  const p = resolvePipeline("barcode", everything, stub);
  assert.equal(p.id, "barcode:finnish");
  assert.equal(p.metered, false, "the free floor must never consume allowance");
});

test("a paid plan uses the vision engine, metered", () => {
  const p = resolvePipeline("ai", everything, stub);
  assert.equal(p.id, "explain:claude");
  assert.equal(p.metered, true);
});

test("the OCR tier is used only when both services are deployed", () => {
  const p = resolvePipeline("ocr", everything, stub);
  assert.equal(p.id, "translate:tesseract+opus-mt");
  assert.equal(p.metered, false);
});

// This is the rule that protects the bill: a plan sold as free must never
// quietly resolve to a paid engine because a service was not deployed.
test("an undeployed OCR tier falls to the free floor, NOT to vision", () => {
  const p = resolvePipeline("ocr", { anthropicApiKey: "k" }, stub);
  assert.equal(p.id, "barcode:finnish");
  assert.equal(p.metered, false, "a free plan must never spend money");
});

test("a half-deployed OCR stack does not count as deployed", () => {
  const p = resolvePipeline("ocr", { anthropicApiKey: "k", ocrServiceUrl: "http://ocr" }, stub);
  assert.equal(p.id, "barcode:finnish");
});

test("with no AI key at all, the paid tier refuses rather than guesses", () => {
  assert.throws(() => resolvePipeline("ai", {}, stub), /no reading engine is configured/);
});

test("but the free floor still works with nothing configured", () => {
  assert.equal(resolvePipeline("barcode", {}, stub).id, "barcode:finnish");
});

report();
