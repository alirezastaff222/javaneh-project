-- Run against an isolated local Supabase database as supabase_admin.
-- All users, submissions, role fixtures, evaluation cycles, and events roll back.
BEGIN;

DO $m9r14_schema_test$
DECLARE
  v_function record;
BEGIN
  IF (
    SELECT pg_catalog.count(*)
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'
        AND relation.relname IN (
          'idea_evaluation_permissions',
          'idea_evaluation_cycles',
          'idea_evaluation_events'
        )
        AND relation.relrowsecurity
        AND relation.relforcerowsecurity
  ) <> 3 THEN
    RAISE EXCEPTION 'Evaluation tables must all have forced RLS enabled';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_evaluation_cycles', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_evaluation_events', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_evaluation_permissions', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.idea_evaluation_cycles', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.idea_evaluation_events', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'javaneh_identity_executor', 'public.idea_evaluation_events', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'javaneh_identity_executor', 'public.idea_evaluation_events', 'DELETE'
     ) THEN
    RAISE EXCEPTION 'Evaluation tables or events expose unsafe direct access';
  END IF;

  IF pg_catalog.has_function_privilege(
       'anon', 'public.assign_idea_evaluator(uuid,uuid)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'service_role', 'public.start_idea_evaluation(uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.assign_idea_evaluator(uuid,uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.start_idea_evaluation(uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.complete_idea_evaluation(uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.get_own_idea_evaluation_status(uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Evaluation RPC execution grants are unsafe';
  END IF;

  SELECT procedure.prosecdef, procedure.proconfig,
         procedure.proowner::regrole::text AS owner_name
    INTO v_function
    FROM pg_catalog.pg_proc AS procedure
    WHERE procedure.oid =
      'public.start_idea_evaluation(uuid)'::regprocedure;
  IF NOT v_function.prosecdef
     OR NOT ('search_path=pg_catalog' = ANY(v_function.proconfig))
     OR v_function.owner_name <> 'javaneh_identity_executor' THEN
    RAISE EXCEPTION 'Evaluation RPC owner, search path, or security definer is unsafe';
  END IF;
END
$m9r14_schema_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a9b00000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', 'm9r14-owner@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9b00000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', 'm9r14-coordinator@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9b00000-0000-4000-8000-000000000003', 'authenticated',
    'authenticated', 'm9r14-evaluator@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9b00000-0000-4000-8000-000000000004', 'authenticated',
    'authenticated', 'm9r14-other@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9b00000-0000-4000-8000-000000000005', 'authenticated',
    'authenticated', 'm9r14-unauthorized-evaluator@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  );

INSERT INTO public.idea_evaluation_permissions (
  user_id, permission, granted_by, reason
)
VALUES
  (
    'a9b00000-0000-4000-8000-000000000002',
    'assignment_manager',
    'a9b00000-0000-4000-8000-000000000001',
    'Rollback-only evaluation lifecycle fixture.'
  ),
  (
    'a9b00000-0000-4000-8000-000000000003',
    'human_evaluator',
    'a9b00000-0000-4000-8000-000000000001',
    'Rollback-only evaluation lifecycle fixture.'
  ),
  (
    'a9b00000-0000-4000-8000-000000000004',
    'human_evaluator',
    'a9b00000-0000-4000-8000-000000000001',
    'Rollback-only evaluation lifecycle fixture.'
  );

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000001', true
);

DO $m9r14_submission_test$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_revision integer := 1;
  v_stage smallint;
BEGIN
  v_result := public.create_idea('a9b10000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Idea fixture creation failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r14_idea_id', v_idea_id::text, true);

  v_result := public.save_idea_content(
    v_idea_id, 'a9b20000-0000-4000-8000-000000000001', v_revision,
    '[{"stage_number":1,"data":{"content":"draft autosave"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Draft autosave failed: %', v_result;
  END IF;
  v_revision := (v_result->>'result_revision')::integer;

  v_result := public.submit_idea(
    v_idea_id, 'a9b30000-0000-4000-8000-000000000001', v_revision
  );
  IF v_result->>'outcome' <> 'incomplete' THEN
    RAISE EXCEPTION 'Incomplete submission unexpectedly succeeded: %', v_result;
  END IF;

  FOR v_stage IN 1..6 LOOP
    v_result := public.save_idea_content(
      v_idea_id,
      ('a9b40000-0000-4000-8000-00000000000' || v_stage::text)::uuid,
      v_revision,
      pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'stage_number', v_stage,
          'data', pg_catalog.jsonb_build_object(
            'content', 'final submitted stage ' || v_stage::text
          )
        )
      )
    );
    IF v_result->>'outcome' <> 'applied' THEN
      RAISE EXCEPTION 'Stage % save failed: %', v_stage, v_result;
    END IF;
    v_revision := (v_result->>'result_revision')::integer;
    v_result := public.request_idea_stage_confirmation(
      v_idea_id, v_stage::smallint
    );
    IF v_result->>'outcome' <> 'requested' THEN
      RAISE EXCEPTION 'Stage % confirmation request failed: %', v_stage, v_result;
    END IF;
    v_result := public.confirm_idea_stage(
      v_idea_id, v_stage::smallint, v_revision
    );
    IF v_result->>'outcome' <> 'confirmed' THEN
      RAISE EXCEPTION 'Stage % confirmation failed: %', v_stage, v_result;
    END IF;
  END LOOP;

  v_result := public.submit_idea(
    v_idea_id, 'a9b30000-0000-4000-8000-000000000002', v_revision
  );
  IF v_result->>'outcome' <> 'submitted'
     OR (
       SELECT idea.competition_id
         FROM public.ideas AS idea
         WHERE idea.id = v_idea_id
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'Valid submission failed: %', v_result;
  END IF;
  v_result := public.submit_idea(
    v_idea_id, 'a9b30000-0000-4000-8000-000000000002', v_revision
  );
  IF v_result->>'outcome' <> 'replayed' THEN
    RAISE EXCEPTION 'Submission replay failed: %', v_result;
  END IF;

  v_result := public.get_own_idea_evaluation_status(v_idea_id);
  IF v_result->>'outcome' <> 'available'
     OR v_result->>'status' <> 'awaiting_review'
     OR v_result ? 'assigned_evaluator_id'
     OR v_result ? 'actor_user_id'
     OR v_result ? 'events' THEN
    RAISE EXCEPTION 'Participant projection exposed unsafe fields: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'test.m9r14_revision', v_revision::text, true
  );
END
$m9r14_submission_test$;

SET LOCAL ROLE javaneh_identity_executor;
DO $m9r14_submission_storage_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r14_idea_id')::uuid;
BEGIN
  IF (
    SELECT pg_catalog.count(*)
      FROM public.idea_evaluation_cycles AS cycle
      WHERE cycle.idea_id = v_idea_id
  ) <> 1
     OR (
       SELECT cycle.status
         FROM public.idea_evaluation_cycles AS cycle
         WHERE cycle.idea_id = v_idea_id
     ) <> 'awaiting_review'
     OR (
       SELECT cycle.assigned_evaluator_id
         FROM public.idea_evaluation_cycles AS cycle
         WHERE cycle.idea_id = v_idea_id
     ) IS NOT NULL
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_evaluation_events AS event
         JOIN public.idea_evaluation_cycles AS cycle
           ON cycle.cycle_id = event.cycle_id
         WHERE cycle.idea_id = v_idea_id
           AND event.event_type = 'cycle_created'
     ) <> 1
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_evaluation_events AS event
         JOIN public.idea_evaluation_cycles AS cycle
           ON cycle.cycle_id = event.cycle_id
         WHERE cycle.idea_id = v_idea_id
     ) <> 1 THEN
    RAISE EXCEPTION
      'Submission did not create exactly one awaiting, unassigned cycle and event';
  END IF;
END
$m9r14_submission_storage_test$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000001', true
);
DO $m9r14_client_table_access_test$
DECLARE
  v_access_test record;
BEGIN
  FOR v_access_test IN
    SELECT access_test.table_name, access_test.access_kind,
           access_test.sql_text
      FROM (VALUES
        (
          'idea_evaluation_permissions', 'SELECT',
          'SELECT 1 FROM public.idea_evaluation_permissions LIMIT 1'
        ),
        (
          'idea_evaluation_permissions', 'INSERT',
          'INSERT INTO public.idea_evaluation_permissions '
            '(user_id, permission, granted_by, reason) '
            'SELECT NULL::uuid, NULL::text, NULL::uuid, NULL::text WHERE false'
        ),
        (
          'idea_evaluation_permissions', 'UPDATE',
          'UPDATE public.idea_evaluation_permissions SET reason = reason WHERE false'
        ),
        (
          'idea_evaluation_permissions', 'DELETE',
          'DELETE FROM public.idea_evaluation_permissions WHERE false'
        ),
        (
          'idea_evaluation_cycles', 'SELECT',
          'SELECT 1 FROM public.idea_evaluation_cycles LIMIT 1'
        ),
        (
          'idea_evaluation_cycles', 'INSERT',
          'INSERT INTO public.idea_evaluation_cycles (idea_id) '
            'SELECT NULL::uuid WHERE false'
        ),
        (
          'idea_evaluation_cycles', 'UPDATE',
          'UPDATE public.idea_evaluation_cycles SET status = status WHERE false'
        ),
        (
          'idea_evaluation_cycles', 'DELETE',
          'DELETE FROM public.idea_evaluation_cycles WHERE false'
        ),
        (
          'idea_evaluation_events', 'SELECT',
          'SELECT 1 FROM public.idea_evaluation_events LIMIT 1'
        ),
        (
          'idea_evaluation_events', 'INSERT',
          'INSERT INTO public.idea_evaluation_events (cycle_id) '
            'SELECT NULL::uuid WHERE false'
        ),
        (
          'idea_evaluation_events', 'UPDATE',
          'UPDATE public.idea_evaluation_events '
            'SET occurred_at = occurred_at WHERE false'
        ),
        (
          'idea_evaluation_events', 'DELETE',
          'DELETE FROM public.idea_evaluation_events WHERE false'
        )
      ) AS access_test(table_name, operation, statement)
  LOOP
    BEGIN
      EXECUTE v_access_test.sql_text;
      RAISE EXCEPTION 'authenticated unexpectedly had % access to %',
        v_access_test.access_kind, v_access_test.table_name;
    EXCEPTION WHEN insufficient_privilege THEN
      NULL;
    END;
  END LOOP;
END
$m9r14_client_table_access_test$;

DO $m9r14_assignment_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r14_idea_id')::uuid;
  v_result jsonb;
BEGIN
  BEGIN
    PERFORM public.assign_idea_evaluator(
      v_idea_id, 'a9b00000-0000-4000-8000-000000000003'
    );
    RAISE EXCEPTION 'Unauthorized participant assigned an evaluator';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000002', true
  );
  v_result := public.assign_idea_evaluator(
    v_idea_id, 'a9b00000-0000-4000-8000-000000000005'
  );
  IF v_result->>'outcome' <> 'evaluator_unauthorized' THEN
    RAISE EXCEPTION 'An unauthorized evaluator was assignable: %', v_result;
  END IF;
  BEGIN
    PERFORM public.assign_idea_evaluator(
      v_idea_id, 'a9b00000-0000-4000-8000-000000000002'
    );
    RAISE EXCEPTION 'Assignment manager assigned themselves';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  v_result := public.assign_idea_evaluator(
    v_idea_id, 'a9b00000-0000-4000-8000-000000000003'
  );
  IF v_result->>'outcome' <> 'assigned'
     OR v_result->>'status' <> 'awaiting_review' THEN
    RAISE EXCEPTION 'Valid evaluator assignment failed: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000003', true
  );
  v_result := public.start_idea_evaluation(v_idea_id);
  IF v_result->>'outcome' <> 'editing_window_active' THEN
    RAISE EXCEPTION 'Evaluation started before the editing window expired: %',
      v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000002', true
  );
  v_result := public.assign_idea_evaluator(
    v_idea_id, 'a9b00000-0000-4000-8000-000000000003'
  );
  IF v_result->>'outcome' <> 'already_assigned' THEN
    RAISE EXCEPTION 'Repeated assignment was not idempotent: %', v_result;
  END IF;
