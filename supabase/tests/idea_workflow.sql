-- Run against an isolated local Supabase database as supabase_admin.
-- All users, ideas, submissions, and deletion events are rolled back.
BEGIN;

DO $m9r8_security_test$
BEGIN
  IF pg_catalog.to_regclass('public.idea_sessions') IS NOT NULL
     OR NOT pg_catalog.has_table_privilege(
       'authenticated', 'public.ideas', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.ideas', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.ideas', 'DELETE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.submit_idea(uuid,uuid,integer)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.submit_idea(uuid,uuid,integer)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'service_role', 'public.submit_idea(uuid,uuid,integer)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.set_idea_current_step(uuid,smallint)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.set_idea_current_step(uuid,smallint)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Idea workflow grants or existing-model assumptions changed';
  END IF;
END
$m9r8_security_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a9000000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', 'm9r8-owner-a@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9000000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', 'm9r8-owner-b@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  );

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9000000-0000-4000-8000-000000000001', true
);

DO $m9r8_draft_lifecycle_test$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_revision integer;
  v_rejected boolean;
BEGIN
  v_result := public.create_idea('a9100000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Draft creation failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;

  IF (SELECT idea.current_step
        FROM public.ideas AS idea
        WHERE idea.id = v_idea_id) <> 1 THEN
    RAISE EXCEPTION 'New draft did not start at step 1';
  END IF;
  v_result := public.set_idea_current_step(v_idea_id, 2::smallint);
  IF v_result->>'outcome' <> 'invalid_state' THEN
    RAISE EXCEPTION 'A locked wizard step became selectable: %', v_result;
  END IF;
  v_result := public.set_idea_current_step(v_idea_id, 8::smallint);
  IF v_result->>'outcome' <> 'invalid_input' THEN
    RAISE EXCEPTION 'Out-of-range current step was accepted: %', v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_id, 'a9200000-0000-4000-8000-000000000001', 1,
    '[{"stage_number":1,"data":{"content":"first durable draft"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Draft save failed: %', v_result;
  END IF;
  v_revision := (v_result->>'result_revision')::integer;

  IF (
    SELECT stage.data->>'content'
      FROM public.idea_stages AS stage
      WHERE stage.idea_id = v_idea_id AND stage.stage_number = 1
  ) <> 'first durable draft' THEN
    RAISE EXCEPTION 'Saved draft payload was not retrievable';
  END IF;
  IF (SELECT idea.current_step
        FROM public.ideas AS idea
        WHERE idea.id = v_idea_id) <> 1 THEN
    RAISE EXCEPTION 'Draft retrieval changed the persisted current step';
  END IF;

  v_result := public.request_idea_stage_confirmation(v_idea_id, 1::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Stage 1 confirmation request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 1::smallint, v_revision);
  IF v_result->>'outcome' <> 'confirmed' THEN
    RAISE EXCEPTION 'Stage 1 confirmation failed: %', v_result;
  END IF;
  IF (SELECT idea.current_step
        FROM public.ideas AS idea
        WHERE idea.id = v_idea_id) <> 2 THEN
    RAISE EXCEPTION 'Confirmation did not advance the persisted step';
  END IF;
  v_result := public.set_idea_current_step(v_idea_id, 2::smallint);
  IF v_result->>'outcome' <> 'already_current'
     OR v_result->>'current_step' <> '2'
     OR (SELECT idea.current_step
           FROM public.ideas AS idea
           WHERE idea.id = v_idea_id) <> 2 THEN
    RAISE EXCEPTION 'Current wizard step was not durably updated: %', v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_id, 'a9200000-0000-4000-8000-000000000002', v_revision,
    '[{"stage_number":1,"data":{"content":"second durable draft"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Confirmed-stage edit failed: %', v_result;
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.save_idea_content(
      v_idea_id, 'a9200000-0000-4000-8000-000000000003',
      (v_result->>'result_revision')::integer,
      '[{"stage_number":1,"data":{"content":42}}]'::jsonb
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Server accepted a non-text wizard content payload';
  END IF;
  PERFORM pg_catalog.set_config(
    'test.m9r8_delete_idea', v_idea_id::text, true
  );
END
$m9r8_draft_lifecycle_test$;

RESET ROLE;
DO $m9r8_snapshot_test$
BEGIN
  IF (
    SELECT pg_catalog.count(*)
      FROM public.idea_stage_confirmed_versions AS snapshot
      WHERE snapshot.idea_id =
        pg_catalog.current_setting('test.m9r8_delete_idea')::uuid
        AND snapshot.stage_number = 1
  ) <> 1 THEN
    RAISE EXCEPTION 'Confirmed draft edit did not preserve its existing snapshot';
  END IF;
END
$m9r8_snapshot_test$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9000000-0000-4000-8000-000000000002', true
);
DO $m9r8_ownership_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r8_delete_idea')::uuid;
  v_result jsonb;
  v_count integer;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas AS idea
    WHERE idea.id = v_idea_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Other participant read a private idea';
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = v_idea_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Other participant read private draft content';
  END IF;
  v_result := public.delete_own_idea(v_idea_id);
  IF v_result->>'outcome' <> 'not_found_or_already_deleted' THEN
    RAISE EXCEPTION 'Other participant deleted an idea: %', v_result;
  END IF;
  v_result := public.submit_idea(
    v_idea_id, 'a9250000-0000-4000-8000-000000000001', 1
  );
  IF v_result->>'outcome' <> 'not_found_or_not_owned' THEN
    RAISE EXCEPTION 'Other participant submitted an idea: %', v_result;
  END IF;
  v_result := public.set_idea_current_step(v_idea_id, 1::smallint);
  IF v_result->>'outcome' <> 'not_found_or_not_owned' THEN
    RAISE EXCEPTION 'Other participant changed the persisted step: %', v_result;
  END IF;
END
$m9r8_ownership_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9000000-0000-4000-8000-000000000001', true
);
DO $m9r8_deletion_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r8_delete_idea')::uuid;
  v_result jsonb;
  v_replacement_id uuid;
  v_count integer;
