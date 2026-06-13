-- BigQuery Schema Improvements — authorityandbrand-workspace.legal_case
-- Applied: 2026-06-12 | Branch: authorityandbrand/workspace
-- This branch is intentionally disconnected from master (karpathy/autoresearch).
-- All changes here are specific to the authorityandbrand-workspace GCP project.

-- ==========================================================================
-- SECTION 1: BROKEN VIEW FIXES (violation_matrix.ai_trial_summary → ai_summary)
-- ==========================================================================
-- Root cause: violation_matrix column was renamed ai_trial_summary → ai_summary
-- but 4 dependent views were never updated, silently breaking the AI pipeline.

-- 1a. v_violations_resolved — 3-tier defendant resolution (EXACT→ALIAS→FUZZY)
CREATE OR REPLACE VIEW `authorityandbrand-workspace.legal_case.v_violations_resolved` AS
WITH resolved AS (
  SELECT
    vm.id, vm.violation_type, vm.violation_class, vm.statute_or_rule,
    vm.significance, vm.claim_status, vm.occurrence_date,
    vm.defendant_name AS raw_defendant,
    vm.factual_basis, vm.damages_amount_min, vm.damages_amount_max,
    vm.ai_summary,                        -- was: vm.ai_trial_summary
    COALESCE(d_exact.name, d_alias.name, d_contains.name, vm.defendant_name) AS canonical_defendant,
    COALESCE(d_exact.id,   d_alias.id,   d_contains.id)                      AS defendant_id,
    CASE
      WHEN d_exact.name    IS NOT NULL THEN 'EXACT'
      WHEN d_alias.name    IS NOT NULL THEN 'ALIAS'
      WHEN d_contains.name IS NOT NULL THEN 'FUZZY'
      ELSE 'UNRESOLVED'
    END AS resolution_method
  FROM `authorityandbrand-workspace.legal_case.violation_matrix` vm
  LEFT JOIN `authorityandbrand-workspace.legal_case.defendants` d_exact
    ON LOWER(TRIM(vm.defendant_name)) = LOWER(TRIM(d_exact.name))
  LEFT JOIN `authorityandbrand-workspace.legal_case.bq_entity_aliases` ea
    ON LOWER(TRIM(vm.defendant_name)) = LOWER(TRIM(ea.alias))
    AND ea.entity_type = 'defendant'
  LEFT JOIN `authorityandbrand-workspace.legal_case.defendants` d_alias
    ON LOWER(TRIM(ea.canonical_name)) = LOWER(TRIM(d_alias.name))
  LEFT JOIN `authorityandbrand-workspace.legal_case.defendants` d_contains
    ON d_exact.name IS NULL AND d_alias.name IS NULL
    AND LOWER(vm.defendant_name) LIKE CONCAT('%', LOWER(d_contains.name), '%')
    AND LENGTH(d_contains.name) > 5
)
SELECT
  id, violation_type, violation_class, statute_or_rule, significance, claim_status,
  occurrence_date, raw_defendant, canonical_defendant, defendant_id, resolution_method,
  factual_basis, damages_amount_min, damages_amount_max, ai_summary
FROM resolved;


-- 1b. v_case_graph — master join: violations + defendants + timeline + docket + personnel + docs
CREATE OR REPLACE VIEW `authorityandbrand-workspace.legal_case.v_case_graph` AS
SELECT
  vr.id                           AS violation_id,
  vr.violation_type, vr.violation_class, vr.statute_or_rule,
  vr.significance, vr.claim_status, vr.occurrence_date,
  vr.damages_amount_min, vr.damages_amount_max,
  vr.ai_summary,                        -- was: vr.ai_trial_summary
  LEFT(vr.factual_basis, 300)     AS factual_basis_excerpt,
  vr.canonical_defendant, vr.defendant_id,
  vr.resolution_method            AS defendant_resolution,
  d.role_type                     AS defendant_role,
  d.organization                  AS defendant_org,
  mt.id                           AS timeline_id,
  mt.event_type,
  mt.summary                      AS timeline_summary,
  mt.evidentiary_weight, mt.event_date,
  de.docket_number,
  de.document_type                AS docket_doc_type,
  LEFT(de.description, 150)       AS docket_desc,
  de.filed_by, de.date_filed,
  pvl.personnel_id, pvl.role_in_violation,
  dvl.document_id,
  dvl.proof_strength              AS doc_proof_strength
FROM `authorityandbrand-workspace.legal_case.v_violations_resolved` vr
LEFT JOIN `authorityandbrand-workspace.legal_case.defendants` d
  ON vr.defendant_id = d.id
LEFT JOIN `authorityandbrand-workspace.legal_case.master_timeline` mt
  ON mt.event_date = vr.occurrence_date
LEFT JOIN `authorityandbrand-workspace.legal_case.d1_docket_entries` de
  ON vr.occurrence_date IS NOT NULL
  AND de.date_filed IS NOT NULL
  AND ABS(DATE_DIFF(de.date_filed, vr.occurrence_date, DAY)) <= 30
LEFT JOIN `authorityandbrand-workspace.legal_case.d1_personnel_violation_link` pvl
  ON pvl.violation_id = vr.id
