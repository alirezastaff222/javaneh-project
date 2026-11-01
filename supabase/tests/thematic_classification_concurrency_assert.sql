-- Run after pgbench as supabase_admin against the disposable fixture database.
DO $phase7_concurrency_assertion$
DECLARE
  v_outcomes integer;
  v_claimed integer;
  v_in_progress integer;
  v_result_count integer;
BEGIN
  SELECT
    pg_catalog.count(*),
    pg_catalog.count(*) FILTER (WHERE outcome = 'claimed'),
    pg_catalog.count(*) FILTER (WHERE outcome = 'in_progress')
  INTO v_outcomes, v_claimed, v_in_progress
  FROM public.m9r13_classification_claim_outcomes;

  IF v_outcomes <> 2 OR v_claimed <> 1 OR v_in_progress <> 1 THEN
    RAISE EXCEPTION
      'Expected two claims (one claimed, one in_progress); got %, %, %',
      v_outcomes, v_claimed, v_in_progress;
  END IF;

  SELECT pg_catalog.count(*) INTO v_result_count
  FROM public.idea_classification_results AS result
  JOIN public.m9r13_classification_claim_fixture AS fixture
    ON fixture.idea_id = result.idea_id;
  IF v_result_count <> 0 THEN
    RAISE EXCEPTION
      'Claim-only concurrency test unexpectedly wrote % successful results',
      v_result_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.idea_classification_results AS result
    JOIN public.m9r13_classification_claim_fixture AS fixture
      ON fixture.idea_id = result.idea_id
    GROUP BY result.idea_id,
             result.source_stage_1_revision_id,
             result.source_stage_2_revision_id,
             result.taxonomy_version,
             result.prompt_version
    HAVING pg_catalog.count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Duplicate successful classification rows were found';
  END IF;
END
$phase7_concurrency_assertion$;

SELECT outcome, pg_catalog.count(*) AS clients
FROM public.m9r13_classification_claim_outcomes
GROUP BY outcome
ORDER BY outcome;
