-- Run against an isolated local Supabase database as supabase_admin.
-- All M9R5 users, awards, corrections, and requests are rolled back.
BEGIN;

DO $scoring_security_test$
BEGIN
  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'DELETE'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.official_points_ledger', 'INSERT'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.award_validated_milestone(uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.award_validated_milestone(uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Scoring ledger or award operation grants are unsafe';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_index AS index
      WHERE index.indrelid = 'public.official_points_ledger'::regclass
        AND index.indisunique
        AND pg_catalog.pg_get_indexdef(index.indexrelid)
          LIKE '%(idea_id, configuration_version_id, milestone_key)%'
  ) OR NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_index AS index
      WHERE index.indrelid = 'public.official_points_ledger'::regclass
        AND index.indisunique
        AND pg_catalog.pg_get_indexdef(index.indexrelid)
          LIKE '%(validation_request_id)%'
  ) THEN
    RAISE EXCEPTION 'Award identity uniqueness constraints are missing';
  END IF;
END
$scoring_security_test$;

DO $version_one_formula_test$
DECLARE
  v_version_id uuid;
BEGIN
  SELECT version.id INTO v_version_id
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1;
  IF v_version_id IS NULL THEN
    RAISE EXCEPTION 'The approved Version 1.0 policy fixture is missing';
  END IF;
  IF public.calculate_scoring_milestone_points(v_version_id, 'S1-M1', 0::smallint) <> 0
     OR public.calculate_scoring_milestone_points(v_version_id, 'S1-M1', 1::smallint) <> 6
     OR public.calculate_scoring_milestone_points(v_version_id, 'S1-M1', 2::smallint) <> 12
     OR public.calculate_scoring_milestone_points(v_version_id, 'S1-M1', 3::smallint) <> 18
     OR public.calculate_scoring_milestone_points(v_version_id, 'S1-M1', 4::smallint) <> 25
     OR public.calculate_scoring_milestone_points(v_version_id, 'S3-M2', 1::smallint) <> 8
     OR public.calculate_scoring_milestone_points(v_version_id, 'S3-M2', 2::smallint) <> 17
     OR public.calculate_scoring_milestone_points(v_version_id, 'S3-M2', 3::smallint) <> 26
     OR public.calculate_scoring_milestone_points(v_version_id, 'S3-M2', 4::smallint) <> 35 THEN
    RAISE EXCEPTION 'A Version 1.0 evaluation level or exact floor result is incorrect';
  END IF;
  IF (SELECT version.development_max_points
        FROM public.scoring_configuration_versions AS version
        WHERE version.id = v_version_id) <> 700
     OR (SELECT version.human_jury_max_points
           FROM public.scoring_configuration_versions AS version
           WHERE version.id = v_version_id) <> 300
     OR (SELECT version.overall_max_points
           FROM public.scoring_configuration_versions AS version
           WHERE version.id = v_version_id) <> 1000
     OR (SELECT version.rounding_policy
           FROM public.scoring_configuration_versions AS version
           WHERE version.id = v_version_id) <> 'floor' THEN
    RAISE EXCEPTION 'The approved Version 1.0 allocations or rounding changed';
  END IF;
END
$version_one_formula_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a5000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
    'm9r5-participant@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a5000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
    'm9r5-validator@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a5000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
    'm9r5-scoring-admin@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a5000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated',
    'm9r5-other-participant@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  );

INSERT INTO public.scoring_role_assignments (user_id, role_name, assigned_by)
VALUES
  ('a5000000-0000-4000-8000-000000000002', 'validator', NULL),
  ('a5000000-0000-4000-8000-000000000003', 'scoring_administrator', NULL);

INSERT INTO public.scoring_configurations (configuration_key)
VALUES ('m9r5-scoring-test');

DO $seed_scoring_configuration$
DECLARE
  v_configuration_id uuid;
  v_version_id uuid;
  v_competition_id uuid;