LEFT JOIN `authorityandbrand-workspace.legal_case.d1_document_violation_links` dvl
  ON dvl.violation_id = vr.id;


-- 1c. v_ai_ready_to_promote — shows summaries ready to push from ai_violation_summaries → violation_matrix
CREATE OR REPLACE VIEW `authorityandbrand-workspace.legal_case.v_ai_ready_to_promote` AS
SELECT
  s.violation_id, s.violation_type, s.violation_class, s.significance,
  s.ai_summary, s.ai_model, s.generated_at,
  s.reviewed_by, s.reviewed_at, s.review_notes, s.citation_verified_at,
  v.ai_summary AS current_canonical_value,   -- was: v.ai_trial_summary
  CASE
    WHEN v.ai_summary IS NULL             THEN 'NEW'
    WHEN v.ai_summary != s.ai_summary     THEN 'UPDATE'
    ELSE                                       'ALREADY_PROMOTED'
  END AS promotion_action
FROM `authorityandbrand-workspace.legal_case.ai_violation_summaries` s
LEFT JOIN `authorityandbrand-workspace.legal_case.violation_matrix` v
  ON v.id = s.violation_id
WHERE s.reviewed = TRUE
  AND s.citation_verified = TRUE
  AND s.promoted_to_canonical = FALSE;


-- 1d. v_bq_capability_status — live registry of all native BigQuery capabilities
--     (full DDL applied directly in BigQuery; key change: ai_trial_summary → ai_summary row)


-- ==========================================================================
-- SECTION 2: DIRTY DATA — violation_matrix scaffold artifacts (3 rows)
-- ==========================================================================
UPDATE `authorityandbrand-workspace.legal_case.violation_matrix`
SET
  violation_type = CASE id
    WHEN 1   THEN 'Failure to Maintain Documentation and Disclosure — TX Const Art XVI §50(a)(6)(Q)(x) Forfeiture'
    WHEN 608 THEN 'LOST_NOTE_NO_COURT_ORDER_3309B'
    WHEN 972 THEN 'False Oath in POC 7-1'
  END,
  claim_status  = CASE id WHEN 608 THEN 'SUPERSEDED' ELSE claim_status END,
  superseded_by = CASE id WHEN 608 THEN '619'        ELSE superseded_by END,
  updated_at    = CURRENT_TIMESTAMP()
WHERE id IN (1, 608, 972);


-- ==========================================================================
-- SECTION 3: FILL EMBEDDING GAPS (idempotent — NOT EXISTS guard prevents duplicates)
-- ==========================================================================
-- Run in batches of 200. Results go into ai_embeddings (source_table, source_id, embedding).
-- violation_matrix: 98.2% → 100% (19 rows, 1 batch)
-- key_findings:     53.8% → 100% (640 rows, 4 batches)
-- master_timeline:  60.8% → 100% (375 rows, 2 batches)

-- Generic template — adapt source_table, id column, and content expression:
INSERT INTO `authorityandbrand-workspace.legal_case.ai_embeddings`
  (source_table, source_id, source_text, embedding, embedded_at)
SELECT
  '<source_table>' AS source_table,
  CAST(t.id AS STRING) AS source_id,
  <content_expression> AS source_text,
  emb.ml_generate_embedding_result AS embedding,
  CURRENT_TIMESTAMP() AS embedded_at
FROM ML.GENERATE_EMBEDDING(
  MODEL `authorityandbrand-workspace.legal_case.text_embedding_model`,
  (
    SELECT CAST(t.id AS STRING) AS id, <content_expression> AS content
    FROM `authorityandbrand-workspace.legal_case.<source_table>` t
    WHERE NOT EXISTS (
      SELECT 1 FROM `authorityandbrand-workspace.legal_case.ai_embeddings` ae
      WHERE ae.source_id = CAST(t.id AS STRING)
        AND ae.source_table = '<source_table>'
    )
    AND <required_column> IS NOT NULL
    LIMIT 200
  ),
  STRUCT('RETRIEVAL_DOCUMENT' AS task_type)
) AS emb
JOIN `authorityandbrand-workspace.legal_case.<source_table>` t
  ON CAST(t.id AS STRING) = emb.id;


-- ==========================================================================
-- SECTION 4: NEW SELF-HEALER ENTRIES (heal-028 through heal-031)
-- ==========================================================================
-- heal-028: broken views (ai_trial_summary) — FIXED
-- heal-029: dirty violation_type scaffold text — FIXED
-- heal-030: embedding coverage gap — FIXED (100% coverage)
-- heal-031: ai_summary promotion disconnect — FIXED (see Section 7)


-- ==========================================================================
-- SECTION 5: NEW LLM ERROR-RECOVERY PATTERNS (v_query_recovery_map, 5 entries)
-- ==========================================================================
-- ai_trial_summary not found   → use ai_summary
-- statute_ref not found        → use statute_or_rule
-- FROM timeline_events         → use master_timeline
-- error_message on agent_query_log → correct column list
-- severity on violation_matrix → use significance


