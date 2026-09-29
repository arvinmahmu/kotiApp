/**
 * Free-tier translation: Marian NMT / OPUS-MT (or Argos Translate, which wraps
 * the same models) behind a self-hosted HTTP service.
 *
 *   POST {baseUrl}/translate
 *   { "text": string, "from": string | null, "to": string }
 *   200 -> { "text": string, "pivoted": boolean }
 *
 * Two honest limits, both of which belong in the code rather than in a wiki:
 *
 * 1. Coverage. OPUS-MT is strong for fi->en/de/sv/ru and thin to absent for
 *    Persian, Somali and Kurdish -- which are exactly Koti's first users'
 *    languages. `supports()` is therefore not decoration: the pipeline must be
 *    able to ask before promising a household something it cannot deliver.
 *
 * 2. Pivoting. Where no direct model exists, these services route through
 *    English, compounding error twice. The response says when that happened so
 *    the UI can mark the translation as lower confidence.
 */
import { EngineUnavailable, FREE, type Translator } from "../../domain/contracts.ts";

const TIMEOUT_MS = 60_000;

/** Pairs a stock OPUS-MT deployment can be expected to do directly from Finnish. */
const DIRECT_FROM_FINNISH = new Set(["en", "sv", "de", "ru", "et", "fr", "es", "nl"]);

export interface OpusMtTranslator extends Translator {
  /** Whether this engine can serve the pair at all, and how well. */
  supports(from: string | null, to: string): "direct" | "pivot" | "no";
}

export function opusMtTranslator(baseUrl: string): OpusMtTranslator {
  return {
    id: "opus-mt",

    supports(from, to) {
      if (from === to) return "direct";
      if (from === "fi" && DIRECT_FROM_FINNISH.has(to)) return "direct";
      if (DIRECT_FROM_FINNISH.has(to)) return "pivot";
      // Persian, Kurdish, Somali and friends: no usable open model from
      // Finnish. Say so rather than returning confident nonsense.
      return "no";
    },

    async translate({ text, from, to }) {
      let response: Response;
      try {
        response = await fetch(`${baseUrl.replace(/\/$/, "")}/translate`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ text, from, to }),
          signal: AbortSignal.timeout(TIMEOUT_MS),
        });
      } catch (err) {
        throw new EngineUnavailable("opus-mt", (err as Error).message);
      }

      if (!response.ok) {
        throw new EngineUnavailable("opus-mt", `HTTP ${response.status}`);
      }

      const body = await response.json() as { text?: string };
      if (!body.text) {
        throw new EngineUnavailable("opus-mt", "empty translation");
      }

      return { text: body.text, cost: FREE };
    },
  };
}