BEGIN
  SELECT configuration.id INTO v_configuration_id
    FROM public.scoring_configurations AS configuration
    WHERE configuration.configuration_key = 'm9r5-scoring-test';
  INSERT INTO public.scoring_configuration_versions (
    configuration_id, version_number, development_max_points,
    human_jury_max_points, overall_max_points, rounding_policy
  )
  VALUES (v_configuration_id, 1, 75, 300, 375, 'floor')
  RETURNING id INTO v_version_id;
  PERFORM pg_catalog.set_config('test.m9r5_version_id', v_version_id::text, true);

  INSERT INTO public.scoring_stage_catalog (
    configuration_version_id, stage_number, display_name, stage_kind,
    maximum_points, sort_order
  )
  VALUES
    (v_version_id, 1, 'Test Stage 1', 'development', 75, 1),
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
  VALUES
    (
      v_version_id, 'S1-M1', 1, 'Objective scoring test.', 15, true,
      'm9r5-test-v1', 'Objective test', 'Objective test', 'Objective test',
      'objective',
      '{"objective_checks":[{"stage_number":1,"path":["problem"],"operator":"present"}]}',
      'active', 1, 'approved',
      'Not achieved', 'Very limited', 'Developing', 'Satisfactory', 'Fully achieved',
      'Rollback-only evidence guidance.', 'Rollback-only objective instructions.'
    ),
    (
      v_version_id, 'S1-M2', 1, 'Qualitative scoring test.', 25, true,
      'm9r5-test-v1', 'Qualitative test', 'Qualitative test', 'Qualitative test',
      'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}',
      'active', 2, 'approved',
      'Not achieved', 'Very limited', 'Developing', 'Satisfactory', 'Fully achieved',
      'Rollback-only evidence guidance.', 'Rollback-only qualitative instructions.'
    ),
    (
      v_version_id, 'S1-M3', 1, 'Hybrid scoring test.', 30, true,
      'm9r5-test-v1', 'Hybrid test', 'Hybrid test', 'Hybrid test', 'hybrid',
      '{"objective_checks":[{"stage_number":1,"path":["problem"],"operator":"present"}],"human":{"levels":[0,1,2,3,4]}}',
      'active', 3, 'approved',
      'Not achieved', 'Very limited', 'Developing', 'Satisfactory', 'Fully achieved',
      'Rollback-only evidence guidance.', 'Rollback-only hybrid instructions.'
    ),
    (
      v_version_id, 'S1-M4', 1, 'Stage cap test.', 15, true,
      'm9r5-test-v1', 'Stage cap test', 'Stage cap test', 'Stage cap test',
      'objective',
      '{"objective_checks":[{"stage_number":1,"path":["problem"],"operator":"present"}]}',
      'active', 4, 'approved',
      'Not achieved', 'Very limited', 'Developing', 'Satisfactory', 'Fully achieved',
      'Rollback-only evidence guidance.', 'Rollback-only cap instructions.'
    ),
    (
      v_version_id, 'S2-M1', 2, 'Development cap test one.', 5, true,
      'm9r5-test-v1', 'Development cap one', 'Development cap one',
      'Development cap one', 'objective',
      '{"objective_checks":[{"stage_number":2,"path":["proof"],"operator":"present"}]}',
      'active', 1, 'approved',
      'Not achieved', 'Very limited', 'Developing', 'Satisfactory', 'Fully achieved',
      'Rollback-only evidence guidance.', 'Rollback-only cap instructions.'
    ),
    (
      v_version_id, 'S2-M2', 2, 'Development cap test two.', 8, true,
      'm9r5-test-v1', 'Development cap two', 'Development cap two',
      'Development cap two', 'objective',
      '{"objective_checks":[{"stage_number":2,"path":["proof"],"operator":"present"}]}',
      'active', 2, 'approved',
      'Not achieved', 'Very limited', 'Developing', 'Satisfactory', 'Fully achieved',
      'Rollback-only evidence guidance.', 'Rollback-only cap instructions.'
    );

  UPDATE public.scoring_configuration_versions
    SET status = 'approved',
        approved_by = 'a5000000-0000-4000-8000-000000000003',
        approved_at = pg_catalog.clock_timestamp()
    WHERE id = v_version_id;
  UPDATE public.scoring_configuration_versions
    SET status = 'active',
        activated_at = pg_catalog.clock_timestamp()
    WHERE id = v_version_id;

  INSERT INTO public.competitions (
    competition_key, name, description, status,
    scoring_configuration_version_id, entry_opens_at, entry_closes_at
  )
  VALUES (
    'm9r5-scoring-test', 'M9R5 Scoring Test',
    'Rollback-only test competition.', 'active', v_version_id,
    pg_catalog.clock_timestamp() - interval '1 hour',
    pg_catalog.clock_timestamp() + interval '1 day'
  )
  RETURNING id INTO v_competition_id;
  PERFORM pg_catalog.set_config(
    'test.m9r5_competition_id', v_competition_id::text, true
  );
