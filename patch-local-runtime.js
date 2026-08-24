#!/usr/bin/env node

const fs = require("fs");
const path = require("path");

const root = process.argv[2];
if (!root) throw new Error("Usage: patch-local-runtime.js <firecrawl-source-dir>");

function patch(relativePath, before, after) {
  const file = path.join(root, relativePath);
  let source = fs.readFileSync(file, "utf8");
  if (after && source.includes(after)) return;
  if (!source.includes(before)) {
    throw new Error(`Patch target not found: ${relativePath}`);
  }
  source = source.replace(before, after);
  fs.writeFileSync(file, source);
}

function remove(relativePath, target) {
  const file = path.join(root, relativePath);
  const source = fs.readFileSync(file, "utf8");
  const normalizedTarget = target.trimEnd();
  if (!source.includes(normalizedTarget)) return;
  fs.writeFileSync(file, source.replace(normalizedTarget, ""));
}

patch(
  "apps/api/src/scraper/scrapeURL/transformers/query.ts",
  'import { getModel } from "../../../lib/generic-ai";',
  'import {\n  getConfiguredModelName,\n  getModelFast,\n} from "../../../lib/generic-ai";',
);
remove(
  "apps/api/src/scraper/scrapeURL/transformers/query.ts",
  `const DIRECT_QUOTE_MODEL = {
  id: "accounts/thomas-bfc570/models/gpt-oss-20b-query-finetune-2026-04-15#accounts/thomas-bfc570/deployments/gpt-oss-20b-query-finetune-2026-04-24",
  provider: "fireworks" as const,
};

  `,
);
patch(
  "apps/api/src/scraper/scrapeURL/transformers/llmExtract.ts",
  "  const modelConfig = modelPrices[model];",
  "  const modelConfig =\n    modelPrices[model] ?? modelPrices[`fireworks_ai/${model}`];",
);
patch(
  "apps/api/src/scraper/scrapeURL/transformers/llmExtract.ts",
  "  const modelCosts = {",
  "  const catalogPricing =\n    modelPrices[model] ?? modelPrices[`fireworks_ai/${model}`];\n  if (catalogPricing) {\n    return (\n      inputTokens * (catalogPricing.input_cost_per_token ?? 0) +\n      outputTokens * (catalogPricing.output_cost_per_token ?? 0)\n    );\n  }\n  const modelCosts = {",
);
patch(
  "apps/api/src/scraper/scrapeURL/transformers/query.ts",
  "  const modelName = DIRECT_QUOTE_MODEL.id;\n  const model = getModel(modelName, DIRECT_QUOTE_MODEL.provider);",
  '  const modelName = getConfiguredModelName("gpt-4o-mini");\n  const model = getModelFast("gpt-4o-mini");',
);
patch(
  "apps/api/src/scraper/scrapeURL/transformers/query.ts",
  `  const modelChain = [
    {
      name: "gemini-2.5-flash-lite",
      model: getModel("gemini-2.5-flash-lite", "google"),
    },
    {
      name: "gpt-4o-mini",
      model: getModel("gpt-4o-mini", "openai"),
    },
    {
      name: "gemini-2.5-flash-lite",
      model: getModel("gemini-2.5-flash-lite", "vertex"),
    },
  ];`,
  '  const modelName = getConfiguredModelName("gpt-4o-mini");\n  const modelChain = [{ name: modelName, model: getModelFast("gpt-4o-mini") }];',
);
patch(
  "apps/api/src/lib/extract/fire-0/llmExtract-f0.ts",
  "  const modelConfig = modelPrices[model];",
  "  const modelConfig =\n    modelPrices[model] ?? modelPrices[`fireworks_ai/${model}`];",
);
patch(
  "apps/api/src/lib/extract/fire-0/llmExtract-f0.ts",
  "          totalTokens: numTokens + (result.usage?.outputTokens ?? 0),\n        },",
  "          totalTokens: numTokens + (result.usage?.outputTokens ?? 0),\n          model: modelId,\n        },",
);
patch(
  "apps/api/src/lib/extract/fire-0/llmExtract-f0.ts",
  "        totalTokens: promptTokens + completionTokens,\n      },",
  "        totalTokens: promptTokens + completionTokens,\n        model: modelId,\n      },",
);
patch(
  "apps/api/src/lib/extract/fire-0/usage/llm-cost-f0.ts",
  "    const pricing = modelPrices[model] as ModelPricing;",
  "    const pricing = (modelPrices[model] ??\n      modelPrices[`fireworks_ai/${model}`]) as ModelPricing;",
);
patch(
  "apps/api/src/lib/extract/fire-0/extraction-service-f0.ts",
  "    const timeout = 60000;",
  "    const timeout = Math.min(Math.max(request.timeout ?? 300000, 1000), 600000);",
);
patch(
  "apps/api/src/lib/extract/fire-0/extraction-service-f0.ts",
  "    const timeoutCompletion = 45000; // 45 second timeout",
  "    const timeoutCompletion = timeout;",
);
patch(
  "apps/api/src/lib/extract/fire-0/extraction-service-f0.ts",
  "    // Scrape documents\n    const timeout = 60000;",
  "    // Scrape documents\n    const timeout = Math.min(Math.max(request.timeout ?? 300000, 1000), 600000);",
);
patch(
  "apps/api/src/db/rpc.ts",
  "export function creditsBilledByCrawlId(",
  `export async function changeTrackingSaveDocument(params: {
  job_id: string;
  document: unknown;
}): Promise<void> {
  await db.execute(
    sql\`insert into change_tracking_documents (job_id, document)
        values (\${params.job_id}, \${JSON.stringify(params.document)}::jsonb)
        on conflict (job_id) do update set document = excluded.document, created_at = now()\`,
  );
}

export function changeTrackingGetDocument(
  jobId: string,
): Promise<{ document: unknown }[]> {
  return execRows(
    db,
    sql\`select document from change_tracking_documents where job_id = \${jobId}\`,
  );
}

export function creditsBilledByCrawlId(`,
);
patch(
  "apps/api/src/services/logging/log_job.ts",
  'import { changeTrackingInsertScrape } from "../../db/rpc";',
  'import {\n  changeTrackingInsertScrape,\n  changeTrackingSaveDocument,\n} from "../../db/rpc";',
);
patch(
  "apps/api/src/services/logging/log_job.ts",
  "    config.USE_DB_AUTHENTICATION &&\n    !scrape.team_id.startsWith(\"preview_\")",
  "    (config.USE_DB_AUTHENTICATION || !!config.DATABASE_URL) &&\n    !scrape.team_id.startsWith(\"preview_\")",
);
patch(
  "apps/api/src/services/logging/log_job.ts",
  "        await changeTrackingInsertScrape({\n          team_id: scrape.team_id,",
  "        await changeTrackingSaveDocument({\n          job_id: scrape.id,\n          document: scrape.doc,\n        });\n        await changeTrackingInsertScrape({\n          team_id: scrape.team_id,",
);
patch(
  "apps/api/src/scraper/scrapeURL/transformers/diff.ts",
  'import { diffGetLastScrape } from "../../../db/rpc";',
  'import {\n  changeTrackingGetDocument,\n  diffGetLastScrape,\n} from "../../../db/rpc";',
);
patch(
  "apps/api/src/scraper/scrapeURL/transformers/diff.ts",
  "    const rawJob = data?.o_job_id ? await getJobFromGCS(data.o_job_id) : null;\n    const job: Document | null = rawJob?.[0] ?? null;",
  "    const localJob = data?.o_job_id\n      ? (await changeTrackingGetDocument(data.o_job_id))[0]?.document\n      : null;\n    const rawJob =\n      data?.o_job_id && !localJob ? await getJobFromGCS(data.o_job_id) : null;\n    const job: Document | null = (localJob as Document | undefined) ?? rawJob?.[0] ?? null;",
);
patch(
  "apps/api/src/services/webhook/delivery.ts",
  `  try {
    await redisEvictConnection.rpush(
      WEBHOOK_INSERT_QUEUE_KEY,`,
  `  try {
    await db.insert(schema.webhook_logs).values({
      success: data.success,
      error: data.error ?? null,
      team_id: data.teamId,
      crawl_id: data.crawlId,
      scrape_id: data.scrapeId ?? null,
      url: data.url,
      status_code: data.statusCode ?? null,
      event: data.event,
    });
    return;
  } catch (error) {
    logger.warn("Direct webhook log insert failed; queueing for retry", {
      error,
      teamId: data.teamId,
    });
  }

  try {
    await redisEvictConnection.rpush(
      WEBHOOK_INSERT_QUEUE_KEY,`,
);

