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
  id, configuration_id, version_number
)
VALUES
  (
    'a2200000-0000-4000-8000-000000000001',
    'a2100000-0000-4000-8000-000000000001', 1
  ),
  (
    'a2200000-0000-4000-8000-000000000002',
    'a2100000-0000-4000-8000-000000000002', 1
  );
INSERT INTO public.scoring_milestone_catalog (
  configuration_version_id, milestone_key, stage_number,
  definition, point_value, is_active
)
VALUES
  (
    'a2200000-0000-4000-8000-000000000001',
    'test.approved', 1, 'Rollback-only human review fixture.', 17, true
  ),
  (
    'a2200000-0000-4000-8000-000000000001',
    'test.rejected', 2, 'Rollback-only human review fixture.', 5, true
  ),
  (
    'a2200000-0000-4000-8000-000000000002',
    'test.draft', 1, 'Rollback-only inactive fixture.', 99, true
  );

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
  IF v_queue_count <> 4 THEN
    RAISE EXCEPTION 'Validator queue returned % rows, expected 4 excluding own idea',
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

  v_result := public.validate_milestone(
    v_idea_id,
    'a2200000-0000-4000-8000-000000000001',
    'test.approved', 1, 'approved', 'Evidence reviewed by Validator.'
  );
  IF v_result->>'outcome' <> 'approved' THEN
    RAISE EXCEPTION 'Eligible milestone was not approved: %', v_result;
  END IF;
  v_validation_id := (v_result->>'validation_id')::uuid;
  PERFORM pg_catalog.set_config(
    'test.validation_id', v_validation_id::text, true
  );

  v_result := public.validate_milestone(
    v_idea_id,
    'a2200000-0000-4000-8000-000000000001',
    'test.approved', 1, 'rejected', 'Conflicting duplicate decision.'
  );
  IF v_result->>'outcome' <> 'already_decided'
     OR v_result->>'decision' <> 'approved' THEN
    RAISE EXCEPTION 'Conflicting validation was not prevented: %', v_result;
  END IF;

  v_result := public.validate_milestone(
    v_rejected_idea_id,
    'a2200000-0000-4000-8000-000000000001',
    'test.rejected', 1, 'rejected', 'Evidence did not satisfy definition.'
  );
  IF v_result->>'outcome' <> 'rejected' THEN
    RAISE EXCEPTION 'Eligible milestone rejection failed: %', v_result;
  END IF;
  v_rejected_validation_id := (v_result->>'validation_id')::uuid;
  v_result := public.award_validated_milestone(v_rejected_validation_id);
  IF v_result->>'outcome' <> 'not_approved' THEN
    RAISE EXCEPTION 'Rejected milestone generated an award: %', v_result;
  END IF;

  v_result := public.award_validated_milestone(v_validation_id);
  IF v_result->>'outcome' <> 'awarded' OR v_result->>'points' <> '17' THEN
    RAISE EXCEPTION 'Award did not derive configured points: %', v_result;
  END IF;
  v_entry_id := (v_result->>'entry_id')::uuid;
  PERFORM pg_catalog.set_config('test.award_entry_id', v_entry_id::text, true);

  v_result := public.award_validated_milestone(v_validation_id);
  IF v_result->>'outcome' <> 'already_awarded'
     OR v_result->>'entry_id' <> v_entry_id::text THEN
    RAISE EXCEPTION 'Duplicate award request was not idempotent: %', v_result;
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
  v_result := public.correct_score_award(v_entry_id, 'Rollback-only correction.');
  IF v_result->>'outcome' <> 'corrected' OR v_result->>'points' <> '-17' THEN
    RAISE EXCEPTION 'Scoring Administrator could not compensate award: %',
      v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'test.correction_entry_id', v_result->>'entry_id', true
  );

  v_result := public.correct_score_award(v_entry_id, 'Duplicate correction.');
  IF v_result->>'outcome' <> 'already_corrected' THEN
    RAISE EXCEPTION 'Duplicate correction was not rejected: %', v_result;
  END IF;
  v_result := public.correct_score_award(v_entry_id, '   ');
  IF v_result->>'outcome' <> 'invalid_input' THEN
    RAISE EXCEPTION 'Empty correction reason was accepted: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000004', true
  );
  v_rejected := false;
  BEGIN
    PERFORM public.correct_score_award(v_entry_id, 'Unauthorized correction.');
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Participant created an administrative correction';
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
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000003', true
  );
  v_rejected := false;
  BEGIN
    PERFORM public.award_validated_milestone(v_validation_id);
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Revoked Validator authorization remained usable';
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

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a2000000-0000-4000-8000-000000000002', true
  );
  v_rejected := false;
  BEGIN
    PERFORM public.correct_score_award(v_entry_id, 'Revoked administrator.');
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Revoked Scoring Administrator authorization remained usable';
  END IF;