BEGIN
  v_result := public.delete_own_idea(v_idea_id);
  IF v_result->>'outcome' <> 'deleted' THEN
    RAISE EXCEPTION 'Owned draft deletion failed: %', v_result;
  END IF;
  v_result := public.delete_own_idea(v_idea_id);
  IF v_result->>'outcome' <> 'not_found_or_already_deleted' THEN
    RAISE EXCEPTION 'Repeated deletion did not return an idempotent result: %',
      v_result;
  END IF;
  v_result := public.create_idea('a9100000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'already_deleted' THEN
    RAISE EXCEPTION 'Deleted creation identity was reused: %', v_result;
  END IF;
  v_result := public.create_idea('a9100000-0000-4000-8000-000000000002');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Deletion did not release an active-idea slot: %', v_result;
  END IF;
  v_replacement_id := (v_result->>'idea_id')::uuid;
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas AS idea
    WHERE idea.owner_id = 'a9000000-0000-4000-8000-000000000001';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Unexpected remaining active idea count: %', v_count;
  END IF;
  PERFORM pg_catalog.set_config(
    'test.m9r8_replacement_idea', v_replacement_id::text, true
  );
END
$m9r8_deletion_test$;

RESET ROLE;
DO $m9r8_deletion_cleanup_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r8_delete_idea')::uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM public.ideas WHERE id = v_idea_id)
     OR EXISTS (SELECT 1 FROM public.idea_stages WHERE idea_id = v_idea_id)
     OR EXISTS (
       SELECT 1 FROM public.idea_stage_confirmed_versions
       WHERE idea_id = v_idea_id
     )
     OR EXISTS (
       SELECT 1 FROM public.idea_save_requests WHERE idea_id = v_idea_id
     ) THEN
    RAISE EXCEPTION 'Permanent deletion left substantive draft records';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.idea_deletion_audit AS audit
      WHERE audit.deleted_idea_id = v_idea_id
        AND audit.actor_id = 'a9000000-0000-4000-8000-000000000001'
        AND audit.operation = 'participant_delete'
        AND audit.reason_code = 'participant_requested_deletion'
  ) OR EXISTS (
    SELECT 1
      FROM pg_catalog.pg_attribute AS attribute
      WHERE attribute.attrelid = 'public.idea_deletion_audit'::regclass
        AND attribute.attname IN ('data', 'content', 'payload')
        AND NOT attribute.attisdropped
  ) THEN
    RAISE EXCEPTION 'Deletion audit is missing or retains substantive content';
  END IF;
