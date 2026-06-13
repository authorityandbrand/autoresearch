/**
 * BigQuery Nightly Maintenance — authorityandbrand-workspace.legal_case
 * Account: authorityandbrand@gmail.com (profile 5)
 * Deploy:  script.google.com → New project → Enable BigQuery advanced service
 *
 * One-time setup: run installTriggers() once from the script editor.
 * After that, the nightly job runs automatically at 2 AM and self-heals.
 */

const PROJECT_ID = 'authorityandbrand-workspace';
const DATASET   = 'legal_case';

// ============================================================
// ENTRY POINT — called by the nightly time-driven trigger
// ============================================================
function nightly_bq_maintenance() {
  const log = [];
  try {
    log.push(fillAiSummaries());
    log.push(fillEmbeddings('violation_matrix',
      "CONCAT(t.violation_type, '. Statute: ', COALESCE(t.statute_or_rule,''), '. Facts: ', LEFT(COALESCE(t.factual_basis,''),600))",
      'violation_type'));
    log.push(fillEmbeddings('key_findings',
      "CONCAT(t.finding_title, ': ', LEFT(COALESCE(t.finding_description,''),600))",
      'finding_title'));
    log.push(fillEmbeddings('master_timeline',
      "CONCAT(t.event_type, ': ', LEFT(COALESCE(t.summary,''),600))",
      'summary'));
    log.push(warmViewCache());
    log.push(checkDeprecatedTableDrift());

    const summary = log.join('\n');
    Logger.log('✅ nightly_bq_maintenance complete\n' + summary);
    GmailApp.sendEmail(
      'authorityandbrand@gmail.com',
      '✅ BQ Nightly Maintenance — OK',
      summary
    );
  } catch (err) {
    GmailApp.sendEmail(
      'authorityandbrand@gmail.com',
      '❌ BQ Nightly Maintenance — FAILED',
      'Error: ' + err.message + '\n\nStack:\n' + err.stack
    );
    throw err;
  }
}

// ============================================================
// 1. AI SUMMARY GAP FILL
//    Generates ai_summary for any violation_matrix rows where
//    ai_summary IS NULL and no staging row exists yet.
//    Loops in batches of 50 until no rows remain.
// ============================================================
function fillAiSummaries() {
  const BATCH_SQL = `
    INSERT INTO \`${PROJECT_ID}.${DATASET}.ai_violation_summaries\`
      (violation_id, violation_type, violation_class, significance, ai_summary,
       ai_model, generated_at, reviewed, citation_verified, promoted_to_canonical)
    SELECT
      CAST(g.id AS INT64),
      vm.violation_type, vm.violation_class, vm.significance,
      TRIM(JSON_VALUE(g.ml_generate_text_result, '$.candidates[0].content.parts[0].text')),
      JSON_VALUE(g.ml_generate_text_result, '$.model_version'),
      CURRENT_TIMESTAMP(), TRUE, FALSE, FALSE
    FROM ML.GENERATE_TEXT(
      MODEL \`${PROJECT_ID}.${DATASET}.gemini_flash\`,
      (SELECT CAST(vm.id AS STRING) AS id,
        CONCAT(
          'Legal analyst: Summarize this case violation in 2-3 sentences for a federal court brief. ',
          'State the statute violated, the specific prohibited conduct, and the resulting harm. ',
          'Violation: ', vm.violation_type,
          '. Statute: ', COALESCE(vm.statute_or_rule,'not specified'),
          '. Defendant: ', COALESCE(vm.defendant_name,'not specified'),
          '. Facts: ', LEFT(COALESCE(vm.factual_basis, COALESCE(vm.element_analysis,'no details')),600)
        ) AS prompt
       FROM \`${PROJECT_ID}.${DATASET}.violation_matrix\` vm
       WHERE vm.ai_summary IS NULL
         AND NOT EXISTS (
           SELECT 1 FROM \`${PROJECT_ID}.${DATASET}.ai_violation_summaries\` avs
           WHERE avs.violation_id = vm.id)
       ORDER BY CASE vm.significance
         WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END, vm.id
       LIMIT 50),
      STRUCT(0.2 AS temperature, 300 AS max_output_tokens)
    ) g
    JOIN \`${PROJECT_ID}.${DATASET}.violation_matrix\` vm
      ON CAST(vm.id AS STRING) = g.id`;

  const PROMOTE_SQL = `
    UPDATE \`${PROJECT_ID}.${DATASET}.violation_matrix\` vm
    SET ai_summary = avs.ai_summary, updated_at = CURRENT_TIMESTAMP()
    FROM \`${PROJECT_ID}.${DATASET}.ai_violation_summaries\` avs
    WHERE vm.id = avs.violation_id
      AND vm.ai_summary IS NULL
      AND avs.ai_summary IS NOT NULL`;

  const MARK_SQL = `
    UPDATE \`${PROJECT_ID}.${DATASET}.ai_violation_summaries\` avs
    SET promoted_to_canonical = TRUE, promoted_at = CURRENT_TIMESTAMP()
    FROM \`${PROJECT_ID}.${DATASET}.violation_matrix\` vm
    WHERE avs.violation_id = vm.id
      AND vm.ai_summary IS NOT NULL
      AND avs.promoted_to_canonical = FALSE`;

  const CHECK_SQL = `
    SELECT COUNT(*) AS n
    FROM \`${PROJECT_ID}.${DATASET}.violation_matrix\` vm
    WHERE vm.ai_summary IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM \`${PROJECT_ID}.${DATASET}.ai_violation_summaries\` avs
        WHERE avs.violation_id = vm.id)`;

  let batches = 0;
  let remaining = runScalar(CHECK_SQL);

  while (remaining > 0 && batches < 30) {
    runQuery(BATCH_SQL);
    batches++;
    remaining = runScalar(CHECK_SQL);
  }

  if (remaining === 0) {
    runQuery(PROMOTE_SQL);
    runQuery(MARK_SQL);
    const promoted = runScalar(
      `SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${DATASET}.violation_matrix\` WHERE ai_summary IS NOT NULL`);
    const total    = runScalar(
      `SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${DATASET}.violation_matrix\``);
    return `ai_summary: ${promoted}/${total} (${Math.round(promoted*100/total)}%) — ${batches} batches run`;
  } else {
    return `ai_summary: WARNING — ${remaining} rows still unprocessed after ${batches} batches`;
  }
}

