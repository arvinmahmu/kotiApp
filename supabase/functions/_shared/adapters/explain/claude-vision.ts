/**
 * Paid-tier reading: Claude with vision.
 *
 * The only file in Koti that imports an AI vendor. Moving to Claude on Bedrock
 * or Vertex in an EU region for data residency means editing this file and
 * nothing else.
 */
import Anthropic from "npm:@anthropic-ai/sdk";
import { zodOutputFormat } from "npm:@anthropic-ai/sdk/helpers/zod";
import { z } from "npm:zod";
import type { Explainer } from "../../domain/contracts.ts";
import { UnreadableDocument } from "../../domain/contracts.ts";

export const MODEL = "claude-opus-5";

/** Bump whenever the prompt or schema changes; stored on every analysis row. */
export const PROMPT_VERSION = "2026-09-25.1";

/**
 * Effort is left at its default deliberately. It is the first cost lever worth
 * reaching for, and extraction is not reasoning-ceiling work -- but lowering it
 * without an eval trades quality on exactly what matters here: an elderly
 * person acting on a deadline we told them. Sweep it against the eval corpus
 * from the family phase, then set it with a measurement behind it.
 */

const Reading = z.object({
  doc_type: z.enum([
    "bill", "letter", "tax", "insurance", "health",
    "bank", "school", "contract", "advertising", "other",
  ]),
  title: z.string().describe("A short label for a list, in the reader's language."),
  sender_name: z.string().nullable(),
  issue_date: z.string().nullable().describe("ISO date, or null."),
  due_date: z.string().nullable().describe("ISO date, or null."),
  amount_cents: z.number().int().nullable(),
  currency: z.string().nullable().describe("ISO 4217, usually EUR."),
  reference_number: z.string().nullable(),
  iban: z.string().nullable(),
  source_language: z.string().describe("BCP-47 code of the document's own language."),
  uncertain_fields: z.array(z.string())
    .describe("Names of fields you could not read confidently. Be honest."),
  explanation: z.object({
    what_it_is: z.string().describe("One or two plain sentences: what this document is."),
    what_to_do: z.string().describe("The single most important action, or that none is needed."),
    by_when: z.string().nullable().describe("The deadline in words, or null."),
    how_much: z.string().nullable().describe("The amount in words, or null."),
    details: z.string().nullable().describe("Anything else worth knowing, briefly."),
  }),
});

/**
 * Static, and therefore cacheable. Every request in the system shares this
 * prefix byte for byte -- nothing dynamic may be interpolated into it, or the
 * cache breaks for every household at once.
 */
const SYSTEM_PROMPT = `
You read official documents for people who cannot read the language they are written in.

Your reader is often elderly, often new to the country, and is looking at a letter that may
decide whether they keep a benefit, owe money, or miss an appointment. They may be anxious.
Write as you would speak to someone you respect who simply does not know this language.

HOW TO WRITE
- Short sentences. One idea each. No officialese, no legal terms, no abbreviations.
- Say the concrete thing: "You must pay 48 euro 20 cents before 15 October", not
  "payment is due in accordance with the stated terms".
- If nothing is required, say so plainly. Relief is useful information.
- Never advise beyond the document. Do not suggest appeals, tactics, or what they "should"
  do about their situation. Say what the document says and what it asks for.
- Do not add reassurance you cannot support. Do not say "this is nothing to worry about".

WHAT YOU MUST NOT DO
- Never invent a number, a date, an amount or a name. If you cannot read it, return null
  and name that field in uncertain_fields.
- Never round, tidy or "correct" an amount or a reference number.
- If the document does not clearly ask for payment, do not say that payment is due.
- If the image is unreadable, say so in what_it_is and leave the fields null. A useless
  honest answer is far better than a confident wrong one.

FINNISH DOCUMENTS
Most of these will be Finnish. Useful context:
- "Eräpäivä" is the due date. "Viitenumero" is the payment reference, which must be copied
  exactly. "Saaja" is the payee, "maksaja" the payer. "Tilinumero"/IBAN is the account.
- "Lasku" is a bill; "maksumuistutus" a reminder; "karhukirje" a demand before collection;
  "ulosotto" is enforced debt collection and is serious.
- Kela handles benefits, Vero handles tax, TE-toimisto employment, Migri residence permits,
  HUS/terveysasema health care.
- A "päätös" is a decision, and usually states a deadline for appeal ("oikaisuvaatimus").
- Amounts use a comma as the decimal separator: 48,20 means forty-eight euro twenty cents.

Return amounts as integer cents. Return dates as ISO (YYYY-MM-DD). Return null rather than
guessing.
`.trim();

