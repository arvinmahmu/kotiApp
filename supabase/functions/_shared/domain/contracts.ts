/**
 * The domain contract.
 *
 * This file knows nothing about Anthropic, Tesseract, Supabase or HTTP. Every
 * engine in the system implements one of the ports below, and the use case in
 * `pipeline/analyse.ts` depends only on these interfaces -- never on a vendor.
 *
 * That is the whole point of the structure: swapping Claude for OPUS-MT, or
 * adding a third engine, is a new file in `adapters/` and one line in
 * `pipeline/registry.ts`. Nothing else moves.
 */

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

export interface DocumentInput {
  /** Raw bytes of the uploaded file. */
  readonly bytes: Uint8Array;
  readonly mimeType: string;
  /** The barcode payload the phone scanned, if any. */
  readonly scannedBarcode: string | null;
}

/** What a reader wants and in which language. */
export interface ReaderContext {
  /** BCP-47, e.g. "ckb". */
  readonly language: string;
  /** Human name for the prompt, e.g. "Kurdish (Sorani)". */
  readonly languageName: string;
}

/** Layer 0. Free, deterministic, and authoritative where its checks pass. */
export interface BarcodeFacts {
  readonly iban: string;
  readonly amountCents: number;
  readonly reference: string;
  readonly dueDate: string | null;
  readonly ibanValid: boolean;
  readonly referenceValid: boolean;
}

/** Facts a document states, however they were obtained. */
export interface DocumentFacts {
  readonly docType: string;
  readonly title: string;
  readonly senderName: string | null;
  readonly issueDate: string | null;
  readonly dueDate: string | null;
  readonly amountCents: number | null;
  readonly currency: string | null;
  readonly referenceNumber: string | null;
  readonly iban: string | null;
  readonly sourceLanguage: string;
  /** Fields the engine could not read confidently. Honesty is a feature. */
  readonly uncertainFields: readonly string[];
}

/** The actionable part. Only an Explainer can produce this. */
export interface Explanation {
  readonly whatItIs: string;
  readonly whatToDo: string;
  readonly byWhen: string | null;
  readonly howMuch: string | null;
  readonly details: string | null;
}

/** Every engine reports what it cost, so free and paid record identically. */
export interface EngineCost {
  readonly micros: number;
  readonly inputTokens: number | null;
  readonly outputTokens: number | null;
  readonly cacheReadTokens: number | null;
}

export const FREE: EngineCost = {
  micros: 0,
  inputTokens: null,
  outputTokens: null,
  cacheReadTokens: null,
};

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------

/** Anything that turns a document into plain text. Tesseract, a PDF layer. */
export interface TextExtractor {
  readonly id: string;
  extract(input: DocumentInput): Promise<{
    text: string;
    /** 0..1. Low confidence is what would justify falling back to vision. */
    confidence: number;
    detectedLanguage: string | null;
    cost: EngineCost;
  }>;
}

/** Anything that turns text into another language. OPUS-MT, Claude. */
export interface Translator {
  readonly id: string;
  translate(args: {
    text: string;
    from: string | null;
    to: string;
  }): Promise<{ text: string; cost: EngineCost }>;
}

/**
 * Anything that reads a document and says what to do about it.
 *
 * There is deliberately no free implementation of this port. Extracting and
 * translating text is a solved, cheap problem; understanding a Finnish tax
 * decision well enough to tell an anxious person what it requires is not.
 * That asymmetry is the product's pricing boundary, expressed in the type
 * system rather than in a billing rule.
 */
export interface Explainer {
  readonly id: string;
  explain(args: {
    input: DocumentInput;
    reader: ReaderContext;
    /** Facts layer 0 already established; the engine must not contradict them. */
    known: BarcodeFacts | null;
  }): Promise<{ facts: DocumentFacts; explanation: Explanation; cost: EngineCost }>;
}

// ---------------------------------------------------------------------------
// Pipeline results
// ---------------------------------------------------------------------------

/**
 * The three products, as a discriminated union, in increasing order of value:
 * we filed it, we read it to you, we told you what to do. Callers must handle
 * all three, which is the point -- these are not better and worse versions of
 * one thing, and the UI must not pretend they are.
 */
export type ReadingResult =
  /**
   * Free, exact, and available at any scale: the payment barcode alone. Enough
   * to file the bill and set the reminder, which is most of the day-to-day
   * value -- and it needs no language at all, so it serves the users no
   * translation engine covers.
   */
  | {
    readonly kind: "tracked";
    readonly engine: string;
    readonly barcode: BarcodeFacts;
    readonly cost: EngineCost;
  }
  | {
    readonly kind: "explained";
    readonly engine: string;
    readonly facts: DocumentFacts;
    readonly explanation: Explanation;
    readonly cost: EngineCost;
  }
  | {
    readonly kind: "translated";
    readonly engine: string;
    readonly sourceLanguage: string | null;
    readonly originalText: string;
    readonly translatedText: string;
    readonly confidence: number;
    readonly cost: EngineCost;
  };

export class EngineUnavailable extends Error {
  constructor(engineId: string, cause: string) {
    super(`engine ${engineId} unavailable: ${cause}`);
    this.name = "EngineUnavailable";
  }
}

export class UnreadableDocument extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = "UnreadableDocument";
  }
}
