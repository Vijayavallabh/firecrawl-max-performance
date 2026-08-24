const schema = require("/app/dist/src/db/schema/public.js");
const { getTableName, getTableColumns } = require("/app/node_modules/drizzle-orm");
const { Client } = require("/app/node_modules/pg");

const TABLES = [
  "keyless_credit_usage",
  "requests",
  "scrapes",
  "parses",
  "crawls",
  "batch_scrapes",
  "searches",
  "search_feedback",
  "research_paper_searches",
  "research_paper_inspects",
  "research_paper_reads",
  "research_related_papers",
  "research_github_searches",
  "code_searches",
  "deterministic_json_scripts",
  "deterministic_json_llm_cache",
  "extracts",
  "maps",
  "llm_texts",
  "llmstxts",
  "deep_researches",
  "monitors",
  "monitor_pages",
  "monitor_checks",
  "monitor_check_pages",
  "monitor_email_recipients",
  "browser_sessions",
  "browser_session_activities",
  "agents",
  "agent_sponsors",
  "idempotency_keys",
];

const TYPE = {
  PgUUID: "text",
  PgJsonb: "jsonb",
  PgTimestampString: "timestamptz",
  PgTimestamp: "timestamptz",
  PgDate: "date",
  PgNumericNumber: "numeric",
  PgInteger: "integer",
  PgSmallInt: "smallint",
  PgBoolean: "boolean",
  PgText: "text",
  PgBigInt53: "bigint",
  PgBytea: "bytea",
  PgVarchar: "text",
};

const q = value => `"${String(value).replace(/"/g, '""')}"`;

function baseType(column) {
  return TYPE[column.columnType] || "text";
}

function columnType(column) {
  const base = baseType(column);
  return `${base}${"[]".repeat(column.dimensions || 0)}`;
}

function literal(value) {
  if (typeof value === "boolean" || typeof value === "number") {
    return String(value);
  }
  return `'${String(value).replace(/'/g, "''")}'`;
}

function defaultSql(column, type) {
  if (column.generatedIdentity) return null;

  const chunks = column.default?.queryChunks;
  if (Array.isArray(chunks)) {
    const raw = chunks
      .map(chunk => (Array.isArray(chunk.value) ? chunk.value.join("") : ""))
      .join("")
      .trim();
    if (raw) {
      if (raw.includes("gen_random_uuid()") && type === "text") {
        return "gen_random_uuid()::text";
      }
      return raw;
    }
  }

  if (column.default === undefined || column.default === null) return null;
  if (type === "jsonb") {
    return `${literal(JSON.stringify(column.default))}::jsonb`;
  }
  if (type.endsWith("[]") && Array.isArray(column.default)) {
    const elementType = type.slice(0, -2);
    return `ARRAY[${column.default.map(literal).join(", ")}]::${type}`;
  }
  return literal(column.default);
}

function columnDefinition(column, includeNotNull = true) {
  const type = columnType(column);
  const parts = [q(column.name), type];
  const defaultValue = defaultSql(column, type);
  if (includeNotNull && column.notNull) parts.push("NOT NULL");
  if (defaultValue !== null) parts.push(`DEFAULT ${defaultValue}`);
  return parts.join(" ");
}

function sourceTables() {
  const result = new Map();
  for (const table of Object.values(schema)) {
    try {
      result.set(getTableName(table), table);
    } catch {
      // Non-table exports are present in the schema module as well.
    }
  }
  return result;
}

async function createAgentJobsTable(client) {
  await client.query(`
    CREATE TABLE IF NOT EXISTS agent_jobs (
      id text PRIMARY KEY,
      team_id text NOT NULL,
      status text NOT NULL,
      prompt text NOT NULL DEFAULT '',
      urls jsonb,
      request_schema jsonb,
      data jsonb,
      error text,
      model text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now()
    )
  `);
}

async function addMissingColumns(client, tableName, table) {
  const rows = await client.query(
    `SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1`,
    [tableName],
  );
  const existing = new Set(rows.rows.map(row => row.column_name));
  for (const column of Object.values(getTableColumns(table))) {
    if (existing.has(column.name)) continue;
    await client.query(
      `ALTER TABLE ${q(tableName)} ADD COLUMN ${columnDefinition(column)}`,
    );
    console.log(`ADD: ${tableName}.${column.name}`);
  }
}