END
$seed_scoring_configuration$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000001', true
);

DO $create_scoring_idea$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
BEGIN
  v_result := public.create_idea('a5100000-0000-4000-8000-000000000001');
  v_idea_id := (v_result->>'idea_id')::uuid;
  IF v_idea_id IS NULL THEN
    RAISE EXCEPTION 'M9R5 test idea was not created: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config('test.m9r5_idea_id', v_idea_id::text, true);
  v_result := public.save_idea_content(
    v_idea_id, 'a5200000-0000-4000-8000-000000000001', 1,
    '[{"stage_number":1,"data":{"problem":"Scoring evidence"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'M9R5 test evidence was not saved: %', v_result;
  END IF;
END
$create_scoring_idea$;

DO $objective_award_test$
DECLARE
  v_result jsonb;
  v_request_id uuid;
  v_award_id uuid;
  v_eligibility_ai jsonb;
  v_eligibility_fallback jsonb;
  v_award_count_before bigint;
  v_award_count_after bigint;
  v_rejected boolean := false;
BEGIN
  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid,
    pg_catalog.current_setting('test.m9r5_version_id')::uuid,
    'S1-M1', 2
  );
  IF v_result->>'outcome' <> 'validated'
     OR v_result->'objective_result'->>'passed' <> 'true' THEN
    RAISE EXCEPTION 'Objective request was not validated: %', v_result;
  END IF;
  v_request_id := (v_result->>'request_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r5_objective_request', v_request_id::text, true);

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000002', true
  );
  BEGIN
    PERFORM public.award_validated_milestone(v_request_id);
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A Validator issued an objective award for another participant';
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000001', true
  );
  SELECT pg_catalog.count(*) INTO v_award_count_before
    FROM public.official_points_ledger AS ledger
    WHERE ledger.idea_id =
      pg_catalog.current_setting('test.m9r5_idea_id')::uuid;
  PERFORM pg_catalog.set_config(
    'app.javaneh.mentor_mode', 'ai_assisted', true
  );
  v_eligibility_ai := public.get_milestone_scoring_eligibility(v_request_id);
  PERFORM pg_catalog.set_config(
    'app.javaneh.mentor_mode', 'non_ai_fallback', true
  );
  v_eligibility_fallback :=
    public.get_milestone_scoring_eligibility(v_request_id);
  SELECT pg_catalog.count(*) INTO v_award_count_after
    FROM public.official_points_ledger AS ledger
    WHERE ledger.idea_id =
      pg_catalog.current_setting('test.m9r5_idea_id')::uuid;
  IF v_eligibility_ai IS DISTINCT FROM v_eligibility_fallback
     OR v_eligibility_ai->>'eligible' <> 'true'
     OR v_award_count_after <> v_award_count_before THEN
    RAISE EXCEPTION
      'AI mode changed milestone eligibility or caused an award: %, %',
      v_eligibility_ai, v_eligibility_fallback;
  END IF;

  v_result := public.award_validated_milestone(v_request_id);
  IF v_result->>'outcome' <> 'awarded'
     OR v_result->>'points' <> '15'
     OR v_result->>'catalog_version' <> 'm9r5-test-v1'
     OR v_result->>'competition_id' <>
       pg_catalog.current_setting('test.m9r5_competition_id') THEN
    RAISE EXCEPTION 'Objective award did not derive authoritative metadata: %',
      v_result;
  END IF;
  v_award_id := (v_result->>'entry_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r5_objective_award', v_award_id::text, true);

  v_result := public.award_validated_milestone(v_request_id);
  IF v_result->>'outcome' <> 'already_awarded'
     OR v_result->>'entry_id' <> v_award_id::text THEN
    RAISE EXCEPTION 'Objective award retry did not return the existing entry: %',
      v_result;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.official_points_ledger AS ledger
      WHERE ledger.entry_id = v_award_id
        AND ledger.validation_request_id = v_request_id
        AND ledger.source_reference = v_request_id
        AND ledger.evaluation_level IS NULL
        AND ledger.points = 15
  ) THEN
    RAISE EXCEPTION 'Objective ledger references are not reconstructible';
  END IF;
END
$objective_award_test$;