// ============================================================
// 2. EMBEDDING GAP FILL
//    Idempotent — NOT EXISTS guard prevents duplicates.
//    Loops in batches of 200 until coverage = 100%.
// ============================================================
function fillEmbeddings(sourceTable, contentExpr, requiredCol) {
  const BATCH_SQL = `
    INSERT INTO \`${PROJECT_ID}.${DATASET}.ai_embeddings\`
      (source_table, source_id, source_text, embedding, embedded_at)
    SELECT
      '${sourceTable}', CAST(t.id AS STRING),
      ${contentExpr.replace('t.', 't.')},
      emb.ml_generate_embedding_result,
      CURRENT_TIMESTAMP()
    FROM ML.GENERATE_EMBEDDING(
      MODEL \`${PROJECT_ID}.${DATASET}.text_embedding_model\`,
      (SELECT CAST(t.id AS STRING) AS id, ${contentExpr} AS content
       FROM \`${PROJECT_ID}.${DATASET}.${sourceTable}\` t
       WHERE NOT EXISTS (
         SELECT 1 FROM \`${PROJECT_ID}.${DATASET}.ai_embeddings\` ae
         WHERE ae.source_id = CAST(t.id AS STRING)
           AND ae.source_table = '${sourceTable}')
       AND t.${requiredCol} IS NOT NULL
       LIMIT 200),
      STRUCT('RETRIEVAL_DOCUMENT' AS task_type)
    ) AS emb
    JOIN \`${PROJECT_ID}.${DATASET}.${sourceTable}\` t
      ON CAST(t.id AS STRING) = emb.id`;

  const CHECK_SQL = `
    SELECT COUNT(*) AS n
    FROM \`${PROJECT_ID}.${DATASET}.${sourceTable}\` t
    WHERE NOT EXISTS (
      SELECT 1 FROM \`${PROJECT_ID}.${DATASET}.ai_embeddings\` ae
      WHERE ae.source_id = CAST(t.id AS STRING)
        AND ae.source_table = '${sourceTable}')
    AND t.${requiredCol} IS NOT NULL`;

  let batches = 0;
  let remaining = runScalar(CHECK_SQL);

  while (remaining > 0 && batches < 20) {
    runQuery(BATCH_SQL);
    batches++;
    remaining = runScalar(CHECK_SQL);
  }

  const embedded = runScalar(
    `SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${DATASET}.ai_embeddings\` WHERE source_table='${sourceTable}'`);
  const total = runScalar(
    `SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${DATASET}.${sourceTable}\``);
  return `embeddings(${sourceTable}): ${embedded}/${total} — ${batches} batches run`;
}