patch(
  "apps/playwright-service-ts/api.ts",
  "    const pageError =\n      result.status !== 200 ? getError(result.status) : undefined;",
  "    const pageError =\n      result.status !== 200 ? getError(result.status) : undefined;\n    const screenshotRequest = req.body?.screenshot;\n    let screenshot: string | undefined;\n    if (screenshotRequest && !pageError) {\n      const quality = Number.isInteger(screenshotRequest.quality)\n        ? Math.min(Math.max(screenshotRequest.quality, 0), 100)\n        : undefined;\n      const type = quality === undefined ? 'png' : 'jpeg';\n      const bytes = await page.screenshot({\n        fullPage: Boolean(screenshotRequest.fullPage),\n        type,\n        ...(quality === undefined ? {} : { quality }),\n      });\n      screenshot = `data:image/${type};base64,${bytes.toString('base64')}`;\n    }",
);
patch(
  "apps/playwright-service-ts/api.ts",
  "      contentType: result.contentType,\n      ...(pageError && { pageError }),",
  "      contentType: result.contentType,\n      ...(screenshot && { screenshot }),\n      ...(pageError && { pageError }),",
);
patch(
  "apps/api/src/scraper/scrapeURL/engines/playwright/index.ts",
  'import { getInnerJson } from "@mendable/firecrawl-rs";',
  'import { getInnerJson } from "@mendable/firecrawl-rs";\nimport { hasFormatOfType } from "../../../../lib/format-utils";',
);
patch(
  "apps/api/src/scraper/scrapeURL/engines/playwright/index.ts",
  '): Promise<EngineScrapeResult> {\n  const response = await robustFetch({',
  '): Promise<EngineScrapeResult> {\n  const screenshotFormat = hasFormatOfType(meta.options.formats, "screenshot");\n  const response = await robustFetch({',
);
patch(
  "apps/api/src/scraper/scrapeURL/engines/playwright/index.ts",
  "      skip_tls_verification: meta.options.skipTlsVerification,\n    },",
  "      skip_tls_verification: meta.options.skipTlsVerification,\n      ...(screenshotFormat\n        ? {\n            screenshot: {\n              fullPage: screenshotFormat.fullPage,\n              quality: screenshotFormat.quality,\n            },\n          }\n        : {}),\n    },",
);
patch(
  "apps/api/src/scraper/scrapeURL/engines/playwright/index.ts",
  "      contentType: z.string().optional(),\n    }),",
  "      contentType: z.string().optional(),\n      screenshot: z.string().optional(),\n    }),",
);
patch(
  "apps/api/src/scraper/scrapeURL/engines/playwright/index.ts",
  "    contentType: response.contentType,\n\n    proxyUsed: \"basic\",",
  "    contentType: response.contentType,\n    screenshot: response.screenshot,\n\n    proxyUsed: \"basic\",",
);
patch(
  "apps/api/src/scraper/scrapeURL/engines/index.ts",
  '  playwright: {\n    features: {\n      actions: false,\n      waitFor: true,\n      screenshot: false,\n      "screenshot@fullScreen": false,\n      pdf: false,',
  '  playwright: {\n    features: {\n      actions: false,\n      waitFor: true,\n      screenshot: true,\n      "screenshot@fullScreen": true,\n      pdf: false,',
);
patch(
  "apps/api/src/scraper/scrapeURL/engines/index.ts",
  '  playwright: {\n    features: {\n      actions: false,\n      waitFor: true,\n      screenshot: true,\n      "screenshot@fullScreen": true,\n      pdf: false,\n      document: false,\n      audio: false,',
  '  playwright: {\n    features: {\n      actions: false,\n      waitFor: true,\n      screenshot: true,\n      "screenshot@fullScreen": true,\n      pdf: false,\n      document: false,\n      // AVGRAB handles media download after the browser has loaded the page.\n      // This keeps public audio sources usable without Fire Engine.\n      audio: true,',
);
remove(
  "apps/api/src/lib/scrape-interact/browser-agent.ts",
  `      prepareStep: async ({ stepNumber, messages }) => {
        if (actionLog.length === 0) return {};
        return {
          messages: [
            ...messages,
            {
              role: "user" as const,
              content: [
                {
                  type: "text" as const,
                  text: \`ACTION LOG (your commands so far):\\n\${actionLog.join("\\n")}\\n\\nReview this log before your next action. Common mistakes to check for:\\n- Typed text but forgot to press Enter\\n- Clicked a link but didn't wait or re-snapshot\\n- Used stale @refs from a previous snapshot\\n- Scrolled but didn't snapshot to see new content\`,
                },
              ],
            },
          ],
        };
      },
  `,
);
patch(
  "apps/api/src/lib/scrape-interact/browser-agent.ts",
  "async function takeSnapshot(browserId: string): Promise<string> {\n  try {\n    const result = await execInBrowser(\n      browserId,\n      \"agent-browser snapshot -i\",\n      SNAPSHOT_TIMEOUT,\n      \"agent_snapshot\",\n    );\n    return (result.stdout || result.result || \"\").slice(0, SNAPSHOT_MAX_CHARS);\n  } catch {\n    return \"\";\n  }\n}",
  "async function takeSnapshot(browserId: string): Promise<string> {\n  try {\n    const result = await execInBrowser(\n      browserId,\n      \"agent-browser snapshot -i\",\n      SNAPSHOT_TIMEOUT,\n      \"agent_snapshot\",\n    );\n    return (result.stdout || result.result || \"\").slice(0, SNAPSHOT_MAX_CHARS);\n  } catch {\n    return \"\";\n  }\n}\n\nasync function readPageText(browserId: string): Promise<string> {\n  try {\n    const result = await execInBrowser(\n      browserId,\n      'return await page.locator(\"body\").innerText();',\n      SNAPSHOT_TIMEOUT,\n      \"agent_page_text\",\n    );\n    return (result.stdout || result.result || \"\").slice(0, SNAPSHOT_MAX_CHARS);\n  } catch {\n    return \"\";\n  }\n}",
);
patch(
  "apps/api/src/lib/scrape-interact/browser-agent.ts",
  "    logger.error(\"Agent failed\", { error: err });\n    debugLog.add(`\\n=== END: error — ${msg} ===\\n`);\n    await debugLog.flush();\n\n    return {",
  "    logger.error(\"Agent failed\", { error: err });\n    debugLog.add(`\\n=== END: error — ${msg} ===\\n`);\n    await debugLog.flush();\n\n    // Some OpenAI-compatible providers can answer requests but do not preserve\n    // tool-call IDs across AI SDK steps. Fall back to a tool-free answer over\n    // the rendered page rather than failing read-only interaction prompts.\n    const pageText = await readPageText(browserId);\n    if (pageText) {\n      try {\n        const fallback = await generateText({\n          model: getModelFast(\"gemini-3.5-flash\"),\n          system:\n            \"Answer the user's question using only the rendered page text. Be concise. Do not claim to have clicked, typed, or changed the page.\",\n          prompt: `Task: ${prompt}\\n\\nRendered page text:\\n${pageText}`,\n          temperature: 0,\n        });\n        if (fallback.text.trim()) {\n          return {\n            output: fallback.text.trim(),\n            stdout: allOutputs.join(\"\\n\"),\n            result: lastSnapshotResult,\n            stderr: \"\",\n            exitCode: 0,\n            killed: false,\n          };\n        }\n      } catch (fallbackError) {\n        logger.warn(\"Tool-free interaction fallback failed\", { fallbackError });\n      }\n    }\n\n    return {",
);
patch(
  "apps/api/src/lib/scrape-interact/browser-agent.ts",
  "  origin: string,\n): Promise<BrowserServiceExecResponse> {\n  return browserServiceRequest<BrowserServiceExecResponse>(\n    \"POST\",\n    `/browsers/${browserId}/exec`,\n    { code, language: \"bash\", timeout, origin },",
  "  origin: string,\n  language: \"bash\" | \"node\" = \"bash\",\n): Promise<BrowserServiceExecResponse> {\n  return browserServiceRequest<BrowserServiceExecResponse>(\n    \"POST\",\n    `/browsers/${browserId}/exec`,\n    { code, language, timeout, origin },",
);
patch(
  "apps/api/src/lib/scrape-interact/browser-agent.ts",
  "      'return await page.locator(\"body\").innerText();',\n      SNAPSHOT_TIMEOUT,\n      \"agent_page_text\",\n    );",
  "      'return await page.locator(\"body\").innerText();',\n      SNAPSHOT_TIMEOUT,\n      \"agent_page_text\",\n      \"node\",\n    );",
);

console.log("Patched local Firecrawl runtime features.");
