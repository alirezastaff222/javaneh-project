-- Run against an isolated local Supabase database as supabase_admin.
-- All test users and lifecycle changes are rolled back.
BEGIN;

DO $catalog_integrity_test$
DECLARE
  v_version_id uuid;
  v_competition_id uuid;
  v_count integer;
  v_total integer;
  v_status text;
BEGIN
  SELECT v.id, c.id INTO v_version_id, v_competition_id
    FROM public.scoring_configurations AS config
    JOIN public.scoring_configuration_versions AS v
      ON v.configuration_id = config.id
    JOIN public.competitions AS c
      ON c.scoring_configuration_version_id = v.id
    WHERE config.configuration_key = 'javaneh-approved-scoring-policy-v1'
      AND v.version_number = 1;
  IF public.calculate_scoring_milestone_points(v_version_id, 'S1-M1', 1::smallint) <> 6
     OR public.calculate_scoring_milestone_points(v_version_id, 'S3-M2', 3::smallint) <> 26
     OR public.calculate_scoring_milestone_points(v_version_id, 'S6-M1', 4::smallint) <> 30 THEN
    RAISE EXCEPTION 'Evaluation multipliers or deterministic floor rounding are incorrect';
  END IF;
  IF v_version_id IS NULL OR v_competition_id IS NULL THEN
    RAISE EXCEPTION 'The Version 1.0 scoring configuration and draft competition must exist';
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.scoring_milestone_catalog AS m
    WHERE m.configuration_version_id = v_version_id
      AND m.catalog_version = '1.0';
  IF v_count <> 28 THEN
    RAISE EXCEPTION 'Expected 28 explicitly approved milestones; found %', v_count;
  END IF;

  IF EXISTS (
    SELECT 1
      FROM (VALUES
        ('S1-M1', 1, 25), ('S1-M2', 1, 20),
        ('S1-M3', 1, 20), ('S1-M4', 1, 15),
        ('S2-M1', 2, 25), ('S2-M2', 2, 25),
        ('S2-M3', 2, 25), ('S2-M4', 2, 25),
        ('S3-M1', 3, 30), ('S3-M2', 3, 35),
        ('S3-M3', 3, 35), ('S3-M4', 3, 20), ('S3-M5', 3, 20),
        ('S4-M1', 4, 25), ('S4-M2', 4, 35),
        ('S4-M3', 4, 25), ('S4-M4', 4, 30), ('S4-M5', 4, 25),
        ('S5-M1', 5, 25), ('S5-M2', 5, 25),
        ('S5-M3', 5, 25), ('S5-M4', 5, 25), ('S5-M5', 5, 20),
        ('S6-M1', 6, 30), ('S6-M2', 6, 30),
        ('S6-M3', 6, 20), ('S6-M4', 6, 20), ('S6-M5', 6, 20)
      ) AS expected(milestone_key, stage_number, point_value)
      FULL JOIN (
        SELECT m.milestone_key, m.stage_number, m.point_value
          FROM public.scoring_milestone_catalog AS m
          WHERE m.configuration_version_id = v_version_id
            AND m.catalog_version = '1.0'
      ) AS actual USING (milestone_key, stage_number, point_value)
      WHERE expected.milestone_key IS NULL OR actual.milestone_key IS NULL
  ) THEN
    RAISE EXCEPTION 'Version 1.0 milestone codes, stages, or maxima differ from policy';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.scoring_stage_catalog AS s
      LEFT JOIN (
        SELECT m.configuration_version_id, m.stage_number,
          pg_catalog.sum(m.point_value) AS points
        FROM public.scoring_milestone_catalog AS m
        WHERE m.configuration_version_id = v_version_id
          AND m.catalog_version = '1.0'
        GROUP BY m.configuration_version_id, m.stage_number
      ) AS totals USING (configuration_version_id, stage_number)
      WHERE s.configuration_version_id = v_version_id
        AND (
          (s.stage_number BETWEEN 1 AND 6
            AND COALESCE(totals.points, 0) <> s.maximum_points)
          OR (s.stage_number = 7 AND totals.points IS NOT NULL)
        )
  ) THEN
    RAISE EXCEPTION 'Stage totals are invalid or Stage 7 has participant milestones';
  END IF;

  SELECT pg_catalog.sum(s.maximum_points) INTO v_total
    FROM public.scoring_stage_catalog AS s
    WHERE s.configuration_version_id = v_version_id
      AND s.stage_kind = 'development';
  IF v_total <> 700 THEN
    RAISE EXCEPTION 'Development stages must total 700; found %', v_total;
  END IF;
  SELECT s.maximum_points INTO v_total
    FROM public.scoring_stage_catalog AS s
    WHERE s.configuration_version_id = v_version_id
      AND s.stage_number = 7;
  IF v_total <> 300 THEN
    RAISE EXCEPTION 'Human jury maximum must be 300; found %', v_total;
  END IF;
  SELECT v.overall_max_points, v.status INTO v_total, v_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = v_version_id;
  IF v_total <> 1000 OR v_status NOT IN ('draft', 'approved') THEN
    RAISE EXCEPTION 'Overall maximum or initial inactive status is invalid';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.scoring_milestone_catalog AS m
      WHERE m.configuration_version_id = v_version_id
        AND m.catalog_version = '1.0'
        AND (
          m.stage_number NOT BETWEEN 1 AND 6
          OR m.is_active
          OR m.catalog_status <> 'approved'
          OR m.descriptor_status <> 'approved'
          OR m.validation_mode <> CASE
            WHEN m.milestone_key IN ('S6-M1', 'S6-M5') THEN 'hybrid'
            ELSE 'qualitative'
          END
          OR m.level_0_description IS NOT NULL
          OR m.level_1_description IS NOT NULL
          OR m.level_2_description IS NOT NULL
          OR m.level_3_description IS NOT NULL
          OR m.level_4_description IS NOT NULL
          OR m.evidence_guidance IS NULL
          OR m.evaluator_instructions IS NULL
          OR m.level_4_indicators IS NULL
        )
  ) THEN
    RAISE EXCEPTION 'Catalog must remain inactive with approved guidance and the final supported validation modes';
  END IF;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_evaluation_levels AS l
        WHERE l.configuration_version_id = v_version_id) <> 5 THEN
    RAISE EXCEPTION 'All five evaluation levels must be seeded';
  END IF;
  IF (SELECT c.status
        FROM public.competitions AS c
        WHERE c.id = v_competition_id) <> 'draft' THEN
    RAISE EXCEPTION 'Competition must remain a draft';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname IN (
          'scoring_stage_catalog',
          'scoring_evaluation_levels',
          'competitions',
          'competition_events'
        )
        AND c.relkind = 'r'
        AND NOT (c.relrowsecurity AND c.relforcerowsecurity)
  ) OR (
    SELECT pg_catalog.count(*)
      FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname IN (
          'scoring_stage_catalog',
          'scoring_evaluation_levels',
          'competitions',
          'competition_events'
        )
        AND c.relkind = 'r'
        AND c.relrowsecurity
        AND c.relforcerowsecurity
  ) <> 4 THEN
    RAISE EXCEPTION 'All M9R3 authoritative tables must have forced RLS';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_milestone_catalog', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_milestone_catalog', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.competitions', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.competitions', 'UPDATE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.set_competition_status(uuid,text,text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.set_competition_status(uuid,text,text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'M9R3 direct write privileges or RPC grants are invalid';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_constraint AS c
    WHERE c.conrelid = 'public.scoring_configurations'::regclass
      AND c.conname ILIKE '%competition%'
      AND c.contype = 'f'
  ) THEN
    RAISE EXCEPTION 'Opaque legacy competition_id values must not gain an unvalidated foreign key';
  END IF;