RESET ROLE;
DO $criterion_maximum_guard_test$
DECLARE
  v_rejected boolean := false;
  v_request_id uuid :=
    pg_catalog.current_setting('test.m9r5_objective_request')::uuid;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000001', true
  );
  BEGIN
    INSERT INTO public.official_points_ledger (
      idempotency_key, user_id, idea_id, configuration_version_id,
      milestone_key, stage_number, entry_kind, points, source,
      source_reference, reason, recorded_by, competition_id,
      catalog_version, validation_request_id, evaluation_level
    )
    VALUES (
      pg_catalog.gen_random_uuid(),
      'a5000000-0000-4000-8000-000000000001',
      pg_catalog.current_setting('test.m9r5_idea_id')::uuid,
      pg_catalog.current_setting('test.m9r5_version_id')::uuid,
      'S1-M1', 1, 'award', 16, 'milestone_validation',
      v_request_id, 'Forged criterion overrun.',
      'a5000000-0000-4000-8000-000000000001',
      pg_catalog.current_setting('test.m9r5_competition_id')::uuid,
      'm9r5-test-v1', v_request_id, NULL
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A ledger insert exceeded its configured criterion maximum';
  END IF;
END
$criterion_maximum_guard_test$;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000001', true
);

DO $human_and_hybrid_award_test$
DECLARE
  v_result jsonb;
  v_request_id uuid;
  v_validation_id uuid;
  v_expected integer;
BEGIN
  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid,
    pg_catalog.current_setting('test.m9r5_version_id')::uuid,
    'S1-M2', 2
  );
  IF v_result->>'outcome' <> 'pending_validation' THEN
    RAISE EXCEPTION 'Qualitative request did not enter Validator review: %',
      v_result;
  END IF;
  v_request_id := (v_result->>'request_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r5_human_request', v_request_id::text, true);

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000002', true
  );
  v_result := public.validate_milestone_request(
    v_request_id, 'validated', 3::smallint, 'Rollback-only human approval.'
  );
  IF v_result->>'outcome' <> 'validated' THEN
    RAISE EXCEPTION 'Qualitative human decision failed: %', v_result;
  END IF;
  v_validation_id := (v_result->>'validation_id')::uuid;

  IF public.calculate_scoring_milestone_points(
       pg_catalog.current_setting('test.m9r5_version_id')::uuid,
       'S1-M2', 3::smallint
     ) <> 18 THEN
    RAISE EXCEPTION 'Exact numeric floor rounding for 25 x 0.75 failed';
  END IF;
  v_result := public.award_validated_milestone(v_request_id);
  IF v_result->>'outcome' <> 'awarded' OR v_result->>'points' <> '18'
     OR v_result->>'evaluation_level' <> '3' THEN
    RAISE EXCEPTION 'Human award did not use the validated level: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'test.m9r5_human_award', v_result->>'entry_id', true
  );

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000001', true
  );
  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid,
    pg_catalog.current_setting('test.m9r5_version_id')::uuid,
    'S1-M3', 2
  );
  IF v_result->>'outcome' <> 'pending_validation'
     OR v_result->'objective_result'->>'passed' <> 'true' THEN
    RAISE EXCEPTION 'Hybrid objective component did not pass: %', v_result;
  END IF;
  v_request_id := (v_result->>'request_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r5_hybrid_request', v_request_id::text, true);
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000002', true
  );
  v_result := public.validate_milestone_request(
    v_request_id, 'validated', 4::smallint, 'Rollback-only hybrid approval.'
  );
  IF v_result->>'outcome' <> 'validated' THEN
    RAISE EXCEPTION 'Hybrid human decision failed: %', v_result;
  END IF;
  v_result := public.award_validated_milestone(v_request_id);
  IF v_result->>'outcome' <> 'awarded' OR v_result->>'points' <> '30'
     OR v_result->>'evaluation_level' <> '4' THEN
    RAISE EXCEPTION 'Hybrid award did not use its validated level: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'test.m9r5_hybrid_award', v_result->>'entry_id', true
  );

  SELECT pg_catalog.sum(ledger.points)::integer INTO v_expected
    FROM public.official_points_ledger AS ledger
    WHERE ledger.idea_id =
      pg_catalog.current_setting('test.m9r5_idea_id')::uuid
      AND ledger.configuration_version_id =
        pg_catalog.current_setting('test.m9r5_version_id')::uuid
      AND ledger.stage_number = 1;
  IF v_expected <> 63 THEN
    RAISE EXCEPTION 'Stage score was not reconstructed from the ledger: %',
      v_expected;
  END IF;

  IF v_validation_id IS NULL THEN
    RAISE EXCEPTION 'Human decision reference was not returned';
  END IF;