END
$m9r14_assignment_test$;

SET LOCAL ROLE javaneh_identity_executor;
DO $m9r14_assignment_storage_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r14_idea_id')::uuid;
BEGIN
  IF (
    SELECT cycle.status
      FROM public.idea_evaluation_cycles AS cycle
      WHERE cycle.idea_id = v_idea_id
  ) <> 'awaiting_review'
     OR (
       SELECT cycle.assigned_evaluator_id
         FROM public.idea_evaluation_cycles AS cycle
         WHERE cycle.idea_id = v_idea_id
     ) <> 'a9b00000-0000-4000-8000-000000000003'::uuid
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_evaluation_events AS event
         JOIN public.idea_evaluation_cycles AS cycle
           ON cycle.cycle_id = event.cycle_id
         WHERE cycle.idea_id = v_idea_id
           AND event.event_type = 'evaluator_assigned'
     ) <> 1 THEN
    RAISE EXCEPTION 'Assignment transition or audit event is incorrect';
  END IF;
END
$m9r14_assignment_storage_test$;

UPDATE public.ideas
   SET submitted_at = pg_catalog.clock_timestamp() - INTERVAL '169 hours'
 WHERE id = pg_catalog.current_setting('test.m9r14_idea_id')::uuid;

DO $m9r14_event_immutability_test$
DECLARE
  v_cycle_id uuid;
