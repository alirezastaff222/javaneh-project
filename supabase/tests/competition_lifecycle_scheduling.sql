-- Run against an isolated local database as supabase_admin.
-- All M9R4 users, assignments, lifecycle events, and configuration changes roll back.
BEGIN;

DO $m9r4_security_test$
DECLARE
  v_status_definition text;
  v_event_definition text;
  v_index_predicate text;
  v_function record;
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_attribute AS attribute
      WHERE attribute.attrelid = 'public.competitions'::regclass
        AND attribute.attname = 'entry_opens_at'
        AND attribute.atttypid = 'timestamp with time zone'::regtype
        AND NOT attribute.attisdropped
  ) OR NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_attribute AS attribute
      WHERE attribute.attrelid = 'public.competitions'::regclass
        AND attribute.attname = 'entry_closes_at'
        AND attribute.atttypid = 'timestamp with time zone'::regtype
        AND NOT attribute.attisdropped
  ) THEN
    RAISE EXCEPTION 'Competition entry-window timestamps are missing';
  END IF;

  SELECT pg_catalog.pg_get_constraintdef(constraint_row.oid)
    INTO v_status_definition
    FROM pg_catalog.pg_constraint AS constraint_row
    WHERE constraint_row.conrelid = 'public.competitions'::regclass
      AND constraint_row.conname = 'competitions_status_check';
  SELECT pg_catalog.pg_get_constraintdef(constraint_row.oid)
    INTO v_event_definition
    FROM pg_catalog.pg_constraint AS constraint_row
    WHERE constraint_row.conrelid = 'public.competition_events'::regclass
      AND constraint_row.conname = 'competition_events_status_transition_check';
  IF v_status_definition NOT LIKE '%closed%'
     OR v_status_definition NOT LIKE '%archived%'
     OR v_status_definition NOT LIKE '%retired%'
     OR v_event_definition IS NULL THEN
    RAISE EXCEPTION 'Lifecycle statuses or transition audit are incomplete';
  END IF;

  SELECT pg_catalog.pg_get_expr(index.indpred, index.indrelid)
    INTO v_index_predicate
    FROM pg_catalog.pg_index AS index
    WHERE index.indrelid = 'public.competitions'::regclass
      AND index.indexrelid =
        'public.competitions_one_active_global_idx'::regclass
      AND index.indisunique;
  IF v_index_predicate IS NULL
     OR v_index_predicate NOT LIKE '%active%' THEN
    RAISE EXCEPTION 'The existing one-active-competition limit was changed';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.competitions', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.competitions', 'UPDATE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.set_competition_status(uuid,text,text)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.set_competition_status(uuid,text,text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.assign_idea_competition(uuid,uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.assign_idea_competition(uuid,uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Competition lifecycle or assignment grants are unsafe';
  END IF;

  SELECT procedure.prosecdef, procedure.proconfig,
         procedure.proowner::regrole::text AS owner_name
    INTO v_function
    FROM pg_catalog.pg_proc AS procedure
    WHERE procedure.oid =
      'public.set_competition_status(uuid,text,text)'::regprocedure;
  IF NOT v_function.prosecdef
     OR NOT ('search_path=pg_catalog' = ANY(v_function.proconfig))
     OR v_function.owner_name <> 'javaneh_identity_executor' THEN
    RAISE EXCEPTION 'Competition lifecycle RPC security is unsafe';
  END IF;

  SELECT procedure.prosecdef, procedure.proconfig,
         procedure.proowner::regrole::text AS owner_name
    INTO v_function
    FROM pg_catalog.pg_proc AS procedure
    WHERE procedure.oid =
      'public.assign_idea_competition(uuid,uuid)'::regprocedure;
  IF NOT v_function.prosecdef
     OR NOT ('search_path=pg_catalog' = ANY(v_function.proconfig))
     OR v_function.owner_name <> 'javaneh_identity_executor' THEN
    RAISE EXCEPTION 'Competition assignment RPC security is unsafe';
  END IF;

  IF pg_catalog.has_schema_privilege(
       'javaneh_identity_executor', 'public', 'CREATE'
     ) THEN
    RAISE EXCEPTION 'The identity executor retains CREATE on public';
  END IF;