END
$human_and_hybrid_award_test$;

DO $stage_and_development_cap_test$
DECLARE
  v_result jsonb;
  v_request_id uuid;
  v_rejected boolean;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000001', true
  );
  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid,
    pg_catalog.current_setting('test.m9r5_version_id')::uuid,
    'S1-M4', 2
  );
  IF v_result->>'outcome' <> 'validated' THEN
    RAISE EXCEPTION 'Stage cap request was not objectively validated: %', v_result;
  END IF;
  v_request_id := (v_result->>'request_id')::uuid;
  v_rejected := false;
  BEGIN
    PERFORM public.award_validated_milestone(v_request_id);
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Stage award exceeded the configured stage maximum';
  END IF;

  v_result := public.request_idea_stage_confirmation(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid, 1::smallint
  );
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Stage 1 confirmation request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid, 1::smallint, 2
  );
  IF v_result->>'outcome' <> 'confirmed' THEN
    RAISE EXCEPTION 'Stage 1 confirmation failed: %', v_result;
  END IF;
  v_result := public.save_idea_content(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid,
    'a5200000-0000-4000-8000-000000000003', 2,
    '[{"stage_number":2,"data":{"proof":"Supporting evidence"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied'
     OR v_result->>'result_revision' <> '3' THEN
    RAISE EXCEPTION 'Stage 2 evidence save failed: %', v_result;
  END IF;

  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid,
    pg_catalog.current_setting('test.m9r5_version_id')::uuid,
    'S2-M1', 3
  );
  IF v_result->>'outcome' <> 'validated' THEN
    RAISE EXCEPTION 'Development cap request one failed: %', v_result;
  END IF;
  v_result := public.award_validated_milestone(
    (v_result->>'request_id')::uuid
  );
  IF v_result->>'outcome' <> 'awarded' OR v_result->>'points' <> '5' THEN
    RAISE EXCEPTION 'In-cap Stage 2 award failed: %', v_result;
  END IF;

  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid,
    pg_catalog.current_setting('test.m9r5_version_id')::uuid,
    'S2-M2', 3
  );
  IF v_result->>'outcome' <> 'validated' THEN
    RAISE EXCEPTION 'Development cap request two failed: %', v_result;
  END IF;
  v_rejected := false;
  BEGIN
    PERFORM public.award_validated_milestone(
      (v_result->>'request_id')::uuid
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Development awards exceeded the configured aggregate maximum';
  END IF;
END
$stage_and_development_cap_test$;

DO $award_retry_after_edit_test$
DECLARE
  v_result jsonb;
  v_count bigint;
BEGIN
  v_count := (SELECT pg_catalog.count(*) FROM public.official_points_ledger);
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000001', true
  );
  v_result := public.save_idea_content(
    pg_catalog.current_setting('test.m9r5_idea_id')::uuid,
    'a5200000-0000-4000-8000-000000000004', 3,
    '[{"stage_number":1,"data":{"problem":"Edited after award"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Post-award edit failed: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000002', true
  );
  v_result := public.award_validated_milestone(
    pg_catalog.current_setting('test.m9r5_human_request')::uuid
  );
  IF v_result->>'outcome' <> 'already_awarded' THEN
    RAISE EXCEPTION 'An edit caused a duplicate award or silent reversal: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000001', true
  );
  IF (SELECT pg_catalog.count(*) FROM public.official_points_ledger) <> v_count THEN
    RAISE EXCEPTION 'An edit caused a duplicate award or silent reversal';
  END IF;
END
$award_retry_after_edit_test$;