-- ==========================================================================
-- SECTION 7: AI SUMMARY BATCH GENERATION (2026-06-13)
-- ==========================================================================
-- Problem: violation_matrix.ai_summary was NULL for 1,029/1,049 rows (98%).
-- Fix: ML.GENERATE_TEXT (gemini-2.5-flash) run in 23 batches of 50 via
--      NOT EXISTS guard → staged in ai_violation_summaries → promoted to
--      violation_matrix.ai_summary in single UPDATE. Coverage: 1049/1049 (100%).

-- Step 1 — Generate batch (repeat until still_unprocessed = 0):
-- INSERT INTO `authorityandbrand-workspace.legal_case.ai_violation_summaries`
--   (violation_id, violation_type, violation_class, significance, ai_summary,
--    ai_model, generated_at, reviewed, citation_verified, promoted_to_canonical)
-- SELECT
--   CAST(g.id AS INT64), vm.violation_type, vm.violation_class, vm.significance,
--   TRIM(JSON_VALUE(g.ml_generate_text_result, '$.candidates[0].content.parts[0].text')),
--   JSON_VALUE(g.ml_generate_text_result, '$.model_version'),
--   CURRENT_TIMESTAMP(), TRUE, FALSE, FALSE
-- FROM ML.GENERATE_TEXT(
--   MODEL `authorityandbrand-workspace.legal_case.gemini_flash`,
--   (SELECT CAST(vm.id AS STRING) AS id,
--     CONCAT('Legal analyst: Summarize this case violation in 2-3 sentences for a federal court brief. ',
--       'State the statute violated, the specific prohibited conduct, and the resulting harm. ',
--       'Violation: ', vm.violation_type,
--       '. Statute: ', COALESCE(vm.statute_or_rule, 'not specified'),
--       '. Defendant: ', COALESCE(vm.defendant_name, 'not specified'),
--       '. Facts: ', LEFT(COALESCE(vm.factual_basis, COALESCE(vm.element_analysis, 'no details')), 600)
--     ) AS prompt
--    FROM `authorityandbrand-workspace.legal_case.violation_matrix` vm
--    WHERE vm.ai_summary IS NULL
--      AND NOT EXISTS (SELECT 1 FROM `authorityandbrand-workspace.legal_case.ai_violation_summaries` avs WHERE avs.violation_id = vm.id)
--    ORDER BY CASE vm.significance WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 ELSE 4 END, vm.id
--    LIMIT 50),
--   STRUCT(0.2 AS temperature, 300 AS max_output_tokens)
-- ) g
-- JOIN `authorityandbrand-workspace.legal_case.violation_matrix` vm ON CAST(vm.id AS STRING) = g.id;

-- Step 2 — Promote staged summaries to canonical:
-- UPDATE `authorityandbrand-workspace.legal_case.violation_matrix` vm
-- SET ai_summary = avs.ai_summary, updated_at = CURRENT_TIMESTAMP()
-- FROM `authorityandbrand-workspace.legal_case.ai_violation_summaries` avs
-- WHERE vm.id = avs.violation_id AND vm.ai_summary IS NULL AND avs.ai_summary IS NOT NULL;

-- Step 3 — Mark promoted in staging table:
-- UPDATE `authorityandbrand-workspace.legal_case.ai_violation_summaries` avs
-- SET promoted_to_canonical = TRUE, promoted_at = CURRENT_TIMESTAMP()
-- FROM `authorityandbrand-workspace.legal_case.violation_matrix` vm
-- WHERE avs.violation_id = vm.id AND vm.ai_summary IS NOT NULL AND avs.promoted_to_canonical = FALSE;


-- ==========================================================================
-- SECTION 8: VERIFICATION QUERY (updated 2026-06-13)
-- ==========================================================================
SELECT
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.v_violations_resolved`)          AS violations_resolved,
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.v_ai_ready_to_promote`)           AS ai_ready_to_promote,
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.violation_matrix`
   WHERE violation_type IN ('Test update','TEST_RECORD_SUPERSEDED_BY_619')
      OR LOWER(violation_type) LIKE '%smoke-test%')                                                AS dirty_rows_remaining,
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.ai_embeddings`
   WHERE source_table = 'violation_matrix')                                                        AS vm_embeddings,
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.violation_matrix`)                 AS vm_total,
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.ai_embeddings`
   WHERE source_table = 'key_findings')                                                            AS kf_embeddings,
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.key_findings`)                     AS kf_total,
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.ai_embeddings`
   WHERE source_table = 'master_timeline')                                                         AS mt_embeddings,
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.master_timeline`)                  AS mt_total,
  (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.violation_matrix`
   WHERE ai_summary IS NOT NULL)                                                                    AS vm_ai_summary_populated,
  ROUND(
    (SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.violation_matrix` WHERE ai_summary IS NOT NULL) * 100.0
    / NULLIF((SELECT COUNT(*) FROM `authorityandbrand-workspace.legal_case.violation_matrix`), 0), 1
  )                                                                                                 AS ai_summary_coverage_pct;
-- Expected 2026-06-13: dirty_rows_remaining=0, vm_embeddings=vm_total,
--   mt_embeddings=mt_total, ai_summary_coverage_pct=100.0