END
$m9r4_security_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a8000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
    'm9r4-scoring-admin@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a8000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
    'm9r4-participant-one@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a8000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated',
    'm9r4-participant-two@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a8000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated',
    'm9r4-participant-three@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a8000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated',
    'm9r4-participant-four@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  );

INSERT INTO public.scoring_role_assignments (user_id, role_name, assigned_by)
VALUES ('a8000000-0000-4000-8000-000000000001', 'scoring_administrator', NULL);

DO $competition_identifiers$
DECLARE
  v_version_id uuid;
  v_competition_id uuid;
BEGIN
  SELECT version.id, competition.id
    INTO v_version_id, v_competition_id
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    JOIN public.competitions AS competition
      ON competition.scoring_configuration_version_id = version.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1;
  IF v_version_id IS NULL OR v_competition_id IS NULL THEN
    RAISE EXCEPTION 'The canonical draft scoring version and competition are missing';
  END IF;
  PERFORM pg_catalog.set_config('test.m9r4_version_id', v_version_id::text, true);
  PERFORM pg_catalog.set_config(
    'test.m9r4_competition_id', v_competition_id::text, true
  );
END
$competition_identifiers$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a8000000-0000-4000-8000-000000000002', true
);
DO $create_test_ideas$
DECLARE
  v_result jsonb;
  v_participants uuid[] := ARRAY[
    'a8000000-0000-4000-8000-000000000002'::uuid,
    'a8000000-0000-4000-8000-000000000003'::uuid,
    'a8000000-0000-4000-8000-000000000004'::uuid,
    'a8000000-0000-4000-8000-000000000005'::uuid
  ];
  v_requests uuid[] := ARRAY[
    'a8100000-0000-4000-8000-000000000001'::uuid,
    'a8100000-0000-4000-8000-000000000002'::uuid,
    'a8100000-0000-4000-8000-000000000003'::uuid,
    'a8100000-0000-4000-8000-000000000004'::uuid
  ];
  v_index integer;
BEGIN
  FOR v_index IN 1..4 LOOP
    PERFORM pg_catalog.set_config(
      'request.jwt.claim.sub', v_participants[v_index]::text, true
    );
    v_result := public.create_idea(v_requests[v_index]);
    IF v_result->>'outcome' <> 'created' OR v_result->>'idea_id' IS NULL THEN
      RAISE EXCEPTION 'Could not create rollback-only idea fixture: %', v_result;
    END IF;
    PERFORM pg_catalog.set_config(
      'test.m9r4_idea_' || v_index::text, v_result->>'idea_id', true
    );
  END LOOP;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a8000000-0000-4000-8000-000000000001', true
  );
END
$create_test_ideas$;

DO $draft_assignment_test$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.assign_idea_competition(
    pg_catalog.current_setting('test.m9r4_idea_1')::uuid,
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid
  );
  IF v_result->>'outcome' <> 'competition_unavailable' THEN
    RAISE EXCEPTION 'A draft competition accepted an idea assignment: %', v_result;
  END IF;
END
$draft_assignment_test$;
RESET ROLE;

SET LOCAL ROLE javaneh_identity_executor;
DO $draft_assignment_unchanged$
BEGIN
  IF (SELECT idea.competition_id
        FROM public.ideas AS idea
        WHERE idea.id =
          pg_catalog.current_setting('test.m9r4_idea_1')::uuid) IS NOT NULL THEN
    RAISE EXCEPTION 'A failed assignment changed the idea entry';
  END IF;
END
$draft_assignment_unchanged$;
UPDATE public.competitions
  SET description = 'Draft settings remain editable after failed assignment.'
  WHERE id = pg_catalog.current_setting('test.m9r4_competition_id')::uuid;
DO $draft_window_constraints$
DECLARE
  v_rejected boolean;
BEGIN
  v_rejected := false;
  BEGIN
    UPDATE public.competitions
      SET entry_opens_at = pg_catalog.clock_timestamp(),
          entry_closes_at = NULL
      WHERE id = pg_catalog.current_setting('test.m9r4_competition_id')::uuid;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A partial entry window was accepted';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.competitions
      SET entry_opens_at = pg_catalog.clock_timestamp() + interval '1 hour',
          entry_closes_at = pg_catalog.clock_timestamp()
      WHERE id = pg_catalog.current_setting('test.m9r4_competition_id')::uuid;
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An inverted entry window was accepted';
  END IF;
