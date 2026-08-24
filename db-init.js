const s = require("/app/dist/src/db/schema/public.js");
const { getTableName, getTableColumns } = require("/app/node_modules/drizzle-orm");
const { Client } = require("/app/node_modules/pg");

const WANT = [
  "requests","scrapes","parses","crawls","batch_scrapes","searches",
  "search_feedback","research_paper_searches","research_paper_inspects",
  "research_paper_reads","research_related_papers","research_github_searches",
  "code_searches","extracts","maps","llmstxts","deep_researches",
  "monitors","monitor_pages","monitor_checks","monitor_check_pages",
  "monitor_email_recipients","browser_sessions","browser_session_activities",
  "agents","agent_sponsors","idempotency_keys",
];

// uuid -> text so keyless team ids like "bypass" are storable locally.
const TYPE = {
  PgUUID: "text", PgJsonb: "jsonb", PgTimestampString: "timestamp",
  PgNumericNumber: "numeric", PgInteger: "integer", PgBoolean: "boolean",
  PgText: "text", PgBigInt53: "bigint", PgBytea: "bytea", PgVarchar: "text",
};

function sqlLit(t, v) {
  if (v === undefined || v === null) return null;
  if (t === "jsonb") return `'${JSON.stringify(v)}'::jsonb`;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return `'${String(v).replace(/'/g, "''")}'`;
}

function colDef(c) {
  const t = TYPE[c.columnType] || "text";
  const isTs = c.columnType === "PgTimestampString" || c.columnType === "PgTimestamp" || c.columnType === "PgDate";
  const parts = [`"${c.name}"`, t];
  if (c.notNull) parts.push("NOT NULL");
  if (c.hasDefault) {
    const d = c.default;
    const isSqlObj = d !== null && typeof d === "object" && !Array.isArray(d) && d.queryChunks !== undefined;
    if (isSqlObj) {
      // drizzle SQL default (now(), gen_random_uuid(), ...)
      if (isTs) parts.push("DEFAULT now()");
      // uuid-as-text: skip (app supplies value)
    } else {
      const lit = sqlLit(t, d);
      if (lit !== null) parts.push(`DEFAULT ${lit}`);
      else if (isTs) parts.push("DEFAULT now()");
    }
  }
  return parts.join(" ");
}

(async () => {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();

  const tables = {};
  for (const t of Object.values(s)) {
    try {
      const name = getTableName(t);
      if (WANT.includes(name)) tables[name] = t;
    } catch (e) {}
  }

  for (const name of WANT) {
    const t = tables[name];
    if (!t) { console.log(`SKIP (not in schema): ${name}`); continue; }
    const cols = Object.values(getTableColumns(t)).map(colDef);
    const ddl = `CREATE TABLE IF NOT EXISTS "${getTableName(t)}" (${cols.join(", ")})`;
    try {
      await client.query(ddl);
      console.log(`OK: ${name}`);
    } catch (e) {
      console.log(`FAIL: ${name}: ${e.message}`);
    }
  }

  // Monitor scheduler claim RPC (mirrors upstream contract; worker id unused).
  const fn = `
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
    $$ LANGUAGE sql;`;
  try {
    await client.query(fn);
    console.log("OK: monitoring_claim_due_monitors()");
  } catch (e) {
    console.log(`FAIL: claim fn: ${e.message}`);
  }

  await client.end();
})();