DO $unvalidated_and_stage_confirmation_test$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_ledger_count bigint;
BEGIN
  v_ledger_count := (SELECT pg_catalog.count(*)
                       FROM public.official_points_ledger);
  v_result := public.create_idea('a5100000-0000-4000-8000-000000000002');
  v_idea_id := (v_result->>'idea_id')::uuid;
  v_result := public.save_idea_content(
    v_idea_id, 'a5200000-0000-4000-8000-000000000002', 1,
    '[{"stage_number":1,"data":{"problem":"No validation"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Unvalidated test evidence was not saved: %', v_result;
  END IF;
  v_result := public.submit_milestone_for_validation(
    v_idea_id, pg_catalog.current_setting('test.m9r5_version_id')::uuid,
    'S1-M1', 2
  );
  IF v_result->>'outcome' <> 'validated' THEN
    RAISE EXCEPTION 'Objective check did not validate the test data: %', v_result;
  END IF;
  v_result := public.award_validated_milestone(
    (v_result->>'request_id')::uuid
  );
  IF v_result->>'outcome' <> 'awarded' THEN
    RAISE EXCEPTION 'Eligible second objective request did not award: %', v_result;
  END IF;

  v_result := public.request_idea_stage_confirmation(v_idea_id, 1::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Stage confirmation request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 1::smallint, 2);
  IF v_result->>'outcome' <> 'confirmed' THEN
    RAISE EXCEPTION 'Stage confirmation failed: %', v_result;
  END IF;
  IF (SELECT pg_catalog.count(*) FROM public.official_points_ledger)
     <> v_ledger_count + 1 THEN
    RAISE EXCEPTION 'Stage confirmation independently generated score points';
  END IF;
END
$unvalidated_and_stage_confirmation_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000003', true
);
DO $correction_and_immutability_test$
DECLARE
  v_award_id uuid := pg_catalog.current_setting('test.m9r5_human_award')::uuid;
  v_result jsonb;
  v_correction_id uuid;
  v_rejected boolean := false;
BEGIN
  v_result := public.correct_score_award(v_award_id, 'Rollback-only M9R5 correction.');
  IF v_result->>'outcome' <> 'corrected' OR v_result->>'points' <> '-18' THEN
    RAISE EXCEPTION 'Authorized correction failed: %', v_result;
  END IF;
  v_correction_id := (v_result->>'entry_id')::uuid;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000001', true
  );
  IF NOT EXISTS (
    SELECT 1
      FROM public.official_points_ledger AS original
      JOIN public.official_points_ledger AS compensation
        ON compensation.original_entry_id = original.entry_id
      WHERE original.entry_id = v_award_id
        AND compensation.entry_id = v_correction_id
        AND compensation.competition_id = original.competition_id
        AND compensation.catalog_version = original.catalog_version
        AND compensation.validation_request_id = original.validation_request_id
        AND compensation.evaluation_level = original.evaluation_level
        AND original.points = 18
        AND compensation.points = -18
  ) THEN
    RAISE EXCEPTION 'Compensation did not preserve original award references';
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000003', true
  );
  v_result := public.correct_score_award(v_award_id, 'Duplicate correction.');
  IF v_result->>'outcome' <> 'already_corrected'
     OR v_result->>'entry_id' <> v_correction_id::text THEN
    RAISE EXCEPTION 'Duplicate correction was not idempotent: %', v_result;
  END IF;
  IF public.correct_score_award(v_award_id, '   ')->>'outcome' <> 'invalid_input' THEN
    RAISE EXCEPTION 'An empty correction reason was accepted';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.official_points_ledger
      SET points = 1
      WHERE entry_id = v_award_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Original ledger award was mutable';
  END IF;
  v_rejected := false;
  BEGIN
    DELETE FROM public.official_points_ledger WHERE entry_id = v_award_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Original ledger award was deletable';
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000002', true
  );
  v_rejected := false;
  BEGIN
    PERFORM public.correct_score_award(v_award_id, 'Unauthorized correction.');
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Validator corrected an award without administrator authority';
  END IF;
END
$correction_and_immutability_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a5000000-0000-4000-8000-000000000004', true
);
DO $private_score_isolation_test$
DECLARE
  v_count integer;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.official_points_ledger;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Another participant read private score ledger rows';
  END IF;
END
$private_score_isolation_test$;

RESET ROLE;
DO $draft_policy_and_award_guard_test$
DECLARE
  v_version_id uuid;
  v_actor_id uuid := 'a5000000-0000-4000-8000-000000000001';
  v_rejected boolean := false;
BEGIN
  SELECT version.id INTO v_version_id
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1;
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_actor_id::text, true);
  BEGIN
    INSERT INTO public.official_points_ledger (
      idempotency_key, user_id, idea_id, configuration_version_id,
      milestone_key, stage_number, entry_kind, points, source,
      source_reference, reason, recorded_by
    )
    VALUES (
      pg_catalog.gen_random_uuid(), v_actor_id,
      'a5100000-0000-4000-8000-000000000003', v_version_id,
      'S1-M1', 1, 'award', 25, 'milestone_validation',
      pg_catalog.gen_random_uuid(), 'Draft configuration must not award.',
      v_actor_id
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Draft Version 1.0 configuration generated an award';
  END IF;
END
$draft_policy_and_award_guard_test$;

ROLLBACK;
