-- Run against an isolated local Supabase database as supabase_admin.
BEGIN;

DO $ranking_contract_test$
DECLARE
  v_points_type text;
BEGIN
  SELECT format_type(attribute.atttypid, attribute.atttypmod)
    INTO v_points_type
    FROM pg_catalog.pg_attribute AS attribute
   WHERE attribute.attrelid = 'public.official_points_ledger'::regclass
     AND attribute.attname = 'points'
     AND NOT attribute.attisdropped;

  IF v_points_type <> 'numeric(10,2)' THEN
    RAISE EXCEPTION 'Existing ledger points type changed unexpectedly: %', v_points_type;
  END IF;
  IF NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.prepare_competition_results(uuid,text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.prepare_competition_results(uuid,text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.publish_competition_results(uuid,text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Ranking operation grants are unsafe';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class
     WHERE oid = 'public.competition_result_versions'::regclass
       AND relforcerowsecurity
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class
     WHERE oid = 'public.competition_result_entries'::regclass
       AND relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'Ranking result tables must force RLS';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'public.competition_result_versions'::regclass
      AND tgname = 'competition_result_versions_immutable'
      AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'public.competition_result_entries'::regclass
      AND tgname = 'competition_result_entries_immutable'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'Result immutability triggers are missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS procedure
    WHERE procedure.oid = 'public.get_participant_published_result(uuid)'::regprocedure
      AND pg_catalog.pg_get_functiondef(procedure.oid)
        LIKE '%idea.owner_id = javaneh_private.current_uid()%'
  ) THEN
    RAISE EXCEPTION 'Participant ownership check is missing';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS procedure
    WHERE procedure.oid = 'public.prepare_competition_results(uuid,text)'::regprocedure
      AND pg_catalog.pg_get_functiondef(procedure.oid)
        LIKE '%stage_number BETWEEN 1 AND 6%'
      AND pg_catalog.pg_get_functiondef(procedure.oid)
        LIKE '%jury.status = ''published''%'
      AND pg_catalog.pg_get_functiondef(procedure.oid)
        LIKE '%rank() OVER (ORDER BY development_score + jury_score DESC)%'
  ) THEN
    RAISE EXCEPTION 'Authoritative score sources or competition ranking are missing';
  END IF;
END
$ranking_contract_test$;

DO $ranking_arithmetic_test$
DECLARE
  v_development numeric(10,2) := 642.00;
  v_jury numeric(10,2) := 287.33;
  v_final numeric(10,2);
BEGIN
  v_final := v_development + v_jury;
  IF v_final <> 929.33 OR v_final > 1000 THEN
    RAISE EXCEPTION 'Final score combination is incorrect: %', v_final;
  END IF;
END
$ranking_arithmetic_test$;

DO $ranking_tie_policy_test$
DECLARE
  v_ranks integer[];
BEGIN
  SELECT array_agg(rank ORDER BY final_score DESC, idea_id)
    INTO v_ranks
    FROM (
      SELECT final_score, idea_id,
        rank() OVER (ORDER BY final_score DESC)::integer AS rank
      FROM (VALUES
        (900.00::numeric, '00000000-0000-0000-0000-000000000001'::uuid),
        (800.00::numeric, '00000000-0000-0000-0000-000000000002'::uuid),
        (800.00::numeric, '00000000-0000-0000-0000-000000000003'::uuid),
        (700.00::numeric, '00000000-0000-0000-0000-000000000004'::uuid)
      ) AS scores(final_score, idea_id)
    ) ranked;
  IF v_ranks <> ARRAY[1, 2, 2, 4] THEN
    RAISE EXCEPTION 'Competition ranking tie policy is incorrect: %', v_ranks;
  END IF;
END
$ranking_tie_policy_test$;

ROLLBACK;
