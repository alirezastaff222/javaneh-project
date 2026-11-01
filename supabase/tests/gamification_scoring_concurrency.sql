-- Run only in a fresh disposable database as supabase_admin, then drop the database.
-- The committed request is shared by independent pgbench clients.
BEGIN;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES (
  'a6000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
  'm9r5-concurrent-participant@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
  pg_catalog.now(), pg_catalog.now(), false, false
);

INSERT INTO public.scoring_configurations (configuration_key)
VALUES ('m9r5-concurrent-test');

DO $seed_concurrent_scoring$
DECLARE
  v_configuration_id uuid;
  v_version_id uuid;
BEGIN
  SELECT configuration.id INTO v_configuration_id
    FROM public.scoring_configurations AS configuration
    WHERE configuration.configuration_key = 'm9r5-concurrent-test';
  INSERT INTO public.scoring_configuration_versions (
    configuration_id, version_number, development_max_points,
    human_jury_max_points, overall_max_points, rounding_policy
  )
  VALUES (v_configuration_id, 1, 700, 300, 1000, 'floor')
  RETURNING id INTO v_version_id;
  PERFORM pg_catalog.set_config(
    'test.m9r5_concurrent_version', v_version_id::text, true
  );

  INSERT INTO public.scoring_stage_catalog (
    configuration_version_id, stage_number, display_name, stage_kind,
    maximum_points, sort_order
  )
  VALUES
    (v_version_id, 1, 'Test Stage 1', 'development', 80, 1),
    (v_version_id, 2, 'Test Stage 2', 'development', 100, 2),
    (v_version_id, 3, 'Test Stage 3', 'development', 140, 3),
    (v_version_id, 4, 'Test Stage 4', 'development', 140, 4),
    (v_version_id, 5, 'Test Stage 5', 'development', 120, 5),
    (v_version_id, 6, 'Test Stage 6', 'development', 120, 6),
    (v_version_id, 7, 'Test Stage 7', 'human_jury', 300, 7);
  INSERT INTO public.scoring_evaluation_levels (
    configuration_version_id, evaluation_level, display_label, multiplier
  )
  VALUES
    (v_version_id, 0, 'Not achieved', 0.00),
    (v_version_id, 1, 'Very limited', 0.25),
    (v_version_id, 2, 'Developing', 0.50),
    (v_version_id, 3, 'Satisfactory', 0.75),
    (v_version_id, 4, 'Fully achieved and supported', 1.00);
  INSERT INTO public.scoring_milestone_catalog (
    configuration_version_id, milestone_key, stage_number, definition,
    point_value, is_active, catalog_version, display_name,
    participant_description, evaluator_description, validation_mode,
    validation_policy, catalog_status, sort_order, descriptor_status,
    level_0_description, level_1_description, level_2_description,
    level_3_description, level_4_description, evidence_guidance,
    evaluator_instructions
  )
  VALUES (
    v_version_id, 'S1-M1', 1, 'Concurrent objective test.', 20, true,
    'm9r5-concurrent-v1', 'Concurrent test', 'Concurrent test',
    'Concurrent test', 'objective',
    '{"objective_checks":[{"stage_number":1,"path":["problem"],"operator":"present"}]}',
    'active', 1, 'approved',
    'Not achieved', 'Very limited', 'Developing', 'Satisfactory', 'Fully achieved',
    'Rollback-only evidence guidance.', 'Rollback-only objective instructions.'
  );
  UPDATE public.scoring_configuration_versions
    SET status = 'approved',
        approved_by = 'a6000000-0000-4000-8000-000000000001',
        approved_at = pg_catalog.clock_timestamp()
    WHERE id = v_version_id;
  UPDATE public.scoring_configuration_versions
    SET status = 'active',
        activated_at = pg_catalog.clock_timestamp()
    WHERE id = v_version_id;
  INSERT INTO public.competitions (
    competition_key, name, description, status,
    scoring_configuration_version_id
  )
  VALUES (
    'm9r5-concurrent-test', 'M9R5 Concurrent Test',
    'Disposable concurrent award fixture.', 'active', v_version_id
  );
END
$seed_concurrent_scoring$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a6000000-0000-4000-8000-000000000001', true
);
DO $create_concurrent_request$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
BEGIN
  v_result := public.create_idea('a6100000-0000-4000-8000-000000000001');
  v_idea_id := (v_result->>'idea_id')::uuid;
  v_result := public.save_idea_content(
    v_idea_id, 'a6200000-0000-4000-8000-000000000001', 1,
    '[{"stage_number":1,"data":{"problem":"Concurrent award evidence"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Concurrent award evidence save failed: %', v_result;
  END IF;
  v_result := public.submit_milestone_for_validation(
    v_idea_id, pg_catalog.current_setting('test.m9r5_concurrent_version')::uuid,
    'S1-M1', 2
  );
  IF v_result->>'outcome' <> 'validated' THEN
    RAISE EXCEPTION 'Concurrent award request failed: %', v_result;
  END IF;
END
$create_concurrent_request$;
RESET ROLE;
COMMIT;

SELECT request.request_id
  FROM public.milestone_validation_requests AS request
  JOIN public.scoring_configurations AS configuration
    ON configuration.configuration_key = 'm9r5-concurrent-test'
  JOIN public.scoring_configuration_versions AS version
    ON version.configuration_id = configuration.id
   AND version.id = request.configuration_version_id
  WHERE request.participant_id = 'a6000000-0000-4000-8000-000000000001'
    AND request.milestone_key = 'S1-M1'
    AND version.version_number = 1;
