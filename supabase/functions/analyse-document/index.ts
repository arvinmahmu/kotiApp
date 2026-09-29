/**
 * analyse-document -- the HTTP shell.
 *
 * Deliberately thin. It does authorisation, storage, metering and persistence;
 * it does not know how a document is read. That lives behind `Pipeline`, so
 * adding an engine never touches this file.
 *
 * Authorisation rule, held everywhere: a user-scoped client proves the caller
 * may touch this row, and only then does the service-role client write. The
 * service role never reads its own input.
 */
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { parseFinnishBarcode } from "../_shared/adapters/barcode/finnish.ts";
import { claudeVisionExplainer } from "../_shared/adapters/explain/claude-vision.ts";
import { tesseractExtractor } from "../_shared/adapters/extract/tesseract.ts";
import { opusMtTranslator } from "../_shared/adapters/translate/opus-mt.ts";
import {
  EngineUnavailable,
  UnreadableDocument,
  type DocumentInput,
  type ReadingResult,
} from "../_shared/domain/contracts.ts";
import { reconcile } from "../_shared/domain/reconcile.ts";
import { resolvePipeline, type EngineTier } from "../_shared/pipeline/registry.ts";

const env = (key: string) => Deno.env.get(key) ?? "";

const SUPABASE_URL = env("SUPABASE_URL");
const ANON_KEY = env("SUPABASE_ANON_KEY");
const SERVICE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");

const REGISTRY_CONFIG = {
  anthropicApiKey: env("ANTHROPIC_API_KEY") || undefined,
  ocrServiceUrl: env("OCR_SERVICE_URL") || undefined,
  translateServiceUrl: env("TRANSLATE_SERVICE_URL") || undefined,
};