BEGIN
  SELECT cycle.cycle_id INTO v_cycle_id
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.idea_id =
      pg_catalog.current_setting('test.m9r14_idea_id')::uuid;
  BEGIN
    UPDATE public.idea_evaluation_cycles
       SET status = 'completed'
     WHERE cycle_id = v_cycle_id;
    RAISE EXCEPTION 'Invalid evaluation state transition was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  BEGIN
    UPDATE public.idea_evaluation_events
       SET occurred_at = pg_catalog.clock_timestamp()
     WHERE cycle_id = v_cycle_id;
    RAISE EXCEPTION 'Evaluation audit events can be updated';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    DELETE FROM public.idea_evaluation_events
     WHERE cycle_id = v_cycle_id;
    RAISE EXCEPTION 'Evaluation audit events can be deleted';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$m9r14_event_immutability_test$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000001', true
);
DO $m9r14_edit_window_test$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.edit_submitted_idea(
    pg_catalog.current_setting('test.m9r14_idea_id')::uuid,
    'a9b50000-0000-4000-8000-000000000001',
    pg_catalog.current_setting('test.m9r14_revision')::integer,
    '[]'::jsonb
  );
  IF v_result->>'outcome' <> 'editing_window_expired' THEN
    RAISE EXCEPTION 'Existing dossier editing restriction changed: %', v_result;
  END IF;