END
$role_and_workflow_test$;

RESET ROLE;

DO $unique_award_constraints_test$
DECLARE
  v_original public.official_points_ledger%ROWTYPE;
  v_rejected boolean := false;
BEGIN
  SELECT l.* INTO v_original
    FROM public.official_points_ledger AS l
    WHERE l.entry_id = pg_catalog.current_setting('test.award_entry_id')::uuid;

  BEGIN
    INSERT INTO public.official_points_ledger (
      idempotency_key, user_id, idea_id, configuration_version_id,
      milestone_key, stage_number, entry_kind, points,
      source, reason, recorded_by
    )
    VALUES (
      pg_catalog.gen_random_uuid(),
      v_original.user_id,
      v_original.idea_id,
      v_original.configuration_version_id,
      v_original.milestone_key,
      v_original.stage_number,
      'award',
      v_original.points,
      'duplicate_test',
      'Deterministic concurrent-award guard test.',
      v_original.recorded_by
    );
  EXCEPTION WHEN unique_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Natural award uniqueness constraint allowed a duplicate';
  END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.official_points_ledger (
      idempotency_key, user_id, idea_id, configuration_version_id,
      milestone_key, stage_number, entry_kind, points, original_entry_id,
      source, reason, recorded_by
    )
    VALUES (
      pg_catalog.gen_random_uuid(),
      v_original.user_id,
      v_original.idea_id,
      v_original.configuration_version_id,
      v_original.milestone_key,
      v_original.stage_number,
      'compensation',
      -v_original.points,
      v_original.entry_id,
      'duplicate_test',
      'Deterministic duplicate-correction guard test.',
      'a2000000-0000-4000-8000-000000000002'
    );
  EXCEPTION WHEN unique_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Original award accepted more than one correction';
  END IF;
END
$unique_award_constraints_test$;

DO $ledger_audit_test$
DECLARE
  v_original public.official_points_ledger%ROWTYPE;
  v_compensation public.official_points_ledger%ROWTYPE;
  v_count integer;
  v_points bigint;
BEGIN
  SELECT l.* INTO v_original
    FROM public.official_points_ledger AS l
    WHERE l.entry_id = pg_catalog.current_setting('test.award_entry_id')::uuid;
  IF NOT FOUND
     OR v_original.entry_kind <> 'award'
     OR v_original.points <> 17
     OR v_original.user_id <> 'a2000000-0000-4000-8000-000000000004'
     OR v_original.recorded_by <> 'a2000000-0000-4000-8000-000000000003' THEN
    RAISE EXCEPTION 'Award did not preserve derived owner, value, and actor';
  END IF;

  SELECT l.* INTO v_compensation
    FROM public.official_points_ledger AS l
    WHERE l.entry_id = pg_catalog.current_setting('test.correction_entry_id')::uuid;
  IF NOT FOUND
     OR v_compensation.entry_kind <> 'compensation'
     OR v_compensation.original_entry_id <> v_original.entry_id
     OR v_compensation.points <> -v_original.points
     OR v_compensation.recorded_by <> 'a2000000-0000-4000-8000-000000000002'
     OR v_compensation.reason <> 'Rollback-only correction.' THEN
    RAISE EXCEPTION 'Compensating entry is incomplete or does not match the award';
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.official_points_ledger AS l
    WHERE l.idea_id = v_original.idea_id
      AND l.configuration_version_id = v_original.configuration_version_id
      AND l.milestone_key = 'test.rejected';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Rejected milestone has an official ledger entry';
  END IF;

  SELECT pg_catalog.sum(l.points)::bigint INTO v_points
    FROM public.official_points_ledger AS l
    WHERE l.idea_id = v_original.idea_id;
  IF v_points <> 0 THEN
    RAISE EXCEPTION 'Score is not derived from award and compensation entries';
  END IF;

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
$ledger_audit_test$;

ROLLBACK;