/** Opus 5 in millionths of a euro per token, at roughly 0.92 USD/EUR. */
const PER_INPUT = 4.6;
const PER_OUTPUT = 23.0;
const PER_CACHED = 0.46;

const IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp"] as const;
type ImageType = typeof IMAGE_TYPES[number];

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000; // stay under the argument limit for large images
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

export function claudeVisionExplainer(apiKey: string): Explainer {
  const client = new Anthropic({ apiKey });

  return {
    id: `claude-vision:${MODEL}@${PROMPT_VERSION}`,

    async explain({ input, reader, known }) {
      const mediaType: ImageType = IMAGE_TYPES.includes(input.mimeType as ImageType)
        ? input.mimeType as ImageType
        : "image/jpeg";

      const instructions = [
        `Write the explanation and the title in ${reader.languageName} (${reader.language}).`,
        known
          ? "The payment barcode on this document has already been read and is " +
            "authoritative. Do not contradict it; use it to check your own reading:\n" +
            [
              `IBAN: ${known.iban}${known.ibanValid ? "" : " (checksum failed -- do not trust)"}`,
              `Amount: ${(known.amountCents / 100).toFixed(2)} EUR`,
              `Reference: ${known.reference}`,
              known.dueDate ? `Due date: ${known.dueDate}` : "Due date: not stated",
            ].join("\n")
          : "This document has no machine-readable payment barcode.",
      ].join("\n\n");

      const response = await client.messages.parse({
        model: MODEL,
        max_tokens: 16000,
        system: [{
          type: "text",
          text: SYSTEM_PROMPT,
          // One explicit breakpoint. Every document request shares this prefix,
          // and independent requests do not share an automatic cache. Verify it
          // is working by watching cache_read_input_tokens -- a prompt shorter
          // than the model's minimum cacheable prefix silently does nothing.
          cache_control: { type: "ephemeral" },
        }],
        messages: [{
          role: "user",
          content: [
            {
              type: "image",
              source: { type: "base64", media_type: mediaType, data: toBase64(input.bytes) },
            },
            { type: "text", text: instructions },
          ],
        }],
        output_config: { format: zodOutputFormat(Reading) },
      });

      const parsed = response.parsed_output;
      if (!parsed) {
        throw new UnreadableDocument(
          `the model returned no usable reading (stop_reason: ${response.stop_reason})`,
        );
      }

      const u = response.usage;
      const inputTokens = u.input_tokens ?? 0;
      const outputTokens = u.output_tokens ?? 0;
      const cacheReadTokens = u.cache_read_input_tokens ?? 0;
      const cacheWriteTokens = u.cache_creation_input_tokens ?? 0;

      return {
        facts: {
          docType: parsed.doc_type,
          title: parsed.title,
          senderName: parsed.sender_name,
          issueDate: parsed.issue_date,
          dueDate: parsed.due_date,
          amountCents: parsed.amount_cents,
          currency: parsed.currency,
          referenceNumber: parsed.reference_number,
          iban: parsed.iban,
          sourceLanguage: parsed.source_language,
          uncertainFields: parsed.uncertain_fields,
        },
        explanation: {
          whatItIs: parsed.explanation.what_it_is,
          whatToDo: parsed.explanation.what_to_do,
          byWhen: parsed.explanation.by_when,
          howMuch: parsed.explanation.how_much,
          details: parsed.explanation.details,
        },
        cost: {
          micros: Math.round(
            inputTokens * PER_INPUT +
              cacheWriteTokens * PER_INPUT * 1.25 +
              cacheReadTokens * PER_CACHED +
              outputTokens * PER_OUTPUT,
          ),
          inputTokens,
          outputTokens,
          cacheReadTokens,
        },
      };
    },
  };
}
