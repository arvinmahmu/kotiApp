/**
 * Free-tier text extraction: Tesseract, behind a small self-hosted HTTP service.
 *
 * Tesseract cannot run inside a Deno edge function, so this adapter speaks to a
 * container you deploy yourself. The service contract is deliberately tiny --
 * one endpoint, no state -- so it can be replaced by PaddleOCR, docTR or a
 * managed OCR API without touching anything else in Koti.
 *
 *   POST {baseUrl}/ocr
 *   multipart/form-data: file=<bytes>, languages=fin+eng+swe
 *   200 -> { "text": string, "confidence": number, "language": string | null }
 *
 * Cost is reported as zero because the compute is a fixed monthly server bill,
 * not a per-document charge. That is the whole argument for this tier -- and
 * also its weakness: the bill exists at zero usage.
 */
import { EngineUnavailable, FREE, type DocumentInput, type TextExtractor } from "../../domain/contracts.ts";

/** Scripts worth attempting on Finnish post. Tesseract needs to be told. */
const DEFAULT_LANGUAGES = "fin+eng+swe";

const TIMEOUT_MS = 30_000;

export function tesseractExtractor(
  baseUrl: string,
  languages = DEFAULT_LANGUAGES,
): TextExtractor {
  return {
    id: "tesseract",

    async extract(input: DocumentInput) {
      const form = new FormData();
      form.append("file", new Blob([input.bytes], { type: input.mimeType }), "document");
      form.append("languages", languages);

      let response: Response;
      try {
        response = await fetch(`${baseUrl.replace(/\/$/, "")}/ocr`, {
          method: "POST",
          body: form,
          signal: AbortSignal.timeout(TIMEOUT_MS),
        });
      } catch (err) {
        throw new EngineUnavailable("tesseract", (err as Error).message);
      }

      if (!response.ok) {
        throw new EngineUnavailable("tesseract", `HTTP ${response.status}`);
      }

      const body = await response.json() as {
        text?: string;
        confidence?: number;
        language?: string | null;
      };

      return {
        text: body.text ?? "",
        // Tesseract reports mean word confidence 0..100; normalise, and treat a
        // missing value as "unknown", which the pipeline reads as too low.
        confidence: typeof body.confidence === "number" ? body.confidence / 100 : 0,
        detectedLanguage: body.language ?? null,
        cost: FREE,
      };
    },
  };
}
