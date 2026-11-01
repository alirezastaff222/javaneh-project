-- Run against an isolated local Supabase database as supabase_admin.
-- All M9R4 fixtures, validation decisions, and events are rolled back.
BEGIN;

DO $m9r4_security_test$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'
        AND relation.relname = 'milestone_validation_requests'
        AND relation.relrowsecurity
        AND relation.relforcerowsecurity
  ) OR NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'
        AND relation.relname = 'milestone_validation_events'
        AND relation.relrowsecurity
        AND relation.relforcerowsecurity
  ) THEN
    RAISE EXCEPTION 'M9R4 validation tables must have forced RLS';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.milestone_validation_requests', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.milestone_validation_requests', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.milestone_validation_events', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.milestone_validations', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'INSERT'
     )
     OR pg_catalog.has_function_privilege(
       'authenticated',
       'public.evaluate_milestone_objective_policy(uuid,uuid,text)',
       'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.submit_milestone_for_validation(uuid,uuid,text,integer)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'M9R4 exposes an authoritative write or internal evaluator';
  END IF;
END
$m9r4_security_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a4000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
    'm9r4-participant-one@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a4000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
    'm9r4-participant-two@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a4000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
    'm9r4-validator@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  );

INSERT INTO public.scoring_role_assignments (user_id, role_name, assigned_by)
VALUES ('a4000000-0000-4000-8000-000000000003', 'validator', NULL);

INSERT INTO public.scoring_configurations (configuration_key)
VALUES ('m9r4-validation-test')
RETURNING id;

DO $seed_validation_configuration$
DECLARE
  v_configuration_id uuid;
  v_version_id uuid;
  v_competition_id uuid;
BEGIN
  SELECT configuration.id INTO v_configuration_id
    FROM public.scoring_configurations AS configuration
    WHERE configuration.configuration_key = 'm9r4-validation-test';
  INSERT INTO public.scoring_configuration_versions (
    configuration_id, version_number, development_max_points, human_jury_max_points,
    overall_max_points, rounding_policy
  )
  VALUES (
    v_configuration_id, 1, 700, 300, 1000, 'floor'
  )
  RETURNING id INTO v_version_id;
  PERFORM pg_catalog.set_config('test.m9r4_version_id', v_version_id::text, true);

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

  INSERT INTO public.competitions (
    competition_key, name, description, status,
    scoring_configuration_version_id, entry_opens_at, entry_closes_at
  )
  VALUES (
    'm9r4-validation-test', 'M9R4 Test Competition',
    'Rollback-only active fixture.', 'active', v_version_id,
    pg_catalog.clock_timestamp() - interval '1 hour',
    pg_catalog.clock_timestamp() + interval '1 day'
  )
  RETURNING id INTO v_competition_id;

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
      v_version_id, 'S1-M1', 1, 'Objective test criterion.', 20, true,
      'm9r4-test', 'Objective test', 'Objective test', 'Objective test',
      'objective',
      '{"objective_checks":[{"stage_number":1,"path":["problem"],"operator":"present"}]}',
      'active', 1, 'approved', NULL, NULL, NULL, NULL, NULL,
      'Rollback-only evidence guidance.', 'Rollback-only objective instructions.'
    ),
    (
      v_version_id, 'S1-M2', 1, 'Human test criterion.', 30, true,
      'm9r4-test', 'Human test', 'Human test', 'Human test',
      'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}',
      'active', 2, 'approved',
      'Test level 0', 'Test level 1', 'Test level 2', 'Test level 3', 'Test level 4',
      'Rollback-only evidence guidance.', 'Rollback-only human instructions.'
    ),
    (
      v_version_id, 'S1-M3', 1, 'Hybrid test criterion.', 30, true,
      'm9r4-test', 'Hybrid test', 'Hybrid test', 'Hybrid test',
      'hybrid',
      '{"objective_checks":[{"stage_number":1,"path":["problem"],"operator":"present"}],"human":{"levels":[0,1,2,3,4]}}',
      'active', 3, 'approved',
      'Test level 0', 'Test level 1', 'Test level 2', 'Test level 3', 'Test level 4',
      'Rollback-only evidence guidance.', 'Rollback-only hybrid instructions.'
    );

  UPDATE public.scoring_configuration_versions
    SET status = 'approved',
        approved_by = 'a4000000-0000-4000-8000-000000000003',
        approved_at = pg_catalog.clock_timestamp()
    WHERE id = v_version_id;
  UPDATE public.scoring_configuration_versions
    SET status = 'active',
        activated_at = pg_catalog.clock_timestamp()
    WHERE id = v_version_id;