END
$m9r14_edit_window_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000004', true
);
DO $m9r14_evaluator_authorization_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r14_idea_id')::uuid;
  v_result jsonb;
BEGIN
  v_result := public.start_idea_evaluation(v_idea_id);
  IF v_result->>'outcome' <> 'not_found_or_not_assigned' THEN
    RAISE EXCEPTION 'Unassigned user started evaluation: %', v_result;
  END IF;
END
$m9r14_evaluator_authorization_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000003', true
);
DO $m9r14_lifecycle_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r14_idea_id')::uuid;
  v_result jsonb;
  v_status jsonb;
BEGIN
  v_result := public.start_idea_evaluation(v_idea_id);
  IF v_result->>'outcome' <> 'started'
     OR v_result->>'status' <> 'in_progress'
     OR v_result->>'evaluated_revision'
       <> pg_catalog.current_setting('test.m9r14_revision') THEN
    RAISE EXCEPTION 'Evaluation did not start at the submitted revision: %',
      v_result;
  END IF;

  v_result := public.start_idea_evaluation(v_idea_id);
  IF v_result->>'outcome' <> 'already_started' THEN
    RAISE EXCEPTION 'Repeated start was not idempotent: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000004', true
  );
  v_result := public.complete_idea_evaluation(v_idea_id);
  IF v_result->>'outcome' <> 'not_found_or_not_assigned' THEN
    RAISE EXCEPTION 'Unassigned user completed evaluation: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000003', true
  );

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000002', true
  );
  v_result := public.assign_idea_evaluator(
    v_idea_id, 'a9b00000-0000-4000-8000-000000000004'
  );
  IF v_result->>'outcome' <> 'invalid_state' THEN
    RAISE EXCEPTION 'Evaluator was reassigned after evaluation started: %',
      v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000003', true
  );
  v_result := public.complete_idea_evaluation(v_idea_id);
  IF v_result->>'outcome' <> 'completed'
     OR v_result->>'status' <> 'completed' THEN
    RAISE EXCEPTION 'Assigned evaluator could not complete evaluation: %',
      v_result;
  END IF;
  v_result := public.complete_idea_evaluation(v_idea_id);
  IF v_result->>'outcome' <> 'already_completed' THEN
    RAISE EXCEPTION 'Repeated completion was not idempotent: %', v_result;
  END IF;

  v_status := public.get_own_idea_evaluation_status(v_idea_id);
  IF v_status->>'status' <> 'completed'
     OR v_status ? 'assigned_evaluator_id'
     OR v_status ? 'actor_user_id'
     OR v_status ? 'events' THEN
    RAISE EXCEPTION 'Completed participant projection is unsafe: %', v_status;
  END IF;
  IF (
    SELECT pg_catalog.count(*)
      FROM public.official_points_ledger AS ledger
      WHERE ledger.idea_id = v_idea_id
  ) <> 0 THEN
    RAISE EXCEPTION 'Evaluation completion created scoring ledger entries';
  END IF;