END
$draft_window_constraints$;
RESET ROLE;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a8000000-0000-4000-8000-000000000001', true
);
SET LOCAL ROLE authenticated;
DO $activate_configuration$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.approve_scoring_configuration_version(
    pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'Rollback-only M9R4 lifecycle test.'
  );
  IF v_result->>'outcome' <> 'approved' THEN
    RAISE EXCEPTION 'The scoring administrator could not approve the ready version: %',
      v_result;
  END IF;
  v_result := public.activate_scoring_configuration_version(
    pg_catalog.current_setting('test.m9r4_version_id')::uuid,
    'Rollback-only M9R4 lifecycle test.'
  );
  IF v_result->>'outcome' <> 'activated' THEN
    RAISE EXCEPTION 'The scoring administrator could not activate the ready version: %',
      v_result;
  END IF;
END
$activate_configuration$;

DO $activation_requires_window$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.set_competition_status(
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid,
    'active',
    'Activation without an entry window must fail.'
  );
  IF v_result->>'outcome' <> 'invalid_entry_window'
  THEN
    RAISE EXCEPTION 'Competition activation without dates was not rejected: %',
      v_result;
  END IF;
END
$activation_requires_window$;

RESET ROLE;
SET LOCAL ROLE javaneh_identity_executor;
DO $draft_after_rejected_activation$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM public.competitions AS competition
      WHERE competition.id =
        pg_catalog.current_setting('test.m9r4_competition_id')::uuid
        AND competition.status = 'draft'
  ) THEN
    RAISE EXCEPTION 'A rejected activation changed the competition status';
  END IF;
END
$draft_after_rejected_activation$;
UPDATE public.competitions
  SET entry_opens_at = pg_catalog.clock_timestamp() + interval '3 seconds',
      entry_closes_at = pg_catalog.clock_timestamp() + interval '12 seconds'
  WHERE id = pg_catalog.current_setting('test.m9r4_competition_id')::uuid;
SELECT entry_closes_at::text AS m9r4_entry_closes_at
  FROM public.competitions
  WHERE id = pg_catalog.current_setting('test.m9r4_competition_id')::uuid;
RESET ROLE;

SET LOCAL ROLE authenticated;
DO $unauthorized_lifecycle_test$
DECLARE
  v_rejected boolean := false;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a8000000-0000-4000-8000-000000000002', true
  );
  BEGIN
    PERFORM public.set_competition_status(
      pg_catalog.current_setting('test.m9r4_competition_id')::uuid,
      'active',
      'Unauthorized activation attempt.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A participant without a scoring role changed competition status';
  END IF;
END
$unauthorized_lifecycle_test$;

DO $activate_competition$
DECLARE
  v_result jsonb;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a8000000-0000-4000-8000-000000000001', true
  );
  v_result := public.set_competition_status(
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid,
    'active',
    'Rollback-only M9R4 lifecycle test.'
  );
  IF v_result->>'outcome' <> 'active' THEN
    RAISE EXCEPTION 'A valid competition did not activate: %', v_result;
  END IF;
END
$activate_competition$;

DO $before_open_assignment$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.assign_idea_competition(
    pg_catalog.current_setting('test.m9r4_idea_1')::uuid,
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid
  );
  IF v_result->>'outcome' <> 'entry_window_not_open' THEN
    RAISE EXCEPTION 'An assignment before opening was not rejected: %', v_result;
  END IF;
END
$before_open_assignment$;
RESET ROLE;

SELECT pg_catalog.pg_sleep(
  GREATEST(
    0,
    EXTRACT(
      epoch FROM (
        SELECT competition.entry_opens_at - pg_catalog.clock_timestamp()
          FROM public.competitions AS competition
          WHERE competition.id =
            pg_catalog.current_setting('test.m9r4_competition_id')::uuid
      )
    )::double precision + 0.05
  )
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a8000000-0000-4000-8000-000000000001', true
);
DO $in_window_assignment$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.assign_idea_competition(
    pg_catalog.current_setting('test.m9r4_idea_1')::uuid,
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid
  );
  IF v_result->>'outcome' <> 'assigned' THEN
    RAISE EXCEPTION 'An in-window assignment did not bind the idea to its competition: %',
      v_result;
  END IF;
