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

function ensureReadPageText() {
  const relativePath = "apps/api/src/lib/scrape-interact/browser-agent.ts";
  const file = path.join(root, relativePath);
  let source = fs.readFileSync(file, "utf8");
  const helper = `async function readPageText(browserId: string): Promise<string> {
  try {
    const result = await execInBrowser(
      browserId,
      'return await page.locator("body").innerText();',
      SNAPSHOT_TIMEOUT,
      "agent_page_text",
      "node",
    );
    return (result.stdout || result.result || "").slice(0, SNAPSHOT_MAX_CHARS);
  } catch {
    return "";
  }
}`;
  const existingHelper = /async function readPageText\(browserId: string\): Promise<string> \{\n  try \{\n    const result = await execInBrowser\(\n      browserId,\n      'return await page\.locator\("body"\)\.innerText\(\);',\n      SNAPSHOT_TIMEOUT,\n      "agent_page_text",\n(?:      "node",\n)?    \);\n    return \(result\.stdout \|\| result\.result \|\| ""\)\.slice\(0, SNAPSHOT_MAX_CHARS\);\n  \} catch \{\n    return "";\n  \}\n\}/g;
  source = source.replace(existingHelper, "");
  const snapshot = `async function takeSnapshot(browserId: string): Promise<string> {
  try {
    const result = await execInBrowser(
      browserId,
      "agent-browser snapshot -i",
      SNAPSHOT_TIMEOUT,
      "agent_snapshot",
    );
    return (result.stdout || result.result || "").slice(0, SNAPSHOT_MAX_CHARS);
  } catch {
    return "";
  }
}`;
  if (!source.includes(snapshot)) {
    throw new Error(`Patch target not found: ${relativePath}`);
  }
  fs.writeFileSync(file, source.replace(snapshot, `${snapshot}\n\n${helper}`));
}

// AI SDK 3.0.71 serializes client-executed tool calls as item references.
// Fireworks requires the inline function-call format introduced in 3.0.73.
patch(
  "apps/api/package.json",
  '"@ai-sdk/openai": "3.0.71"',
  '"@ai-sdk/openai": "3.0.73"',
);
patch(
  "apps/api/pnpm-lock.yaml",
  "      '@ai-sdk/openai':\n        specifier: 3.0.71\n        version: 3.0.71(zod@4.1.12)",
  "      '@ai-sdk/openai':\n        specifier: 3.0.73\n        version: 3.0.73(zod@4.1.12)",
);
patch(
  "apps/api/pnpm-lock.yaml",
  "  '@ai-sdk/openai@3.0.71':\n    resolution: {integrity: sha512-j6eBAa5oHFZ4U5CxpIV3T4zXNM/BviodNCZCL1qHkA4aqkwK9iQ18TWYz2DZcXpw4BO5pikKzqpXORxb1EnZGA==}",
  "  '@ai-sdk/openai@3.0.73':\n    resolution: {integrity: sha512-+3x9oxHv9Xp33Iv2L8D+e5hqmZi64jofBKig/9611JKyfV59NdkaDDajtwc0CxOEfARgCVq1BW7dP+526gKOKw==}",
);
patch(
  "apps/api/pnpm-lock.yaml",
  "  '@ai-sdk/provider-utils@4.0.40':",
  "  '@ai-sdk/provider-utils@4.0.30':\n    resolution: {integrity: sha512-VO7I+vPffqI5sMnPoUq5DCSqKIgQIk/naJWRdQVpz2ma2zoprC/lqiJiUEl2s6DfvTD76TbhD3q39ROjlA6rGw==}\n    engines: {node: '>=18'}\n    peerDependencies:\n      zod: ^3.25.76 || ^4.1.8\n\n  '@ai-sdk/provider-utils@4.0.40':",
);
patch(
  "apps/api/pnpm-lock.yaml",
  "  expect-type@1.3.0:",
  "  eventsource-parser@3.1.1:\n    resolution: {integrity: sha512-EKN1vKAMcZ8MlYMpaNuxN6R9yakzH6uajHcHVTqWJzvu5pWw9DyhbP35HH8MVBQ+dZjAfDxk+A8NiR9KWaXiyQ==}\n    engines: {node: '>=18.0.0'}\n\n  expect-type@1.3.0:",
);
patch(
  "apps/api/pnpm-lock.yaml",
  "  '@ai-sdk/openai@3.0.71(zod@4.1.12)':\n    dependencies:\n      '@ai-sdk/provider': 3.0.10\n      '@ai-sdk/provider-utils': 4.0.29(zod@4.1.12)\n      zod: 4.1.12",
  "  '@ai-sdk/openai@3.0.73(zod@4.1.12)':\n    dependencies:\n      '@ai-sdk/provider': 3.0.10\n      '@ai-sdk/provider-utils': 4.0.30(zod@4.1.12)\n      zod: 4.1.12",
);
patch(
  "apps/api/pnpm-lock.yaml",
  "  '@ai-sdk/provider-utils@4.0.40(zod@4.1.12)':",
  "  '@ai-sdk/provider-utils@4.0.30(zod@4.1.12)':\n    dependencies:\n      '@ai-sdk/provider': 3.0.10\n      '@standard-schema/spec': 1.1.0\n      eventsource-parser: 3.1.1\n      zod: 4.1.12\n\n  '@ai-sdk/provider-utils@4.0.40(zod@4.1.12)':",
);
patch(
  "apps/api/pnpm-lock.yaml",
  "  expect-type@1.3.0: {}",
  "  eventsource-parser@3.1.1: {}\n\n  expect-type@1.3.0: {}",
);

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
ensureReadPageText();
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

console.log("Patched local Firecrawl runtime features.");
