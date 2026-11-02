-- Run against an isolated local Supabase database as supabase_admin.
-- All users, roles, ideas, decisions, awards, and corrections are rolled back.
BEGIN;

DO $security_test$
DECLARE
  v_count integer;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN (
        'scoring_role_assignments',
        'scoring_role_audit',
        'scoring_configuration_events',
        'milestone_validations'
      )
      AND c.relkind = 'r'
      AND c.relrowsecurity
      AND c.relforcerowsecurity;
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'All operations tables must have forced RLS';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_role_assignments', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_role_assignments', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.milestone_validations', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.official_points_ledger', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'javaneh_identity_executor', 'public.official_points_ledger', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'javaneh_identity_executor', 'public.official_points_ledger', 'DELETE'
     ) THEN
    RAISE EXCEPTION 'Client or executor has unapproved authoritative write access';
  END IF;

  IF pg_catalog.has_function_privilege(
       'anon', 'public.manage_scoring_role(uuid,text,text,text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'service_role', 'public.correct_score_award(uuid,text)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.validate_milestone(uuid,uuid,text,integer,text,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Privileged RPC execution grants are too broad or incomplete';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_catalog.pg_roles AS r
      WHERE r.rolname IN ('anon', 'authenticated', 'service_role', 'authenticator')
        AND pg_catalog.pg_has_role(
          r.rolname, 'javaneh_identity_executor', 'MEMBER'
        )
  ) THEN
    RAISE EXCEPTION 'A client-facing role can assume the restricted executor';
  END IF;
END
$security_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a2000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
    'm9r2-owner@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a2000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
    'm9r2-admin@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a2000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
    'm9r2-validator@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a2000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated',
    'm9r2-participant@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  );

INSERT INTO public.scoring_role_assignments (
  user_id, role_name, assigned_by
)
VALUES (
  'a2000000-0000-4000-8000-000000000001', 'platform_owner', NULL
);
INSERT INTO public.scoring_role_audit (
  event_type, role_name, actor_user_id, target_user_id, reason
)
VALUES (
  'bootstrap_owner', 'platform_owner', NULL,
  'a2000000-0000-4000-8000-000000000001',
  'Rollback-only test bootstrap.'
);

INSERT INTO public.scoring_configurations (id, competition_id)
VALUES
  ('a2100000-0000-4000-8000-000000000001', NULL),
  ('a2100000-0000-4000-8000-000000000002', NULL);
INSERT INTO public.scoring_configuration_versions (
  id, configuration_id, version_number,
  development_max_points, human_jury_max_points, overall_max_points,
  rounding_policy
)
VALUES
  (
    'a2200000-0000-4000-8000-000000000001',
    'a2100000-0000-4000-8000-000000000001', 1, 700, 300, 1000, 'floor'
  ),
  (
    'a2200000-0000-4000-8000-000000000002',
    'a2100000-0000-4000-8000-000000000002', 1, 700, 300, 1000, 'floor'
  );
INSERT INTO public.scoring_stage_catalog (
  configuration_version_id, stage_number, display_name, stage_kind,
  maximum_points, sort_order
)
VALUES
  ('a2200000-0000-4000-8000-000000000001', 1, 'Test Stage 1', 'development', 80, 1),
  ('a2200000-0000-4000-8000-000000000001', 2, 'Test Stage 2', 'development', 100, 2),
  ('a2200000-0000-4000-8000-000000000001', 3, 'Test Stage 3', 'development', 140, 3),
  ('a2200000-0000-4000-8000-000000000001', 4, 'Test Stage 4', 'development', 140, 4),
  ('a2200000-0000-4000-8000-000000000001', 5, 'Test Stage 5', 'development', 120, 5),
  ('a2200000-0000-4000-8000-000000000001', 6, 'Test Stage 6', 'development', 120, 6),
  ('a2200000-0000-4000-8000-000000000001', 7, 'Test Stage 7', 'human_jury', 300, 7);
INSERT INTO public.scoring_evaluation_levels (
  configuration_version_id, evaluation_level, display_label, multiplier,
  general_description
)
VALUES
  ('a2200000-0000-4000-8000-000000000001', 0, 'Not achieved', 0.00, 'Not achieved.'),
  ('a2200000-0000-4000-8000-000000000001', 1, 'Very limited', 0.25, 'Very limited.'),
  ('a2200000-0000-4000-8000-000000000001', 2, 'Developing', 0.50, 'Developing.'),
  ('a2200000-0000-4000-8000-000000000001', 3, 'Satisfactory', 0.75, 'Satisfactory.'),
  ('a2200000-0000-4000-8000-000000000001', 4, 'Fully achieved and supported', 1.00, 'Fully achieved.');
INSERT INTO public.scoring_milestone_catalog (
  configuration_version_id, milestone_key, stage_number, definition,
  point_value, is_active, catalog_version, display_name,
  participant_description, evaluator_description, validation_mode,
  validation_policy, catalog_status, sort_order, descriptor_status,
  evaluator_instructions, level_0_description, level_1_description,
  level_2_description, level_3_description, level_4_description,
  evidence_guidance
)
VALUES
  ('a2200000-0000-4000-8000-000000000001', 'test.approved', 1, 'Rollback-only human review fixture.', 17, false, NULL, 'Approved test', 'Approved test', 'Approved test', 'objective', '{"objective_checks":[]}', NULL, NULL, NULL, 'Review the submitted evidence.', NULL, NULL, NULL, NULL, NULL, NULL),
  ('a2200000-0000-4000-8000-000000000001', 'test.stage1-cap', 1, 'Rollback-only cap fixture.', 63, false, 'm9r2-test-v1', 'Stage 1 cap', 'Stage 1 cap', 'Stage 1 cap', 'objective', '{"objective_checks":[]}', 'approved', 2, 'approved', 'Review the submitted evidence.', NULL, NULL, NULL, NULL, NULL, NULL),
  ('a2200000-0000-4000-8000-000000000001', 'test.rejected', 2, 'Rollback-only human review fixture.', 5, false, NULL, 'Rejected test', 'Rejected test', 'Rejected test', 'objective', '{"objective_checks":[]}', NULL, NULL, NULL, 'Review the submitted evidence.', NULL, NULL, NULL, NULL, NULL, NULL),
  ('a2200000-0000-4000-8000-000000000001', 'test.stage2-cap', 2, 'Rollback-only cap fixture.', 95, false, 'm9r2-test-v1', 'Stage 2 cap', 'Stage 2 cap', 'Stage 2 cap', 'objective', '{"objective_checks":[]}', 'approved', 2, 'approved', 'Review the submitted evidence.', NULL, NULL, NULL, NULL, NULL, NULL),
  ('a2200000-0000-4000-8000-000000000001', 'test.stage3-cap', 3, 'Rollback-only cap fixture.', 140, false, 'm9r2-test-v1', 'Stage 3 cap', 'Stage 3 cap', 'Stage 3 cap', 'objective', '{"objective_checks":[]}', 'approved', 1, 'approved', 'Review the submitted evidence.', NULL, NULL, NULL, NULL, NULL, NULL),
  ('a2200000-0000-4000-8000-000000000001', 'test.stage4-cap', 4, 'Rollback-only cap fixture.', 140, false, 'm9r2-test-v1', 'Stage 4 cap', 'Stage 4 cap', 'Stage 4 cap', 'objective', '{"objective_checks":[]}', 'approved', 1, 'approved', 'Review the submitted evidence.', NULL, NULL, NULL, NULL, NULL, NULL),
  ('a2200000-0000-4000-8000-000000000001', 'test.stage5-cap', 5, 'Rollback-only cap fixture.', 120, false, 'm9r2-test-v1', 'Stage 5 cap', 'Stage 5 cap', 'Stage 5 cap', 'objective', '{"objective_checks":[]}', 'approved', 1, 'approved', 'Review the submitted evidence.', NULL, NULL, NULL, NULL, NULL, NULL),
  ('a2200000-0000-4000-8000-000000000001', 'test.stage6-cap', 6, 'Rollback-only cap fixture.', 120, false, 'm9r2-test-v1', 'Stage 6 cap', 'Stage 6 cap', 'Stage 6 cap', 'objective', '{"objective_checks":[]}', 'approved', 1, 'approved', 'Review the submitted evidence.', NULL, NULL, NULL, NULL, NULL, NULL);
INSERT INTO public.competitions (
  competition_key, name, description, status,
  scoring_configuration_version_id, entry_opens_at, entry_closes_at
)
VALUES (
  'm9r2-operations-test', 'M9R2 Operations Test',
  'Rollback-only operations fixture.', 'draft',
  'a2200000-0000-4000-8000-000000000001',
  pg_catalog.clock_timestamp() - interval '1 hour',
  pg_catalog.clock_timestamp() + interval '1 day'
);
SELECT pg_catalog.set_config(
  'test.m9r2_competition_id',
  competition.id::text,
  true
)
FROM public.competitions AS competition
WHERE competition.competition_key = 'm9r2-operations-test';

SET LOCAL ROLE authenticated;

DO $role_and_workflow_test$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_rejected_idea_id uuid;
  v_validator_idea_id uuid;
  v_validation_id uuid;
  v_rejected_validation_id uuid;
  v_entry_id uuid;
  v_rejected boolean;
  v_queue_count integer;
  v_competition_id uuid;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000001', true
  );
  v_result := public.manage_scoring_role(
    'a2000000-0000-4000-8000-000000000002',
    'scoring_administrator', 'grant', 'Assign scoring administrator.'
  );
  IF v_result->>'outcome' <> 'granted' THEN
    RAISE EXCEPTION 'Platform Owner could not assign Scoring Administrator: %',
      v_result;
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.manage_scoring_role(
      'a2000000-0000-4000-8000-000000000004',
      'platform_owner', 'grant', 'Must not grant Platform Owner.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Platform Owner assignment was exposed through the RPC';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.manage_scoring_role(
      'a2000000-0000-4000-8000-000000000001',
      'scoring_administrator', 'grant', 'Self-assignment attempt.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A user could assign a privileged role to themselves';
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000002', true
  );
  v_result := public.manage_scoring_role(
    'a2000000-0000-4000-8000-000000000003',
    'validator', 'grant', 'Assign milestone Validator.'
  );
  IF v_result->>'outcome' <> 'granted' THEN
    RAISE EXCEPTION 'Scoring Administrator could not assign Validator: %',
      v_result;
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.manage_scoring_role(
      'a2000000-0000-4000-8000-000000000004',
      'platform_owner', 'grant', 'Scoring Administrator escalation attempt.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Scoring Administrator appointed a Platform Owner';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.manage_scoring_role(
      'a2000000-0000-4000-8000-000000000004',
      'scoring_administrator', 'grant', 'Must not grant Scoring Administrator.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Scoring Administrator appointed another Scoring Administrator';
  END IF;

  v_result := public.approve_scoring_configuration_version(
    'a2200000-0000-4000-8000-000000000001',
    'Approve rollback-only configuration.'
  );
  IF v_result->>'outcome' <> 'approved' THEN
    RAISE EXCEPTION 'Scoring Administrator could not approve configuration: %',
      v_result;
  END IF;
  v_result := public.activate_scoring_configuration_version(
    'a2200000-0000-4000-8000-000000000001',
    'Activate rollback-only configuration.'
  );
  IF v_result->>'outcome' <> 'activated' THEN
    RAISE EXCEPTION 'Scoring Administrator could not activate configuration: %',
      v_result;
  END IF;
  v_competition_id := pg_catalog.current_setting(
    'test.m9r2_competition_id'
  )::uuid;
  v_result := public.set_competition_status(
    v_competition_id, 'active', 'Activate rollback-only operations competition.'
  );
  IF v_result->>'outcome' <> 'active' THEN
    RAISE EXCEPTION 'Operations test competition could not activate: %',
      v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000004', true
  );
  v_rejected := false;
  BEGIN
    PERFORM public.manage_scoring_role(
      'a2000000-0000-4000-8000-000000000003',
      'validator', 'grant', 'Participant role grant attempt.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Participant granted a privileged role';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.approve_scoring_configuration_version(
      'a2200000-0000-4000-8000-000000000002',
      'Unauthorized approval attempt.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Participant approved a scoring configuration';
  END IF;

  v_result := public.create_idea('a2300000-0000-4000-8000-000000000001');
  v_idea_id := (v_result->>'idea_id')::uuid;
  v_result := public.create_idea('a2300000-0000-4000-8000-000000000002');
  v_rejected_idea_id := (v_result->>'idea_id')::uuid;
  IF v_idea_id IS NULL OR v_rejected_idea_id IS NULL THEN
    RAISE EXCEPTION 'Test participant ideas were not created';
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000002', true
  );
  v_result := public.assign_idea_competition(v_idea_id, v_competition_id);
  IF v_result->>'outcome' <> 'assigned' THEN
    RAISE EXCEPTION 'Operations test idea assignment failed: %', v_result;
  END IF;
  v_result := public.assign_idea_competition(v_rejected_idea_id, v_competition_id);
  IF v_result->>'outcome' <> 'assigned' THEN
    RAISE EXCEPTION 'Operations rejected-idea assignment failed: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000004', true
  );

  v_rejected := false;
  BEGIN
    PERFORM public.validate_milestone(
      v_idea_id,
      'a2200000-0000-4000-8000-000000000001',
      'test.approved', 1, 'approved', 'Unauthorized validation attempt.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Participant validated a milestone';
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000003', true
  );
  v_result := public.create_idea('a2300000-0000-4000-8000-000000000003');
  v_validator_idea_id := (v_result->>'idea_id')::uuid;
  IF v_validator_idea_id IS NULL THEN
    RAISE EXCEPTION 'Validator self-ownership test idea was not created';
  END IF;

  SELECT pg_catalog.count(*) INTO v_queue_count
    FROM public.get_milestone_review_queue() AS q;
  IF v_queue_count <> 12 THEN
    RAISE EXCEPTION 'Validator queue returned % rows, expected 12 excluding own idea',
      v_queue_count;
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.validate_milestone(
      v_validator_idea_id,
      'a2200000-0000-4000-8000-000000000001',
      'test.approved', 1, 'approved', 'Self-validation attempt.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Validator approved their own idea';
  END IF;

  v_result := public.validate_milestone(
    v_idea_id,
    'a2200000-0000-4000-8000-000000000002',
    'test.draft', 1, 'approved', 'Inactive configuration attempt.'
  );
  IF v_result->>'outcome' <> 'not_eligible' THEN
    RAISE EXCEPTION 'Inactive configuration was eligible: %', v_result;
  END IF;

  v_rejected := false;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000004', true
  );
  BEGIN
    PERFORM public.get_milestone_review_queue();
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Participant accessed the Validator review queue';
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000002', true
  );
  v_result := public.manage_scoring_role(
    'a2000000-0000-4000-8000-000000000003',
    'validator', 'revoke', 'Revoke Validator for authorization test.'
  );
  IF v_result->>'outcome' <> 'revoked' THEN
    RAISE EXCEPTION 'Scoring Administrator could not revoke Validator: %',
      v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000001', true
  );
  v_rejected := false;
  BEGIN
    PERFORM public.manage_scoring_role(
      'a2000000-0000-4000-8000-000000000003',
      'validator', 'revoke', 'Platform Owner cannot manage Validators.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Platform Owner bypassed Validator administration hierarchy';
  END IF;

  v_result := public.manage_scoring_role(
    'a2000000-0000-4000-8000-000000000002',
    'scoring_administrator', 'revoke', 'Revoke Scoring Administrator.'
  );
  IF v_result->>'outcome' <> 'revoked' THEN
    RAISE EXCEPTION 'Platform Owner could not revoke Scoring Administrator: %',
      v_result;
  END IF;

END
$role_and_workflow_test$;

RESET ROLE;
DO $operations_audit_test$
DECLARE
  v_count integer;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.scoring_role_audit AS a
    WHERE a.target_user_id IN (
      'a2000000-0000-4000-8000-000000000002',
      'a2000000-0000-4000-8000-000000000003'
    );
  IF v_count < 4 THEN
    RAISE EXCEPTION 'Role grant and revocation actions were not audited';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.scoring_configuration_events AS e
      WHERE e.configuration_version_id =
        'a2200000-0000-4000-8000-000000000001'
        AND e.actor_user_id <> 'a2000000-0000-4000-8000-000000000002'
  ) OR (
    SELECT pg_catalog.count(*)
      FROM public.scoring_configuration_events AS e
      WHERE e.configuration_version_id =
        'a2200000-0000-4000-8000-000000000001'
  ) <> 2 THEN
    RAISE EXCEPTION 'Configuration approval/activation audit is incomplete';
  END IF;
END
$operations_audit_test$;

ROLLBACK;