const BUILDERS = {
  explainer: claudeVisionExplainer,
  extractor: tesseractExtractor,
  translator: opusMtTranslator,
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

const asDate = (iso: string | null) => (iso ? `${iso}T00:00:00Z` : null);

// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "missing authorization" }, 401);

  let itemId: string;
  let scannedBarcode: string | null;
  try {
    const body = await req.json();
    itemId = body.item_id;
    scannedBarcode = body.barcode ?? null;
    if (!itemId) throw new Error("item_id is required");
  } catch (err) {
    return json({ error: (err as Error).message }, 400);
  }

  // -- authorisation: RLS decides, and tells us nothing if the answer is no --
  const asUser = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });

  const { data: { user } } = await asUser.auth.getUser();
  if (!user) return json({ error: "not signed in" }, 401);

  const { data: doc } = await asUser
    .from("document_view")
    .select("item_id, workspace_id, storage_path, mime_type, document_status")
    .eq("item_id", itemId)
    .maybeSingle();

  if (!doc) return json({ error: "not found" }, 404);
  if (doc.document_status === "ready") return json({ status: "already_read" });

  const { data: profile } = await asUser
    .from("profiles")
    .select("explain_language, languages:explain_language(name_en)")
    .eq("id", user.id)
    .single();

  const reader = {
    language: profile?.explain_language ?? "en",
    languageName:
      (profile as { languages?: { name_en?: string } } | null)?.languages?.name_en ?? "English",
  };

  const { data: workspace } = await asUser
    .from("workspaces")
    .select("plan, plans:plan(reading_engine)")
    .eq("id", doc.workspace_id)
    .single();

  const tier = ((workspace as { plans?: { reading_engine?: string } } | null)
    ?.plans?.reading_engine ?? "ai") as EngineTier;

  // -- everything below writes ---------------------------------------------
  const asService: SupabaseClient = createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { persistSession: false },
  });

  const fail = async (message: string, status = 500) => {
    await asService.from("documents")
      .update({ status: "failed", error_message: message })
      .eq("item_id", itemId);
    return json({ error: message }, status);
  };

  await asService.from("documents").update({ status: "processing" }).eq("item_id", itemId);

  const { data: blob, error: downloadError } = await asService.storage
    .from("documents").download(doc.storage_path);
  if (downloadError || !blob) return await fail("could not read the uploaded image");

  const bytes = new Uint8Array(await blob.arrayBuffer());
  const contentHash = await sha256(bytes);

  // -- layer 0, always, free ------------------------------------------------
  const barcode = scannedBarcode ? parseFinnishBarcode(scannedBarcode) : null;

  const applyBarcodeOnly = async (status: string) => {
    if (!barcode) {
      await asService.from("documents")
        .update({ status, content_hash: contentHash }).eq("item_id", itemId);
      return;
    }
    await asService.from("documents").update({
      status,
      content_hash: contentHash,
      barcode_raw: scannedBarcode,
      iban: barcode.ibanValid ? barcode.iban : null,
      reference_number: barcode.referenceValid ? barcode.reference : null,
      extraction_source: "barcode",
      error_message: null,
    }).eq("item_id", itemId);
    await asService.from("items").update({
      amount_cents: barcode.amountCents > 0 ? barcode.amountCents : null,
      currency: barcode.amountCents > 0 ? "EUR" : null,
      due_at: asDate(barcode.dueDate),
      all_day: true,
    }).eq("id", itemId);
  };

  // -- never read the same image twice; runs before the meter ---------------
  const { data: twin } = await asService
    .from("documents").select("item_id")
    .eq("content_hash", contentHash).eq("status", "ready")
    .neq("item_id", itemId).maybeSingle();

  if (twin) {
    const { data: previous } = await asService
      .from("document_explanations").select("*")
      .eq("item_id", twin.item_id).eq("language", reader.language).maybeSingle();

    if (previous) {
      const { item_id: _drop, id: _id, created_at: _at, ...copy } = previous;
      await asService.from("document_explanations")
        .insert({ ...copy, item_id: itemId, workspace_id: doc.workspace_id });
      await asService.from("documents")
        .update({ status: "ready", content_hash: contentHash }).eq("item_id", itemId);
      return json({ status: "ready", reused: true, cost_micros: 0 });
    }
  }

  // -- pick the engine ------------------------------------------------------
  let pipeline;
  try {
    pipeline = resolvePipeline(tier, REGISTRY_CONFIG, BUILDERS);
  } catch (err) {
    return await fail((err as Error).message, 503);
  }

  // -- the meter, only for engines that cost money --------------------------
  let spent = false;
  let outOfAllowance = false;

  if (pipeline.metered) {
    const { data: allowed, error } = await asService
      .rpc("consume_ai_document", { ws: doc.workspace_id });
    if (error) return await fail("could not check the monthly allowance");

    if (allowed === false) {
      // Running out is an ordinary state with its own engine, not an error
      // branch. Drop to the free floor: the bill still gets filed from its
      // barcode, with its amount and due date, and the reminder still fires.
      outOfAllowance = true;
      pipeline = resolvePipeline("barcode", REGISTRY_CONFIG, BUILDERS);
    } else {
      spent = true;
    }
  }

  const refund = async () => {
    if (spent) await asService.rpc("refund_ai_document", { ws: doc.workspace_id });
  };

  // -- read -----------------------------------------------------------------
  const input: DocumentInput = { bytes, mimeType: doc.mime_type, scannedBarcode };
  let result: ReadingResult;
  try {
    result = await pipeline.read(input, reader, barcode);
  } catch (err) {
    await refund();

    // Out of allowance AND no barcode to fall back on: there is genuinely
    // nothing free to offer for this document. That is an upgrade prompt, not
    // a failure -- so the document stays pending rather than being marked bad.
    if (outOfAllowance) {
      await asService.from("documents")
        .update({ status: "uploaded", content_hash: contentHash, error_message: null })
        .eq("item_id", itemId);
      return json({
        status: "quota_exceeded",
        upgrade_required: true,
        reason: (err as Error).message,
      }, 402);
    }

    const known = err instanceof UnreadableDocument || err instanceof EngineUnavailable;
    return await fail((err as Error).message, known ? 422 : 500);
  }

  // -- persist --------------------------------------------------------------
  const { data: analysis, error: analysisError } = await asService
    .from("document_analyses").insert({
      item_id: itemId,
      workspace_id: doc.workspace_id,
      stage: "analyse",
      model: result.engine,
      prompt_version: pipeline.id,
      extracted: result,
      input_tokens: result.cost.inputTokens,
      output_tokens: result.cost.outputTokens,
      cost_micros: result.cost.micros,
    }).select("id").single();

  if (analysisError || !analysis) {
    await refund();
    return await fail(`could not save the analysis: ${analysisError?.message}`);
  }

  // -- free floor: filed from its barcode, nothing read ---------------------
  if (result.kind === "tracked") {
    await applyBarcodeOnly("ready");
    await asService.from("activity").insert({
      workspace_id: doc.workspace_id, item_id: itemId, actor_id: user.id, verb: "tracked",
      meta: { engine: result.engine, out_of_allowance: outOfAllowance },
    });
    return json({
      status: "ready",
      kind: "tracked",
      upgrade_required: true,
      due_at: barcode?.dueDate ?? null,
      amount_cents: barcode && barcode.amountCents > 0 ? barcode.amountCents : null,
      cost_micros: 0,
    });
  }

  if (result.kind === "explained") {
    const agreed = reconcile(barcode, result.facts);

    await asService.from("document_explanations").insert({
      item_id: itemId,
      workspace_id: doc.workspace_id,
      analysis_id: analysis.id,
      language: reader.language,
      source: "vision",
      what_it_is: result.explanation.whatItIs,
      what_to_do: result.explanation.whatToDo,
      by_when: result.explanation.byWhen,
      how_much: result.explanation.howMuch,
      details: result.explanation.details,
    });

    await asService.from("documents").update({
      status: "ready",
      error_message: null,
      content_hash: contentHash,
      doc_type: result.facts.docType,
      sender_name: result.facts.senderName,
      issue_date: result.facts.issueDate,
      reference_number: agreed.reference,
      iban: agreed.iban,
      barcode_raw: scannedBarcode,
      barcode_verified: Boolean(barcode) && agreed.disagreements.length === 0,
      source_language: result.facts.sourceLanguage,
      extraction_source: agreed.source === "engine" ? "vision" : agreed.source,
    }).eq("item_id", itemId);

    await asService.from("items").update({
      title: result.facts.title,
      kind: result.facts.docType,
      due_at: asDate(agreed.dueDate),
      all_day: true,
      amount_cents: agreed.amountCents,
      currency: agreed.amountCents != null ? (result.facts.currency ?? "EUR") : null,
    }).eq("id", itemId);

    await asService.from("activity").insert({
      workspace_id: doc.workspace_id, item_id: itemId, actor_id: user.id, verb: "explained",
      meta: {
        engine: result.engine,
        language: reader.language,
        source: agreed.source,
        disagreements: agreed.disagreements,
        uncertain_fields: result.facts.uncertainFields,
        cost_micros: result.cost.micros,
      },
    });

    return json({
      status: "ready",
      kind: "explained",
      source: agreed.source,
      disagreements: agreed.disagreements,
      uncertain_fields: result.facts.uncertainFields,
      cost_micros: result.cost.micros,
      cache_read_tokens: result.cost.cacheReadTokens,
    });
  }

  // -- free tier: a translated document, not advice about it ----------------
  await asService.from("document_explanations").insert({
    item_id: itemId,
    workspace_id: doc.workspace_id,
    analysis_id: analysis.id,
    language: reader.language,
    source: "machine",
    what_it_is: "This is the text of your document in your own language.",
    what_to_do: "Koti has not read this document. Upgrade to have it explained.",
    by_when: null,
    how_much: null,
    details: null,
    full_text: result.translatedText,
  });

  // The barcode is still the only thing we know for certain here.
  await applyBarcodeOnly("ready");
  await asService.from("documents")
    .update({ ocr_text: result.originalText, ocr_confidence: result.confidence })
    .eq("item_id", itemId);

  await asService.from("activity").insert({
    workspace_id: doc.workspace_id, item_id: itemId, actor_id: user.id, verb: "translated",
    meta: { engine: result.engine, language: reader.language, confidence: result.confidence },
  });

  return json({
    status: "ready",
    kind: "translated",
    confidence: result.confidence,
    cost_micros: result.cost.micros,
  });
});
