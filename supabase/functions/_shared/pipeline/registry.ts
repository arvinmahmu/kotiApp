/**
 * Which engines read a document, for whom.
 *
 * The composition root. This is the only file that names both a plan and a
 * vendor, and it is where a new engine is wired in. Everything downstream
 * depends on `Pipeline`, not on what implements it.
 */
import type {
  BarcodeFacts,
  DocumentInput,
  Explainer,
  ReaderContext,
  ReadingResult,
  TextExtractor,
  Translator,
} from "../domain/contracts.ts";
import { UnreadableDocument } from "../domain/contracts.ts";

/** Mirrors `plans.reading_engine` in the database -- quotas and engines are data. */
export type EngineTier = "barcode" | "ocr" | "ai";

export interface Pipeline {
  readonly tier: EngineTier;
  readonly id: string;
  /** True when running this costs money, and so must pass the meter first. */
  readonly metered: boolean;
  read(
    input: DocumentInput,
    reader: ReaderContext,
    known: BarcodeFacts | null,
  ): Promise<ReadingResult>;
}

/**
 * The free floor, and the fallback when an allowance runs out.
 *
 * Reads nothing. Files what the payment barcode already proved: payee, amount,
 * reference, due date. Costs nothing to run, is exact rather than approximate,
 * and works for every language because numbers need no translating -- which is
 * why this, and not machine translation, is Koti's free tier.
 */
export class BarcodePipeline implements Pipeline {
  readonly tier: EngineTier = "barcode";
  readonly metered = false;
  readonly id = "barcode:finnish";

  read(
    _input: DocumentInput,
    _reader: ReaderContext,
    known: BarcodeFacts | null,
  ): Promise<ReadingResult> {
    if (!known) {
      throw new UnreadableDocument(
        "this document has no payment barcode, so it cannot be read without an explanation",
      );
    }
    return Promise.resolve({
      kind: "tracked",
      engine: this.id,
      barcode: known,
      cost: { micros: 0, inputTokens: null, outputTokens: null, cacheReadTokens: null },
    });
  }
}

/**
 * Paid tier: one vision call both extracts the facts and explains what to do.
 */
export class ExplainPipeline implements Pipeline {
  readonly tier: EngineTier = "ai";
  readonly metered = true;

  readonly #explainer: Explainer;

  constructor(explainer: Explainer) {
    this.#explainer = explainer;
  }

  get id(): string {
    return `explain:${this.#explainer.id}`;
  }

  async read(
    input: DocumentInput,
    reader: ReaderContext,
    known: BarcodeFacts | null,
  ): Promise<ReadingResult> {
    const { facts, explanation, cost } = await this.#explainer.explain({ input, reader, known });
    return { kind: "explained", engine: this.#explainer.id, facts, explanation, cost };
  }
}

/**
 * Free tier: read the text, then translate it. The result is the document in
 * the reader's language -- not advice about it. That distinction is the
 * pricing boundary and the UI must not blur it.
 */
export class TranslatePipeline implements Pipeline {
  readonly tier: EngineTier = "free";
  readonly metered = false;

  readonly #extractor: TextExtractor;
  readonly #translator: Translator;
  /** Below this, the text is too poor to be worth translating. */
  readonly #minConfidence: number;

  constructor(extractor: TextExtractor, translator: Translator, minConfidence = 0.55) {
    this.#extractor = extractor;
    this.#translator = translator;
    this.#minConfidence = minConfidence;
  }

  get id(): string {
    return `translate:${this.#extractor.id}+${this.#translator.id}`;
  }

  async read(input: DocumentInput, reader: ReaderContext): Promise<ReadingResult> {
    const extracted = await this.#extractor.extract(input);

    if (extracted.text.trim().length < 20) {
      throw new UnreadableDocument("no readable text was found in this image");
    }
    if (extracted.confidence < this.#minConfidence) {
      throw new UnreadableDocument("the photograph is too unclear to read reliably");
    }

    const translated = await this.#translator.translate({
      text: extracted.text,
      from: extracted.detectedLanguage,
      to: reader.language,
    });

    return {
      kind: "translated",
      engine: this.id,
      sourceLanguage: extracted.detectedLanguage,
      originalText: extracted.text,
      translatedText: translated.text,
      confidence: extracted.confidence,
      cost: {
        micros: extracted.cost.micros + translated.cost.micros,
        inputTokens: null,
        outputTokens: null,
        cacheReadTokens: null,
      },
    };
  }
}

export interface RegistryConfig {
  readonly anthropicApiKey?: string;
  /** Base URL of the self-hosted OCR service, if one is deployed. */
  readonly ocrServiceUrl?: string;
  /** Base URL of the self-hosted translation service, if one is deployed. */
  readonly translateServiceUrl?: string;
}

/**
 * Resolve the pipeline for a request.
 *
 * `tier` is the engine the plan is entitled to *while it has allowance*. When
 * the meter says no, the caller asks again for "barcode" -- so running out is
 * an ordinary state with its own pipeline, not an error branch.
 *
 * The OCR tier is wired but not deployed. It resolves only when both services
 * are configured, and otherwise degrades to the barcode floor rather than
 * silently spending money on a plan that was sold as free.
 */
export function resolvePipeline(
  tier: EngineTier,
  config: RegistryConfig,
  build: {
    explainer: (apiKey: string) => Explainer;
    extractor: (baseUrl: string) => TextExtractor;
    translator: (baseUrl: string) => Translator;
  },
): Pipeline {
  if (tier === "barcode") return new BarcodePipeline();

  if (tier === "ocr") {
    if (config.ocrServiceUrl && config.translateServiceUrl) {
      return new TranslatePipeline(
        build.extractor(config.ocrServiceUrl),
        build.translator(config.translateServiceUrl),
      );
    }
    return new BarcodePipeline();
  }

  if (!config.anthropicApiKey) {
    throw new UnreadableDocument("no reading engine is configured");
  }
  return new ExplainPipeline(build.explainer(config.anthropicApiKey));
}
