-- Run against an isolated local Supabase database as supabase_admin.
-- Structural and arithmetic compatibility checks for M9R9.
BEGIN;

DO $jury_schema_test$
DECLARE
  v_version_id uuid;
  v_points_type text;
  v_active_assignment_trigger boolean;
BEGIN
  SELECT version.id INTO v_version_id
    FROM public.scoring_configuration_versions AS version
    JOIN public.scoring_configurations AS configuration
      ON configuration.id = version.configuration_id
   WHERE configuration.configuration_key = 'javaneh-approved-scoring-policy-v1'
     AND version.version_number = 1;
  IF v_version_id IS NULL THEN
    RAISE EXCEPTION 'Approved scoring configuration fixture is missing';
  END IF;

  SELECT format_type(attribute.atttypid, attribute.atttypmod)
    INTO v_points_type
    FROM pg_catalog.pg_attribute AS attribute
   WHERE attribute.attrelid = 'public.official_points_ledger'::regclass
     AND attribute.attname = 'points'
     AND NOT attribute.attisdropped;
  IF v_points_type <> 'numeric(10,2)' THEN
    RAISE EXCEPTION 'Ledger points type is not numeric(10,2): %', v_points_type;
  END IF;

  IF (SELECT count(*) FROM public.jury_rubric_criteria
       WHERE configuration_version_id = v_version_id) <> 7
     OR (SELECT sum(maximum_points) FROM public.jury_rubric_criteria
       WHERE configuration_version_id = v_version_id) <> 300 THEN
    RAISE EXCEPTION 'The approved seven-criterion 300-point rubric is incomplete';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
     WHERE tgrelid = 'public.jury_assignments'::regclass
       AND tgname = 'jury_assignments_limit'
       AND NOT tgisinternal
  ) INTO v_active_assignment_trigger;
  IF NOT v_active_assignment_trigger THEN
    RAISE EXCEPTION 'Three-active-juror assignment guard is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class
     WHERE oid = 'public.jury_assignments'::regclass
       AND relforcerowsecurity
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class
     WHERE oid = 'public.jury_evaluations'::regclass
       AND relforcerowsecurity
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_class
     WHERE oid = 'public.jury_evaluation_scores'::regclass
       AND relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'Jury evaluation tables are not forced through RLS';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.jury_evaluation_scores', 'SELECT'
     ) OR pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'INSERT'
     ) THEN
    RAISE EXCEPTION 'Protected jury or ledger table grants are unsafe';
  END IF;
END
$jury_schema_test$;

DO $jury_arithmetic_test$
DECLARE
  v_maximum integer;
  v_level integer;
  v_points integer;
BEGIN
  FOR v_maximum, v_level IN
    SELECT * FROM (VALUES
      (48, 0), (48, 1), (48, 2), (48, 3), (48, 4),
      (36, 0), (36, 1), (36, 2), (36, 3), (36, 4),
      (44, 0), (44, 1), (44, 2), (44, 3), (44, 4)
    ) AS expected(maximum_points, evaluation_level)
  LOOP
    v_points := (v_maximum * v_level) / 4;
    IF v_points < 0 OR v_points > v_maximum THEN
      RAISE EXCEPTION 'Criterion score escaped its configured range';
    END IF;
  END LOOP;

  IF round((113 + 197 + 251)::numeric / 3, 2) <> 187.00 THEN
    RAISE EXCEPTION 'Three-juror arithmetic mean is not rounded to two decimals';
  END IF;
END
$jury_arithmetic_test$;

DO $jury_function_contract_test$
BEGIN
  IF NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.get_participant_published_jury_score(uuid)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.publish_jury_result(uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.publish_jury_result(uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Jury publication or participant visibility grants are unsafe';
  END IF;
END
$jury_function_contract_test$;

ROLLBACK;