// ============================================================
// 3. VIEW CACHE WARM-UP (BI Engine cold-start prevention)
// ============================================================
function warmViewCache() {
  runScalar(`SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${DATASET}.v_violations_resolved\``);
  runScalar(`SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${DATASET}.v_case_graph\``);
  runScalar(`SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${DATASET}.v_ai_ready_to_promote\``);
  return 'view cache: warmed (3 views)';
}

// ============================================================
// 4. DEPRECATED TABLE DRIFT CHECK (heal-026)
//    Alerts if shadow tables diverge — does NOT auto-TRUNCATE.
// ============================================================
function checkDeprecatedTableDrift() {
  const checks = [
    { shadow: 'case_findings',        canonical: 'key_findings' },
    { shadow: 'timeline_events',      canonical: 'master_timeline' },
    { shadow: 'violation_matrix_opt', canonical: 'violation_matrix' },
  ];
  const drifts = [];

  for (const c of checks) {
    const shadowCount    = runScalar(`SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${DATASET}.${c.shadow}\``);
    const canonicalCount = runScalar(`SELECT COUNT(*) AS n FROM \`${PROJECT_ID}.${DATASET}.${c.canonical}\``);
    const drift = canonicalCount - shadowCount;
    if (drift > 10) {
      drifts.push(`  ${c.shadow} is ${drift} rows behind ${c.canonical} — TRUNCATE required (manual approval)`);
    }
  }

  if (drifts.length > 0) {
    GmailApp.sendEmail(
      'authorityandbrand@gmail.com',
      '⚠️ BQ Deprecated Table Drift Detected',
      'The following deprecated tables need manual TRUNCATE approval:\n\n' + drifts.join('\n')
    );
    return 'deprecated drift: ⚠️ ALERT sent — ' + drifts.length + ' table(s)';
  }
  return 'deprecated drift: OK';
}

// ============================================================
// HELPERS
// ============================================================

function runQuery(sql) {
  const job = BigQuery.Jobs.insert({
    configuration: { query: { query: sql, useLegacySql: false } }
  }, PROJECT_ID);

  let status = job.status.state;
  let jobId  = job.jobReference.jobId;

  while (status !== 'DONE') {
    Utilities.sleep(3000);
    const result = BigQuery.Jobs.get(PROJECT_ID, jobId);
    status = result.status.state;
    if (result.status.errorResult) {
      throw new Error('BQ job failed: ' + JSON.stringify(result.status.errorResult));
    }
  }
  return jobId;
}

function runScalar(sql) {
  const request = { query: sql, useLegacySql: false, timeoutMs: 60000 };
  const result  = BigQuery.Jobs.query(request, PROJECT_ID);
  if (!result.rows || result.rows.length === 0) return 0;
  return parseInt(result.rows[0].f[0].v, 10) || 0;
}

// ============================================================
// ONE-TIME SETUP — run this once from the script editor
// ============================================================
function installTriggers() {
  // Remove any existing nightly trigger to avoid duplicates
  ScriptApp.getProjectTriggers().forEach(t => {
    if (t.getHandlerFunction() === 'nightly_bq_maintenance') {
      ScriptApp.deleteTrigger(t);
    }
  });

  // Fire every night at 2 AM (account timezone)
  ScriptApp.newTrigger('nightly_bq_maintenance')
    .timeBased()
    .everyDays(1)
    .atHour(2)
    .create();

  Logger.log('✅ Trigger installed — nightly_bq_maintenance fires daily at 2 AM');
}

// ============================================================
// MANUAL RUN — call this anytime to run maintenance on demand
// ============================================================
function runNow() {
  nightly_bq_maintenance();
}