END
$m9r14_lifecycle_test$;

SET LOCAL ROLE javaneh_identity_executor;
DO $m9r14_lifecycle_storage_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r14_idea_id')::uuid;
  v_expected_revision integer :=
    pg_catalog.current_setting('test.m9r14_revision')::integer;
BEGIN
  IF (
    SELECT cycle.status
      FROM public.idea_evaluation_cycles AS cycle
      WHERE cycle.idea_id = v_idea_id
  ) <> 'completed'
     OR (
       SELECT cycle.evaluated_revision
         FROM public.idea_evaluation_cycles AS cycle
         WHERE cycle.idea_id = v_idea_id
     ) <> v_expected_revision
     OR (
       SELECT cycle.started_at
         FROM public.idea_evaluation_cycles AS cycle
         WHERE cycle.idea_id = v_idea_id
     ) IS NULL
     OR (
       SELECT cycle.completed_at
         FROM public.idea_evaluation_cycles AS cycle
         WHERE cycle.idea_id = v_idea_id
     ) IS NULL THEN
    RAISE EXCEPTION 'Completed evaluation lifecycle data is incorrect';
  END IF;

  IF (
    SELECT pg_catalog.count(*)
      FROM public.idea_evaluation_events AS event
      JOIN public.idea_evaluation_cycles AS cycle
        ON cycle.cycle_id = event.cycle_id
      WHERE cycle.idea_id = v_idea_id
        AND event.event_type = 'cycle_created'
  ) <> 1
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_evaluation_events AS event
         JOIN public.idea_evaluation_cycles AS cycle
           ON cycle.cycle_id = event.cycle_id
         WHERE cycle.idea_id = v_idea_id
           AND event.event_type = 'evaluator_assigned'
     ) <> 1
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_evaluation_events AS event
         JOIN public.idea_evaluation_cycles AS cycle
           ON cycle.cycle_id = event.cycle_id
         WHERE cycle.idea_id = v_idea_id
           AND event.event_type = 'evaluation_started'
     ) <> 1
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_evaluation_events AS event
         JOIN public.idea_evaluation_cycles AS cycle
           ON cycle.cycle_id = event.cycle_id
         WHERE cycle.idea_id = v_idea_id
           AND event.event_type = 'evaluation_completed'
     ) <> 1
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_evaluation_events AS event
         JOIN public.idea_evaluation_cycles AS cycle
           ON cycle.cycle_id = event.cycle_id
         WHERE cycle.idea_id = v_idea_id
     ) <> 4 THEN
    RAISE EXCEPTION 'Lifecycle audit events are missing or duplicated';
  END IF;
END
$m9r14_lifecycle_storage_test$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b00000-0000-4000-8000-000000000004', true
);
DO $m9r14_nonowner_read_test$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.get_own_idea_evaluation_status(
    pg_catalog.current_setting('test.m9r14_idea_id')::uuid
  );
  IF v_result->>'outcome' <> 'not_found' THEN
    RAISE EXCEPTION 'A non-owner read another participant evaluation: %',
      v_result;
  END IF;
END
$m9r14_nonowner_read_test$;

ROLLBACK;