END
$in_window_assignment$;

RESET ROLE;
SET LOCAL ROLE javaneh_identity_executor;
DO $configuration_lock_test$
DECLARE
  v_rejected boolean;
  v_competition_id uuid := pg_catalog.current_setting(
    'test.m9r4_competition_id'
  )::uuid;
  v_version_id uuid := pg_catalog.current_setting('test.m9r4_version_id')::uuid;
BEGIN
  IF (SELECT idea.competition_id
        FROM public.ideas AS idea
        WHERE idea.id =
          pg_catalog.current_setting('test.m9r4_idea_1')::uuid)
     IS DISTINCT FROM v_competition_id THEN
    RAISE EXCEPTION 'An in-window assignment did not bind the idea to its competition';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.competitions
      SET entry_opens_at = entry_opens_at - interval '1 minute'
      WHERE id = v_competition_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Competition schedule changed after activation and assignment';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.competitions
      SET scoring_configuration_version_id = NULL
      WHERE id = v_competition_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Competition scoring version reference was replaceable';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.scoring_configuration_versions
      SET development_max_points = development_max_points + 1
      WHERE id = v_version_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Active scoring configuration totals were mutable';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.scoring_stage_catalog
      SET display_name = display_name || ' changed'
      WHERE configuration_version_id = v_version_id
        AND stage_number = 1;
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Active stage policy was mutable';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.scoring_milestone_catalog
      SET point_value = point_value + 1
      WHERE configuration_version_id = v_version_id
        AND milestone_key = 'S1-M1';
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Active development rubric was mutable';
  END IF;
END
$configuration_lock_test$;
RESET ROLE;

SET LOCAL ROLE javaneh_identity_executor;
DO $early_closure_timing$
BEGIN
  IF pg_catalog.clock_timestamp() >= (
    SELECT competition.entry_closes_at
      FROM public.competitions AS competition
      WHERE competition.id =
        pg_catalog.current_setting('test.m9r4_competition_id')::uuid
  ) THEN
    RAISE EXCEPTION 'Early closure was checked after the scheduled closing time';
  END IF;
END
$early_closure_timing$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a8000000-0000-4000-8000-000000000001', true
);
SAVEPOINT m9r4_legacy_retired_compatibility;
DO $legacy_retired_transition$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.set_competition_status(
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid,
    'retired',
    'Rollback-only legacy compatibility check.'
  );
  IF v_result->>'outcome' <> 'retired' THEN
    RAISE EXCEPTION 'The legacy active-to-retired transition changed: %', v_result;
  END IF;
END
$legacy_retired_transition$;
ROLLBACK TO SAVEPOINT m9r4_legacy_retired_compatibility;

SAVEPOINT m9r4_early_close;
DO $early_close_test$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.set_competition_status(
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid,
    'closed',
    'Rollback-only early closure check.'
  );
  IF v_result->>'outcome' <> 'closed' THEN
    RAISE EXCEPTION 'An administrator could not close an active competition early: %',
      v_result;
  END IF;
  v_result := public.assign_idea_competition(
    pg_catalog.current_setting('test.m9r4_idea_2')::uuid,
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid
  );
  IF v_result->>'outcome' <> 'competition_unavailable' THEN
    RAISE EXCEPTION 'A closed competition accepted an assignment: %', v_result;
  END IF;
END
$early_close_test$;
ROLLBACK TO SAVEPOINT m9r4_early_close;
RESET ROLE;

SELECT pg_catalog.pg_sleep(
  GREATEST(
    0,
    EXTRACT(
      epoch FROM (
        SELECT competition.entry_closes_at - pg_catalog.clock_timestamp()
          FROM public.competitions AS competition
          WHERE competition.id =
            pg_catalog.current_setting('test.m9r4_competition_id')::uuid
      )
    )::double precision + 0.05
  )
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a8000000-0000-4000-8000-000000000001', true
);
DO $at_or_after_close_assignment$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.assign_idea_competition(
    pg_catalog.current_setting('test.m9r4_idea_3')::uuid,
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid
  );
  IF v_result->>'outcome' <> 'entry_window_closed' THEN
    RAISE EXCEPTION 'An assignment at or after closing was not rejected: %', v_result;
  END IF;