END
$seed_validation_configuration$;

SELECT pg_catalog.set_config(
  'test.m9r4_ledger_count',
  (SELECT pg_catalog.count(*)::text FROM public.official_points_ledger),
  true
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000001', true
);

DO $create_participant_ideas$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
BEGIN
  v_result := public.create_idea('a4100000-0000-4000-8000-000000000001');
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r4_objective_idea', v_idea_id::text, true);
  v_result := public.save_idea_content(
    v_idea_id, 'a4200000-0000-4000-8000-000000000001', 1,
    '[{"stage_number":1,"data":{"problem":"Problem statement"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Objective fixture content was not saved: %', v_result;
  END IF;

  v_result := public.create_idea('a4100000-0000-4000-8000-000000000002');
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r4_revision_idea', v_idea_id::text, true);
  v_result := public.save_idea_content(
    v_idea_id, 'a4200000-0000-4000-8000-000000000002', 1,
    '[{"stage_number":1,"data":{"other":"missing problem"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Revision fixture content was not saved: %', v_result;
  END IF;

  v_result := public.create_idea('a4100000-0000-4000-8000-000000000003');
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r4_human_idea', v_idea_id::text, true);
  v_result := public.save_idea_content(
    v_idea_id, 'a4200000-0000-4000-8000-000000000003', 1,
    '[{"stage_number":1,"data":{"problem":"Human review"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Human fixture content was not saved: %', v_result;
  END IF;

END
$create_participant_ideas$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000002', true
);
DO $create_hybrid_ideas$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
BEGIN
  v_result := public.create_idea('a4100000-0000-4000-8000-000000000004');
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r4_hybrid_idea', v_idea_id::text, true);
  v_result := public.save_idea_content(
    v_idea_id, 'a4200000-0000-4000-8000-000000000004', 1,
    '[{"stage_number":1,"data":{"problem":"Hybrid review"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Hybrid fixture content was not saved: %', v_result;
  END IF;

  v_result := public.create_idea('a4100000-0000-4000-8000-000000000006');
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r4_hybrid_failure_idea', v_idea_id::text, true);
  v_result := public.save_idea_content(
    v_idea_id, 'a4200000-0000-4000-8000-000000000007', 1,
    '[{"stage_number":1,"data":{"other":"missing problem"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Hybrid failure fixture content was not saved: %', v_result;
  END IF;
END
$create_hybrid_ideas$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000001', true
);

DO $objective_validation_test$
DECLARE
  v_result jsonb;
  v_request_id uuid;
  v_repeat_id uuid;
  v_revision_idea uuid;
BEGIN
  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r4_objective_idea')::uuid,
    pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'S1-M1', 2
  );
  IF v_result->>'outcome' <> 'validated'
     OR v_result->'objective_result'->>'passed' <> 'true' THEN
    RAISE EXCEPTION 'Deterministic objective validation did not pass: %', v_result;
  END IF;
  v_request_id := (v_result->>'request_id')::uuid;
  IF NOT (public.get_milestone_scoring_eligibility(v_request_id)->>'eligible')::boolean THEN
    RAISE EXCEPTION 'Passing objective validation did not establish eligibility';
  END IF;

  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r4_objective_idea')::uuid,
    pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'S1-M1', 2
  );
  v_repeat_id := (v_result->>'request_id')::uuid;
  IF v_result->>'outcome' <> 'replayed' OR v_repeat_id <> v_request_id
     OR (SELECT pg_catalog.count(*)
         FROM public.milestone_validation_events AS event
         WHERE event.request_id = v_request_id) <> 2 THEN
    RAISE EXCEPTION 'Repeated objective submission created duplicate history: %', v_result;
  END IF;

  v_revision_idea := pg_catalog.current_setting('test.m9r4_revision_idea')::uuid;
  v_result := public.submit_milestone_for_validation(
    v_revision_idea,
    pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'S1-M1', 2
  );
  IF v_result->>'outcome' <> 'needs_revision'
     OR v_result->'objective_result'->>'passed' <> 'false'
     OR (public.get_milestone_scoring_eligibility(
       (v_result->>'request_id')::uuid
     )->>'eligible')::boolean THEN
    RAISE EXCEPTION 'Missing required data passed objective validation: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'test.m9r4_failed_request', v_result->>'request_id', true
  );

  v_result := public.save_idea_content(
    v_revision_idea, 'a4200000-0000-4000-8000-000000000005', 2,
    '[{"stage_number":1,"data":{"problem":"Revised problem"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied'
     OR v_result->>'result_revision' <> '3' THEN
    RAISE EXCEPTION 'Participant could not revise work after failed validation: %', v_result;
  END IF;
  v_result := public.submit_milestone_for_validation(
    v_revision_idea,
    pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'S1-M1', 3
  );
  IF v_result->>'outcome' <> 'validated'
     OR (v_result->>'attempt')::integer <> 2
     OR (SELECT pg_catalog.count(*)
         FROM public.milestone_validation_requests AS request
         WHERE request.idea_id = v_revision_idea
           AND request.milestone_key = 'S1-M1') <> 2 THEN
    RAISE EXCEPTION 'Revalidation did not create a new revision-linked attempt: %', v_result;
  END IF;

END
$objective_validation_test$;

DO $confirmation_is_separate_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r4_objective_idea')::uuid;
  v_result jsonb;
BEGIN
  v_result := public.request_idea_stage_confirmation(v_idea_id, 1::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Stage confirmation request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 1::smallint, 2);
  IF v_result->>'outcome' <> 'confirmed' THEN
    RAISE EXCEPTION 'Stage confirmation failed: %', v_result;
  END IF;
  IF (SELECT pg_catalog.count(*)
        FROM public.milestone_validation_requests AS request
        WHERE request.idea_id = v_idea_id) <> 1 THEN
    RAISE EXCEPTION 'Stage confirmation created a milestone validation request';
  END IF;
END
$confirmation_is_separate_test$;

DO $unauthorized_validation_test$
DECLARE
  v_result jsonb;
  v_rejected boolean := false;
BEGIN
  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r4_human_idea')::uuid,
    pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'S1-M2', 2
  );
  PERFORM pg_catalog.set_config('test.m9r4_human_request', v_result->>'request_id', true);
  BEGIN
    PERFORM public.validate_milestone_request(
      (v_result->>'request_id')::uuid, 'validated', 3::smallint,
      'Participant cannot perform human validation.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Participant performed human milestone validation';
  END IF;
END
$unauthorized_validation_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000003', true
);