END
$catalog_integrity_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a3000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
    'm9r3-admin@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a3000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
    'm9r3-validator@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  );

INSERT INTO public.scoring_role_assignments (user_id, role_name, assigned_by)
VALUES
  ('a3000000-0000-4000-8000-000000000001', 'scoring_administrator', NULL),
  ('a3000000-0000-4000-8000-000000000002', 'validator', NULL);

DO $test_identifiers$
DECLARE
  v_version_id uuid;
  v_competition_id uuid;
BEGIN
  SELECT v.id, c.id INTO v_version_id, v_competition_id
    FROM public.scoring_configurations AS config
    JOIN public.scoring_configuration_versions AS v
      ON v.configuration_id = config.id
    JOIN public.competitions AS c
      ON c.scoring_configuration_version_id = v.id
    WHERE config.configuration_key = 'javaneh-approved-scoring-policy-v1'
      AND v.version_number = 1;
  PERFORM pg_catalog.set_config('test.m9r3_version_id', v_version_id::text, true);
  PERFORM pg_catalog.set_config('test.m9r3_competition_id', v_competition_id::text, true);
END
$test_identifiers$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a3000000-0000-4000-8000-000000000002', true
);
DO $unauthorized_lifecycle_test$
DECLARE
  v_version_id uuid;
  v_rejected boolean := false;
BEGIN
  v_version_id := pg_catalog.current_setting('test.m9r3_version_id')::uuid;
  BEGIN
    PERFORM public.approve_scoring_configuration_version(
      v_version_id, 'Validator authorization test.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Validator unexpectedly approved scoring configuration';
  END IF;
  v_rejected := false;
  BEGIN
    PERFORM public.activate_scoring_configuration_version(
      v_version_id, 'Validator authorization test.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Validator unexpectedly activated scoring configuration';
  END IF;
END
$unauthorized_lifecycle_test$;
RESET ROLE;

ROLLBACK;