async function normalizeKnownTypes(client) {
  const arrayColumns = [
    ["extracts", "urls"],
    ["search_feedback", "issue_types"],
    ["search_feedback", "tags"],
  ];
  for (const [table, column] of arrayColumns) {
    const result = await client.query(
      `SELECT data_type, udt_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
      [table, column],
    );
    const current = result.rows[0];
    if (!current || current.udt_name !== "text") continue;
    await client.query(`ALTER TABLE ${q(table)} ALTER COLUMN ${q(column)} DROP DEFAULT`);
    await client.query(`
      ALTER TABLE ${q(table)} ALTER COLUMN ${q(column)} TYPE text[]
      USING CASE
        WHEN ${q(column)} IS NULL OR btrim(${q(column)}) = '' THEN ARRAY[]::text[]
        WHEN left(${q(column)}, 1) = '{' THEN ${q(column)}::text[]
        ELSE ARRAY[${q(column)}]::text[]
      END
    `);
    await client.query(
      `ALTER TABLE ${q(table)} ALTER COLUMN ${q(column)} SET DEFAULT ARRAY[]::text[]`,
    );
    console.log(`ALTER: ${table}.${column} -> text[]`);
  }

  const timestamps = await client.query(
    `SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = 'public' AND data_type = 'timestamp without time zone' AND column_name IN ('created_at', 'updated_at', 'deleted_at', 'next_run_at', 'last_run_at', 'locked_at', 'locked_until', 'scheduled_for', 'started_at', 'finished_at', 'removed_at', 'confirmation_sent_at', 'confirmed_at', 'unsubscribed_at', 'last_notified_at')`,
  );
  for (const row of timestamps.rows) {
    await client.query(`
      ALTER TABLE ${q(row.table_name)} ALTER COLUMN ${q(row.column_name)}
      TYPE timestamptz USING ${q(row.column_name)} AT TIME ZONE 'UTC'
    `);
    console.log(`ALTER: ${row.table_name}.${row.column_name} -> timestamptz`);
  }
}

async function applyDefaults(client, tableMap) {
  for (const [tableName, table] of tableMap) {
    if (!TABLES.includes(tableName)) continue;
    for (const column of Object.values(getTableColumns(table))) {
      if (column.generatedIdentity) {
        const sequence = `${tableName}_${column.name}_seq`;
        await client.query(`CREATE SEQUENCE IF NOT EXISTS ${q(sequence)}`);
        await client.query(
          `ALTER SEQUENCE ${q(sequence)} OWNED BY ${q(tableName)}.${q(column.name)}`,
        );
        await client.query(`
          SELECT setval(
            ${literal(sequence)},
            GREATEST(COALESCE((SELECT max(${q(column.name)}) FROM ${q(tableName)}), 0) + 1, 1),
            false
          )
        `);
        await client.query(
          `ALTER TABLE ${q(tableName)} ALTER COLUMN ${q(column.name)} SET DEFAULT nextval(${literal(sequence)}::regclass)`,
        );
      } else if (column.columnType === "PgUUID" && column.hasDefault) {
        const typeResult = await client.query(
          `SELECT data_type FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2`,
          [tableName, column.name],
        );
        const sqlType = typeResult.rows[0]?.data_type === "uuid" ? "uuid" : "text";
        await client.query(
          `ALTER TABLE ${q(tableName)} ALTER COLUMN ${q(column.name)} SET DEFAULT ${sqlType === "text" ? "gen_random_uuid()::text" : "gen_random_uuid()"}`,
        );
      }
    }
  }
}

async function applyIndexes(client) {
  const statements = [
    `CREATE UNIQUE INDEX IF NOT EXISTS requests_id_unique ON requests (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS scrapes_id_unique ON scrapes (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS parses_id_unique ON parses (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS crawls_id_unique ON crawls (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS searches_id_unique ON searches (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS extracts_id_unique ON extracts (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS maps_id_unique ON maps (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS monitors_id_unique ON monitors (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS monitor_checks_id_unique ON monitor_checks (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS monitor_check_pages_id_unique ON monitor_check_pages (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS monitor_email_recipients_id_unique ON monitor_email_recipients (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS browser_sessions_id_unique ON browser_sessions (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS agents_id_unique ON agents (id)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS monitor_pages_identity_idx ON monitor_pages (monitor_id, target_id, url_hash)`,
    `CREATE INDEX IF NOT EXISTS monitor_pages_monitor_idx ON monitor_pages (monitor_id, target_id, is_removed)`,
    `CREATE INDEX IF NOT EXISTS monitor_checks_monitor_idx ON monitor_checks (monitor_id, created_at DESC)`,
    `CREATE INDEX IF NOT EXISTS monitor_check_pages_check_idx ON monitor_check_pages (check_id, created_at)`,
    `CREATE INDEX IF NOT EXISTS monitor_email_recipients_monitor_idx ON monitor_email_recipients (monitor_id, team_id)`,
    `CREATE INDEX IF NOT EXISTS browser_sessions_team_status_idx ON browser_sessions (team_id, status, created_at DESC)`,
    `CREATE INDEX IF NOT EXISTS browser_sessions_scrape_idx ON browser_sessions (scrape_id)`,
    `CREATE INDEX IF NOT EXISTS browser_sessions_browser_idx ON browser_sessions (browser_id)`,
    `CREATE INDEX IF NOT EXISTS browser_session_activities_session_idx ON browser_session_activities (session_id, created_at DESC)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS search_feedback_job_unique ON search_feedback (team_id, endpoint, job_id) WHERE job_id IS NOT NULL`,
    `CREATE INDEX IF NOT EXISTS search_feedback_legacy_idx ON search_feedback (team_id, search_id) WHERE search_id IS NOT NULL`,
    `CREATE INDEX IF NOT EXISTS requests_team_created_idx ON requests (team_id, created_at DESC)`,
    `CREATE INDEX IF NOT EXISTS scrapes_request_idx ON scrapes (request_id, created_at)`,
    `CREATE INDEX IF NOT EXISTS extracts_request_idx ON extracts (request_id, created_at)`,
    `CREATE INDEX IF NOT EXISTS llm_texts_origin_idx ON llm_texts (origin_url, updated_at DESC)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS deterministic_json_scripts_cache_key_unique ON deterministic_json_scripts (cache_key)`,
    `CREATE UNIQUE INDEX IF NOT EXISTS deterministic_json_llm_cache_cache_key_unique ON deterministic_json_llm_cache (cache_key)`,
    `CREATE INDEX IF NOT EXISTS agent_jobs_team_updated_idx ON agent_jobs (team_id, updated_at DESC)`,
  ];
  for (const statement of statements) {
    await client.query(statement);
  }
}

async function applyClaimFunction(client) {
  await client.query(`
    CREATE OR REPLACE FUNCTION monitoring_claim_due_monitors(
      p_worker_id text, p_limit int DEFAULT 1, p_lease_seconds int DEFAULT 60
    ) RETURNS SETOF monitors AS $$
      WITH claimed AS (
        SELECT id FROM monitors
        WHERE status = 'active' AND deleted_at IS NULL
          AND (next_run_at IS NULL OR next_run_at <= now())
          AND (locked_until IS NULL OR locked_until < now())
        ORDER BY next_run_at ASC NULLS FIRST
        LIMIT GREATEST(p_limit, 1)
        FOR UPDATE SKIP LOCKED
      )
      UPDATE monitors m
      SET locked_at = now(),
          locked_until = now() + make_interval(secs => GREATEST(p_lease_seconds, 1)),
          updated_at = now()
      FROM claimed c
      WHERE m.id = c.id
      RETURNING m.*;
    $$ LANGUAGE sql;
  `);
}

(async () => {
  if (!process.env.DATABASE_URL) throw new Error("DATABASE_URL is required");
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  try {
    await client.connect();
    await client.query("BEGIN");
    await client.query("CREATE EXTENSION IF NOT EXISTS pgcrypto");

    const tableMap = sourceTables();
    for (const tableName of TABLES) {
      const table = tableMap.get(tableName);
      if (!table) throw new Error(`Table ${tableName} is missing from the Firecrawl schema`);
      const columns = Object.values(getTableColumns(table)).map(columnDefinition);
      await client.query(
        `CREATE TABLE IF NOT EXISTS ${q(tableName)} (${columns.join(", ")})`,
      );
      await addMissingColumns(client, tableName, table);
      console.log(`OK: ${tableName}`);
    }

    await createAgentJobsTable(client);
    await normalizeKnownTypes(client);
    await applyDefaults(client, tableMap);
    await applyIndexes(client);
    await applyClaimFunction(client);
    await client.query(`
      CREATE TABLE IF NOT EXISTS firecrawl_local_schema_migrations (
        version integer PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )
    `);
    await client.query(`
      INSERT INTO firecrawl_local_schema_migrations(version)
      VALUES (2)
      ON CONFLICT (version) DO UPDATE SET applied_at = now()
    `);
    await client.query("COMMIT");
    console.log("Local Firecrawl schema ready (version 2).");
  } catch (error) {
    await client.query("ROLLBACK").catch(() => {});
    console.error(`Local schema initialization failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  } finally {
    await client.end().catch(() => {});
  }
})();