DO $human_and_hybrid_validation_test$
DECLARE
  v_result jsonb;
  v_human_request uuid;
  v_hybrid_request uuid;
  v_failed_hybrid jsonb;
  v_rejected boolean := false;
  v_count integer;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.get_milestone_validation_queue() AS queue;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Validator queue did not return the eligible pending work: %', v_count;
  END IF;

  v_human_request := pg_catalog.current_setting('test.m9r4_human_request')::uuid;
  v_result := public.validate_milestone_request(
    v_human_request, 'needs_revision', 2::smallint, 'Please improve the explanation.'
  );
  IF v_result->>'outcome' <> 'needs_revision' THEN
    RAISE EXCEPTION 'Human revision decision failed: %', v_result;
  END IF;
  v_result := public.validate_milestone_request(
    v_human_request, 'validated', 3::smallint, 'Duplicate decision attempt.'
  );
  IF v_result->>'outcome' <> 'invalid_state' THEN
    RAISE EXCEPTION 'Terminal validation request accepted a duplicate decision: %', v_result;
  END IF;
  IF (public.get_milestone_scoring_eligibility(v_human_request)->>'eligible')::boolean THEN
    RAISE EXCEPTION 'Needs-revision decision established scoring eligibility';
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000002', true
  );
  v_result := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r4_hybrid_idea')::uuid,
    pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'S1-M3', 2
  );
  IF v_result->>'outcome' <> 'pending_validation'
     OR v_result->'objective_result'->>'passed' <> 'true'
     OR (public.get_milestone_scoring_eligibility(
       (v_result->>'request_id')::uuid
     )->>'eligible')::boolean THEN
    RAISE EXCEPTION 'Partial hybrid validation was incorrectly eligible: %', v_result;
  END IF;
  v_hybrid_request := (v_result->>'request_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r4_hybrid_request', v_hybrid_request::text, true);
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000003', true
  );
  v_result := public.validate_milestone_request(
    v_hybrid_request, 'validated', 4::smallint, 'Human component passed.'
  );
  IF v_result->>'outcome' <> 'validated'
     OR NOT (public.get_milestone_scoring_eligibility(
       v_hybrid_request
     )->>'eligible')::boolean THEN
    RAISE EXCEPTION 'Completed hybrid validation did not establish eligibility: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000002', true
  );
  v_failed_hybrid := public.submit_milestone_for_validation(
    pg_catalog.current_setting('test.m9r4_hybrid_failure_idea')::uuid,
    pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'S1-M3', 2
  );
  IF v_failed_hybrid->>'outcome' <> 'needs_revision' THEN
    RAISE EXCEPTION 'Failed hybrid objective checks did not require revision: %',
      v_failed_hybrid;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000003', true
  );
  v_result := public.validate_milestone_request(
    (v_failed_hybrid->>'request_id')::uuid, 'validated', 4::smallint,
    'Must not bypass failed objective checks.'
  );
  IF v_result->>'outcome' <> 'invalid_state' THEN
    RAISE EXCEPTION 'Human validation bypassed failed hybrid objective checks';
  END IF;
