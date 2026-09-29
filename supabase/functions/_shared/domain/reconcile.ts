/**
 * The arbitration rule between layer 0 and whatever read the document.
 *
 * Pure: no I/O, no vendor, no clock. This is the file to read to understand
 * how Koti decides what a document actually says, and it is the file to argue
 * with if that decision is ever wrong.
 */
import type { BarcodeFacts, DocumentFacts } from "./contracts.ts";

export type FactSource = "barcode" | "engine" | "mixed";

export interface ReconciledFacts {
  readonly amountCents: number | null;
  readonly reference: string | null;
  readonly iban: string | null;
  readonly dueDate: string | null;
  readonly source: FactSource;
  /** Fields where the engine disagreed with a barcode whose checks passed. */
  readonly disagreements: readonly string[];
}

/**
 * One rule: the barcode wins where it is present and its checks pass.
 *
 * A disagreement is not an error. It is the barcode catching a misreading,
 * which is the only reason layer 0 exists -- so it is recorded rather than
 * quietly resolved, and the document is shown to a human as unverified.
 */
export function reconcile(
  barcode: BarcodeFacts | null,
  engine: Pick<DocumentFacts, "amountCents" | "referenceNumber" | "iban" | "dueDate">,
): ReconciledFacts {
  if (!barcode) {
    return {
      amountCents: engine.amountCents,
      reference: engine.referenceNumber,
      iban: engine.iban,
      dueDate: engine.dueDate,
      source: "engine",
      disagreements: [],
    };
  }

  const disagreements: string[] = [];
  const compare = (field: string, trusted: unknown, claimed: unknown) => {
    if (trusted == null || claimed == null) return;
    if (String(trusted) !== String(claimed)) disagreements.push(field);
  };

  compare("amountCents", barcode.amountCents || null, engine.amountCents);
  if (barcode.referenceValid) compare("reference", barcode.reference, engine.referenceNumber);
  if (barcode.ibanValid) compare("iban", barcode.iban, engine.iban?.replace(/\s+/g, ""));
  compare("dueDate", barcode.dueDate, engine.dueDate);

  return {
    // A zero amount in the barcode means "no amount stated", not "free".
    amountCents: barcode.amountCents > 0 ? barcode.amountCents : engine.amountCents,
    reference: barcode.referenceValid ? barcode.reference : engine.referenceNumber,
    iban: barcode.ibanValid ? barcode.iban : engine.iban,
    dueDate: barcode.dueDate ?? engine.dueDate,
    source: disagreements.length > 0 ? "mixed" : "barcode",
    disagreements,
  };
}