END
$at_or_after_close_assignment$;

DO $close_and_archive_test$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.set_competition_status(
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid,
    'closed',
    'Rollback-only scheduled closure check.'
  );
  IF v_result->>'outcome' <> 'closed' THEN
    RAISE EXCEPTION 'An active competition did not close: %', v_result;
  END IF;

  v_result := public.assign_idea_competition(
    pg_catalog.current_setting('test.m9r4_idea_4')::uuid,
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid
  );
  IF v_result->>'outcome' <> 'competition_unavailable' THEN
    RAISE EXCEPTION 'A closed competition accepted a new idea: %', v_result;
  END IF;

  v_result := public.set_competition_status(
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid,
    'archived',
    'Rollback-only archive check.'
  );
  IF v_result->>'outcome' <> 'archived' THEN
    RAISE EXCEPTION 'A closed competition did not archive: %', v_result;
  END IF;

  v_result := public.set_competition_status(
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid,
    'active',
    'Reopening must fail.'
  );
  IF v_result->>'outcome' <> 'invalid_state' THEN
    RAISE EXCEPTION 'An archived competition reopened: %', v_result;
  END IF;
  v_result := public.assign_idea_competition(
    pg_catalog.current_setting('test.m9r4_idea_4')::uuid,
    pg_catalog.current_setting('test.m9r4_competition_id')::uuid
  );
  IF v_result->>'outcome' <> 'competition_unavailable' THEN
    RAISE EXCEPTION 'An archived competition accepted an idea: %', v_result;
  END IF;
END
$close_and_archive_test$;
RESET ROLE;

SET LOCAL ROLE javaneh_identity_executor;
DO $lifecycle_audit_assertions$
DECLARE
  v_event_count integer;
BEGIN
  IF (SELECT idea.competition_id
        FROM public.ideas AS idea
        WHERE idea.id =
          pg_catalog.current_setting('test.m9r4_idea_1')::uuid)
     IS DISTINCT FROM
       pg_catalog.current_setting('test.m9r4_competition_id')::uuid THEN
    RAISE EXCEPTION 'Closing or archiving removed an existing competition entry';
  END IF;

  SELECT pg_catalog.count(*) INTO v_event_count
    FROM public.competition_events AS event
    WHERE event.competition_id =
      pg_catalog.current_setting('test.m9r4_competition_id')::uuid
      AND event.previous_status IS NOT NULL
      AND event.new_status IS NOT NULL;
  IF v_event_count <> 3
     OR NOT EXISTS (
       SELECT 1
         FROM public.competition_events AS event
         WHERE event.competition_id =
           pg_catalog.current_setting('test.m9r4_competition_id')::uuid
           AND event.event_type = 'activated'
           AND event.previous_status = 'draft'
           AND event.new_status = 'active'
           AND event.reason = 'Rollback-only M9R4 lifecycle test.'
     )
     OR NOT EXISTS (
       SELECT 1
         FROM public.competition_events AS event
         WHERE event.competition_id =
           pg_catalog.current_setting('test.m9r4_competition_id')::uuid
           AND event.event_type = 'closed'
           AND event.previous_status = 'active'
           AND event.new_status = 'closed'
           AND event.reason = 'Rollback-only scheduled closure check.'
     )
     OR NOT EXISTS (
       SELECT 1
         FROM public.competition_events AS event
         WHERE event.competition_id =
           pg_catalog.current_setting('test.m9r4_competition_id')::uuid
           AND event.event_type = 'archived'
           AND event.previous_status = 'closed'
           AND event.new_status = 'archived'
           AND event.reason = 'Rollback-only archive check.'
     ) THEN
    RAISE EXCEPTION 'Competition lifecycle audit status or reason is incomplete';
  END IF;
END
$lifecycle_audit_assertions$;
RESET ROLE;

ROLLBACK;