END
$m9r8_deletion_cleanup_test$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9000000-0000-4000-8000-000000000002', true
);
DO $m9r8_create_quota_test$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_count integer;
BEGIN
  v_result := public.create_idea('a9300000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'First quota idea failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;
  v_result := public.create_idea('a9300000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'already_exists'
     OR (v_result->>'idea_id')::uuid <> v_idea_id THEN
    RAISE EXCEPTION 'Creation retry was not idempotent: %', v_result;
  END IF;
  v_result := public.create_idea('a9300000-0000-4000-8000-000000000002');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Second quota idea failed: %', v_result;
  END IF;
  v_result := public.create_idea('a9300000-0000-4000-8000-000000000003');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Third quota idea failed: %', v_result;
  END IF;
  v_result := public.create_idea('a9300000-0000-4000-8000-000000000004');
  IF v_result->>'outcome' <> 'quota_exceeded' THEN
    RAISE EXCEPTION 'Fourth active idea was accepted: %', v_result;
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas AS idea
    WHERE idea.owner_id = 'a9000000-0000-4000-8000-000000000002';
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'Quota count is % after fourth request', v_count;
  END IF;
END
$m9r8_create_quota_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9000000-0000-4000-8000-000000000001', true
);
DO $m9r8_submission_fixture_test$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_revision integer;
  v_stage smallint;
  v_request_id uuid := 'a9400000-0000-4000-8000-000000000001';
BEGIN
  v_result := public.create_idea('a9500000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Submission test idea creation failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config(
    'test.m9r8_submission_idea', v_idea_id::text, true
  );
  v_result := public.save_idea_content(
    v_idea_id, 'a9600000-0000-4000-8000-000000000001', 1,
    '[{"stage_number":1,"data":{"content":"saved before submission"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Submission draft save failed: %', v_result;
  END IF;
  v_revision := (v_result->>'result_revision')::integer;

  v_result := public.submit_idea(v_idea_id, v_request_id, v_revision);
  IF v_result->>'outcome' <> 'incomplete' THEN
    RAISE EXCEPTION 'Incomplete draft was submitted: %', v_result;
  END IF;
  IF (SELECT idea.status FROM public.ideas AS idea
      WHERE idea.id = v_idea_id) <> 'in_progress'
     OR (SELECT stage.data->>'content'
           FROM public.idea_stages AS stage
           WHERE stage.idea_id = v_idea_id AND stage.stage_number = 1)
       <> 'saved before submission' THEN
    RAISE EXCEPTION 'Failed submission changed or lost the saved draft';
  END IF;

  FOR v_stage IN 1..6 LOOP
    v_result := public.request_idea_stage_confirmation(
      v_idea_id, v_stage::smallint
    );
    IF v_result->>'outcome' <> 'requested' THEN
      RAISE EXCEPTION 'Stage % confirmation request failed: %',
        v_stage, v_result;
    END IF;
    v_result := public.confirm_idea_stage(
      v_idea_id, v_stage::smallint, v_revision
    );
    IF v_result->>'outcome' <> 'confirmed' THEN
      RAISE EXCEPTION 'Stage % confirmation failed: %', v_stage, v_result;
    END IF;
  END LOOP;

  v_result := public.submit_idea(v_idea_id, v_request_id, v_revision);
  IF v_result->>'outcome' <> 'submitted' THEN
    RAISE EXCEPTION 'Final submission failed: %', v_result;
  END IF;
  v_result := public.submit_idea(v_idea_id, v_request_id, v_revision);
  IF v_result->>'outcome' <> 'replayed' THEN
    RAISE EXCEPTION 'Repeated submission did not replay: %', v_result;
  END IF;
  v_result := public.submit_idea(
    v_idea_id, 'a9400000-0000-4000-8000-000000000002', v_revision
  );
  IF v_result->>'outcome' <> 'already_submitted' THEN
    RAISE EXCEPTION 'A different request duplicated submission: %', v_result;
  END IF;
  v_result := public.delete_own_idea(v_idea_id);
  IF v_result->>'outcome' <> 'invalid_state' THEN
    RAISE EXCEPTION 'Submitted idea deletion was not blocked: %', v_result;
  END IF;
END
$m9r8_submission_fixture_test$;

RESET ROLE;

DO $m9r8_validation_history_deletion_guard$
DECLARE
  v_idea_id uuid;
  v_result jsonb;
  v_version_id uuid;
BEGIN
  v_idea_id := (pg_catalog.current_setting(
    'test.m9r8_replacement_idea'
  ))::uuid;
  PERFORM pg_catalog.set_config('test.m9r8_history_idea', v_idea_id::text, true);
  SELECT version.id INTO v_version_id
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1;
  PERFORM pg_catalog.set_config(
    'test.m9r8_version_id', v_version_id::text, true
  );
END
$m9r8_validation_history_deletion_guard$;

SET LOCAL ROLE javaneh_identity_executor;
INSERT INTO public.milestone_validation_requests (
  request_id, idea_id, participant_id, configuration_version_id,
  milestone_key, catalog_version, stage_number, idea_revision,
  validation_mode, status, submitted_by
)
VALUES (
  'a9700000-0000-4000-8000-000000000001',
  pg_catalog.current_setting('test.m9r8_history_idea')::uuid,
  'a9000000-0000-4000-8000-000000000001',
  pg_catalog.current_setting('test.m9r8_version_id')::uuid,
  'S1-M1', '1.0', 1, 1, 'qualitative', 'pending_validation',
  'a9000000-0000-4000-8000-000000000001'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9000000-0000-4000-8000-000000000001', true
);
DO $m9r8_history_guard_assertion$
DECLARE
  v_result jsonb;
  v_idea_id uuid := pg_catalog.current_setting('test.m9r8_history_idea')::uuid;
BEGIN
  v_result := public.delete_own_idea(v_idea_id);
  IF v_result->>'outcome' <> 'evaluation_history_exists' THEN
    RAISE EXCEPTION 'Deletion did not preserve evaluation history: %', v_result;
  END IF;
END
$m9r8_history_guard_assertion$;
RESET ROLE;

SET LOCAL ROLE javaneh_identity_executor;
DO $m9r8_history_guard_read$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM public.ideas
     WHERE id = pg_catalog.current_setting('test.m9r8_history_idea')::uuid
  ) OR NOT EXISTS (
    SELECT 1
      FROM public.milestone_validation_requests
     WHERE idea_id = pg_catalog.current_setting('test.m9r8_history_idea')::uuid
  ) THEN
    RAISE EXCEPTION 'Blocked deletion modified the idea or its history';
  END IF;
END
$m9r8_history_guard_read$;
RESET ROLE;

ROLLBACK;