END
$human_and_hybrid_validation_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000001', true
);
DO $human_revalidation_submission$
DECLARE
  v_result jsonb;
  v_idea_id uuid := pg_catalog.current_setting('test.m9r4_human_idea')::uuid;
BEGIN
  v_result := public.save_idea_content(
    v_idea_id, 'a4200000-0000-4000-8000-000000000008', 2,
    '[{"stage_number":1,"data":{"problem":"Improved human review"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Participant could not revise human-reviewed work: %', v_result;
  END IF;
  v_result := public.submit_milestone_for_validation(
    v_idea_id, pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'S1-M2', 3
  );
  IF v_result->>'outcome' <> 'pending_validation' THEN
    RAISE EXCEPTION 'Human revalidation submission failed: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config('test.m9r4_human_retry', v_result->>'request_id', true);
END
$human_revalidation_submission$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000003', true
);
DO $human_revalidation_decision$
DECLARE
  v_request_id uuid := pg_catalog.current_setting('test.m9r4_human_retry')::uuid;
  v_idea_id uuid := pg_catalog.current_setting('test.m9r4_human_idea')::uuid;
  v_result jsonb;
BEGIN
  v_result := public.validate_milestone_request(
    v_request_id, 'validated', 3::smallint, 'Revised work satisfies the criterion.'
  );
  IF v_result->>'outcome' <> 'validated'
     OR NOT (public.get_milestone_scoring_eligibility(
       v_request_id
     )->>'eligible')::boolean THEN
    RAISE EXCEPTION 'Revised human validation did not pass: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000001', true
  );
  IF (SELECT pg_catalog.count(*)
           FROM public.milestone_validation_requests AS request
           WHERE request.idea_id = v_idea_id
             AND request.milestone_key = 'S1-M2') <> 2
     OR (SELECT pg_catalog.count(*)
           FROM public.milestone_validation_requests AS request
           WHERE request.idea_id = v_idea_id
             AND request.milestone_key = 'S1-M2'
             AND request.status = 'needs_revision') <> 1 THEN
    RAISE EXCEPTION 'Revalidation overwrote or lost the prior decision';
  END IF;
END
$human_revalidation_decision$;

DO $self_validation_test$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_rejected boolean := false;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000003', true
  );
  v_result := public.create_idea('a4100000-0000-4000-8000-000000000005');
  v_idea_id := (v_result->>'idea_id')::uuid;
  v_result := public.save_idea_content(
    v_idea_id, 'a4200000-0000-4000-8000-000000000006', 1,
    '[{"stage_number":1,"data":{"problem":"Validator own idea"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Validator-owned test content was not saved: %', v_result;
  END IF;
  v_result := public.submit_milestone_for_validation(
    v_idea_id, pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'S1-M2', 2
  );
  IF v_result->>'outcome' <> 'pending_validation' THEN
    RAISE EXCEPTION 'Validator-owned test submission failed: %', v_result;
  END IF;
  BEGIN
    PERFORM public.validate_milestone_request(
      (v_result->>'request_id')::uuid, 'validated', 3::smallint,
      'Self validation must be rejected.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Validator validated their own qualitative milestone';
  END IF;
END
$self_validation_test$;

DO $award_and_isolation_test$
BEGIN
  IF (SELECT pg_catalog.count(*) FROM public.official_points_ledger)
     <> pg_catalog.current_setting('test.m9r4_ledger_count')::bigint THEN
    RAISE EXCEPTION 'Validation and eligibility checks wrote an official award';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_configuration_versions', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_milestone_catalog', 'UPDATE'
     ) THEN
    RAISE EXCEPTION 'Validator can directly modify scoring configuration';
  END IF;
END
$award_and_isolation_test$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a4000000-0000-4000-8000-000000000004', true
);
DO $cross_user_isolation_test$
DECLARE
  v_count integer;
  v_rejected boolean := false;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.milestone_validation_requests;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Participant read another user''s validation request';
  END IF;

  BEGIN
    PERFORM public.get_milestone_scoring_eligibility(
      pg_catalog.current_setting('test.m9r4_hybrid_request')::uuid
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Participant inspected another user''s validation outcome';
  END IF;
END
$cross_user_isolation_test$;

ROLLBACK;
