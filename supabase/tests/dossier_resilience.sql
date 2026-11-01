-- Run against an isolated local Supabase database as supabase_admin.
-- All fixtures, dossier edits, and timestamp changes are rolled back.
BEGIN;

DO $m9r10_schema_test$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM information_schema.columns AS column_info
      WHERE column_info.table_schema = 'public'
        AND column_info.table_name = 'ideas'
        AND column_info.column_name = 'submitted_at'
  ) THEN
    RAISE EXCEPTION 'The database-controlled submission timestamp is missing';
  END IF;
  IF (
    SELECT pg_catalog.count(*)
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'
        AND relation.relname IN (
          'idea_dossier_versions',
          'idea_dossier_edit_requests'
        )
        AND relation.relrowsecurity
        AND relation.relforcerowsecurity
  ) <> 2 OR pg_catalog.has_schema_privilege(
    'javaneh_identity_executor', 'public', 'CREATE'
  ) THEN
    RAISE EXCEPTION 'Dossier history RLS or executor schema privileges are unsafe';
  END IF;
  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_dossier_versions', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_dossier_versions', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_dossier_versions', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_dossier_versions', 'DELETE'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.idea_dossier_versions', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_dossier_edit_requests', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_dossier_edit_requests', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'anon', 'public.idea_dossier_versions', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.idea_dossier_edit_requests', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'Client roles have direct access to protected dossier history';
  END IF;
  IF pg_catalog.has_function_privilege(
       'anon', 'public.edit_submitted_idea(uuid,uuid,integer,jsonb)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'service_role',
       'public.edit_submitted_idea(uuid,uuid,integer,jsonb)',
       'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated',
       'public.edit_submitted_idea(uuid,uuid,integer,jsonb)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Submitted-dossier RPC execution grants are unsafe';
  END IF;
  IF pg_catalog.to_regprocedure('public.reopen_submitted_idea(uuid)') IS NOT NULL THEN
    RAISE EXCEPTION 'An unsupported dossier reopening endpoint was introduced';
  END IF;
END
$m9r10_schema_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a9a10000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', 'm9r10-owner@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9a10000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', 'm9r10-other@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  );

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9a10000-0000-4000-8000-000000000001', true
);

DO $m9r10_dossier_lifecycle_test$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_revision integer;
  v_before timestamptz;
  v_submitted_at timestamptz;
  v_expected_request uuid := 'a9a20000-0000-4000-8000-000000000001';
  v_stage smallint;
BEGIN
  v_result := public.create_idea('a9a30000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Idea fixture creation failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r10_idea_id', v_idea_id::text, true);
  v_revision := 1;

  FOR v_stage IN 1..6 LOOP
    v_result := public.save_idea_content(
      v_idea_id,
      ('a9a40000-0000-4000-8000-00000000000' || v_stage::text)::uuid,
      v_revision,
      pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'stage_number', v_stage,
          'data', pg_catalog.jsonb_build_object(
            'content', 'submitted stage ' || v_stage::text
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

  v_before := pg_catalog.clock_timestamp();
  v_result := public.submit_idea(
    v_idea_id, v_expected_request, v_revision
  );
  IF v_result->>'outcome' <> 'submitted'
     OR v_result->>'submitted_at' IS NULL THEN
    RAISE EXCEPTION 'Final submission did not return its server timestamp: %',
      v_result;
  END IF;
  v_submitted_at := (v_result->>'submitted_at')::timestamptz;
  IF v_submitted_at < v_before
     OR v_submitted_at > pg_catalog.clock_timestamp()
     OR (
       SELECT idea.submitted_at
         FROM public.ideas AS idea
         WHERE idea.id = v_idea_id
     ) IS DISTINCT FROM v_submitted_at THEN
    RAISE EXCEPTION 'Submission time was not established by the database';
  END IF;

  v_result := public.submit_idea(
    v_idea_id, v_expected_request, v_revision
  );
  IF v_result->>'outcome' <> 'replayed'
     OR (v_result->>'submitted_at')::timestamptz IS DISTINCT FROM v_submitted_at THEN
    RAISE EXCEPTION 'Submission retry extended or changed its editing window';
  END IF;

  v_result := public.edit_submitted_idea(
    v_idea_id,
    'a9a50000-0000-4000-8000-000000000001',
    v_revision,
    '[{"stage_number":2,"data":{"content":"edited after submission"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied'
     OR (v_result->>'result_revision')::integer <> v_revision + 1 THEN
    RAISE EXCEPTION 'In-window dossier edit failed: %', v_result;
  END IF;
  v_result := public.edit_submitted_idea(
    v_idea_id,
    'a9a50000-0000-4000-8000-000000000001',
    v_revision,
    '[{"stage_number":2,"data":{"content":"edited after submission"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'replayed'
     OR (v_result->>'result_revision')::integer <> v_revision + 1 THEN
    RAISE EXCEPTION 'Dossier edit retry did not replay: %', v_result;
  END IF;

  v_result := public.edit_submitted_idea(
    v_idea_id,
    'a9a50000-0000-4000-8000-000000000002',
    v_revision,
    '[{"stage_number":1,"data":{"content":"stale competing edit"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'stale_revision' THEN
    RAISE EXCEPTION 'Concurrent stale dossier edit was accepted: %', v_result;
  END IF;

  v_result := public.edit_submitted_idea(
    v_idea_id,
    'a9a50000-0000-4000-8000-000000000003',
    v_revision + 1,
    '[{"stage_number":2,"data":{"content":"edited after submission"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'no_op' THEN
    RAISE EXCEPTION 'A no-op dossier edit changed the revision: %', v_result;
  END IF;

  v_result := public.edit_submitted_idea(
    v_idea_id,
    'a9a50000-0000-4000-8000-000000000006',
    v_revision + 1,
    '[{"stage_number":7,"data":{"content":"invalid stage"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'invalid_input' THEN
    RAISE EXCEPTION 'Invalid dossier stage was accepted: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9a10000-0000-4000-8000-000000000002', true
  );
  v_result := public.edit_submitted_idea(
    v_idea_id,
    'a9a50000-0000-4000-8000-000000000007',
    v_revision + 1,
    '[{"stage_number":1,"data":{"content":"other owner edit"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'not_found_or_not_owned' THEN
    RAISE EXCEPTION 'Another participant edited this dossier: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9a10000-0000-4000-8000-000000000001', true
  );

  PERFORM pg_catalog.set_config('test.m9r10_idea_id', v_idea_id::text, true);
  PERFORM pg_catalog.set_config(
    'test.m9r10_submitted_at', v_submitted_at::text, true
  );
END
$m9r10_dossier_lifecycle_test$;

RESET ROLE;
DO $m9r10_snapshot_assertion$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r10_idea_id')::uuid;
  v_revision integer;
  v_snapshot_count integer;
BEGIN
  SELECT idea.revision - 1 INTO v_revision
    FROM public.ideas AS idea
    WHERE idea.id = v_idea_id;
  SELECT pg_catalog.count(*) INTO v_snapshot_count
    FROM public.idea_dossier_versions AS version
    WHERE version.idea_id = v_idea_id;
  IF v_snapshot_count <> 1
     OR NOT EXISTS (
       SELECT 1
         FROM public.idea_dossier_versions AS version
         WHERE version.idea_id = v_idea_id
           AND version.revision = v_revision
           AND version.actor_id =
             'a9a10000-0000-4000-8000-000000000001'::uuid
           AND version.created_at >=
             pg_catalog.current_setting('test.m9r10_submitted_at')::timestamptz
           AND version.dossier->'stages' @>
             '[{"stage_number":2,"data":{"content":"submitted stage 2"}}]'::jsonb
     ) THEN
    RAISE EXCEPTION 'The pre-edit dossier snapshot is incorrect or duplicated';
  END IF;
  BEGIN
    UPDATE public.idea_dossier_versions AS version
      SET dossier = '{"stages":[]}'::jsonb
      WHERE version.idea_id = v_idea_id;
    RAISE EXCEPTION 'A historical dossier snapshot was modified';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
END
$m9r10_snapshot_assertion$;

SET LOCAL ROLE authenticated;
DO $m9r10_second_history_snapshot$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r10_idea_id')::uuid;
  v_revision integer;
  v_result jsonb;
BEGIN
  SELECT idea.revision INTO v_revision
    FROM public.ideas AS idea
    WHERE idea.id = v_idea_id;
  v_result := public.edit_submitted_idea(
    v_idea_id,
    'a9a50000-0000-4000-8000-000000000009',
    v_revision,
    '[{"stage_number":1,"data":{"content":"second submitted edit"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Second history fixture edit failed: %', v_result;
  END IF;
END
$m9r10_second_history_snapshot$;
DO $m9r10_empty_history_fixture$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.create_idea(
    'a9a30000-0000-4000-8000-000000000003'
  );
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Empty-history fixture creation failed: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config(
    'test.m9r10_empty_history_idea', v_result->>'idea_id', true
  );
END
$m9r10_empty_history_fixture$;
DO $m9r10_history_access_assertion$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r10_idea_id')::uuid;
  v_empty_idea_id uuid :=
    pg_catalog.current_setting('test.m9r10_empty_history_idea')::uuid;
  v_nonexistent_id uuid := 'a9a60000-0000-4000-8000-000000000099';
  v_revisions integer[];
  v_count integer;
  v_history jsonb;
BEGIN
  SELECT pg_catalog.array_agg(history.revision),
         pg_catalog.count(*)::integer
    INTO v_revisions, v_count
    FROM public.get_own_submitted_idea_dossier_history(v_idea_id) AS history;
  IF v_count <> 2 OR pg_catalog.cardinality(v_revisions) <> 2
     OR v_revisions[1] >= v_revisions[2] THEN
    RAISE EXCEPTION 'Owner did not receive their ordered dossier history';
  END IF;

  SELECT pg_catalog.to_jsonb(history)
    INTO v_history
    FROM public.get_own_submitted_idea_dossier_history(v_idea_id) AS history;
  IF v_history ? 'actor_id' OR v_history ? 'request_id'
     OR (v_history ?& ARRAY['revision', 'dossier', 'created_at']) IS NOT TRUE THEN
    RAISE EXCEPTION 'History RPC returned an unsafe participant payload: %',
      v_history;
  END IF;

  BEGIN
    PERFORM 1
      FROM public.get_own_submitted_idea_dossier_history(v_empty_idea_id);
    RAISE EXCEPTION 'A non-submitted idea was not rejected';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
  BEGIN
    PERFORM 1
      FROM public.get_own_submitted_idea_dossier_history(v_nonexistent_id);
    RAISE EXCEPTION 'A nonexistent idea was not rejected';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9a10000-0000-4000-8000-000000000002', true
  );
  BEGIN
    PERFORM 1
      FROM public.get_own_submitted_idea_dossier_history(v_idea_id);
    RAISE EXCEPTION 'A non-owner was not rejected';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', 'a9a10000-0000-4000-8000-000000000001', true
  );

  BEGIN
    PERFORM 1 FROM public.idea_dossier_versions;
    RAISE EXCEPTION 'Authenticated direct snapshot SELECT unexpectedly succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN
      NULL;
  END;
END
$m9r10_history_access_assertion$;
RESET ROLE;

SET LOCAL ROLE javaneh_identity_executor;
UPDATE public.ideas AS idea
  SET status = 'submitted',
      current_step = 7,
      submitted_at = pg_catalog.clock_timestamp()
  WHERE idea.id =
    pg_catalog.current_setting('test.m9r10_empty_history_idea')::uuid;
RESET ROLE;

SET LOCAL ROLE authenticated;
DO $m9r10_empty_history_assertion$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM public.get_own_submitted_idea_dossier_history(
        pg_catalog.current_setting('test.m9r10_empty_history_idea')::uuid
      )
  ) THEN
    RAISE EXCEPTION 'A submitted idea without snapshots returned history';
  END IF;
END
$m9r10_empty_history_assertion$;
RESET ROLE;

DO $m9r10_history_privilege_assertion$
DECLARE
  v_function oid := pg_catalog.to_regprocedure(
    'public.get_own_submitted_idea_dossier_history(uuid)'
  );
BEGIN
  IF v_function IS NULL
     OR pg_catalog.pg_get_userbyid(
          (SELECT procedure.proowner
             FROM pg_catalog.pg_proc AS procedure
             WHERE procedure.oid = v_function)
        ) <> 'javaneh_identity_executor'
     OR NOT pg_catalog.has_function_privilege(
          'authenticated', v_function, 'EXECUTE'
        )
     OR pg_catalog.has_function_privilege('anon', v_function, 'EXECUTE')
     OR pg_catalog.has_function_privilege('service_role', v_function, 'EXECUTE')
     OR pg_catalog.has_table_privilege(
          'authenticated', 'public.idea_dossier_versions', 'SELECT'
        )
     OR pg_catalog.has_table_privilege(
          'authenticated', 'public.idea_dossier_versions', 'INSERT'
        )
     OR pg_catalog.has_table_privilege(
          'javaneh_identity_executor',
          'public.idea_dossier_versions',
          'INSERT'
        ) IS NOT TRUE
     OR NOT EXISTS (
       SELECT 1
         FROM pg_catalog.pg_proc AS procedure
         WHERE procedure.oid = v_function
           AND procedure.provolatile = 's'
           AND procedure.prosrc !~* '\m(insert|update|delete)\M'
           AND pg_catalog.strpos(
             procedure.prosrc,
             'ORDER BY version.revision ASC'
           ) > 0
     ) THEN
    RAISE EXCEPTION 'Dossier history RPC ownership or privileges are unsafe';
  END IF;
END
$m9r10_history_privilege_assertion$;

SET LOCAL ROLE javaneh_identity_executor;
UPDATE public.ideas AS idea
  SET submitted_at = pg_catalog.clock_timestamp() - INTERVAL '169 hours'
  WHERE idea.id =
    pg_catalog.current_setting('test.m9r10_idea_id')::uuid;
RESET ROLE;

SET LOCAL ROLE authenticated;
DO $m9r10_expired_window_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r10_idea_id')::uuid;
  v_revision integer;
  v_result jsonb;
BEGIN
  SELECT idea.revision INTO v_revision
    FROM public.ideas AS idea
    WHERE idea.id = v_idea_id;
  v_result := public.edit_submitted_idea(
    v_idea_id,
    'a9a50000-0000-4000-8000-000000000004',
    v_revision,
    '[{"stage_number":1,"data":{"content":"late edit"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'editing_window_expired' THEN
    RAISE EXCEPTION 'An expired dossier accepted a participant edit: %', v_result;
  END IF;
END
$m9r10_expired_window_test$;
RESET ROLE;
DO $m9r10_expired_snapshot_assertion$
BEGIN
  IF (
    SELECT pg_catalog.count(*)
      FROM public.idea_dossier_versions AS version
      WHERE version.idea_id =
        pg_catalog.current_setting('test.m9r10_idea_id')::uuid
  ) <> 2 THEN
    RAISE EXCEPTION 'A rejected expired edit created a snapshot';
  END IF;
END
$m9r10_expired_snapshot_assertion$;

SET LOCAL ROLE authenticated;
DO $m9r10_deletion_cascade_test$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
BEGIN
  v_result := public.create_idea('a9a30000-0000-4000-8000-000000000002');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Deletion fixture creation failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config('test.m9r10_delete_idea', v_idea_id::text, true);
END
$m9r10_deletion_cascade_test$;
RESET ROLE;

SET LOCAL ROLE javaneh_identity_executor;
INSERT INTO public.idea_dossier_versions (
  idea_id, revision, dossier, actor_id, request_id
)
VALUES (
  pg_catalog.current_setting('test.m9r10_delete_idea')::uuid,
  1,
  '{"stages":[]}'::jsonb,
  'a9a10000-0000-4000-8000-000000000001',
  'a9a50000-0000-4000-8000-000000000005'
);
INSERT INTO public.idea_dossier_edit_requests (
  owner_id, idea_id, request_id, expected_revision,
  payload_fingerprint, result_revision, outcome
)
VALUES (
  'a9a10000-0000-4000-8000-000000000001',
  pg_catalog.current_setting('test.m9r10_delete_idea')::uuid,
  'a9a50000-0000-4000-8000-000000000008',
  1,
  extensions.digest(pg_catalog.convert_to('fixture', 'UTF8'), 'sha256'),
  1,
  'no_op'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
DO $m9r10_deletion_cascade_assertion$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.m9r10_delete_idea')::uuid;
  v_result jsonb;
BEGIN
  v_result := public.delete_own_idea(v_idea_id);
  IF v_result->>'outcome' <> 'deleted' THEN
    RAISE EXCEPTION 'Permanent idea deletion failed: %', v_result;
  END IF;
END
$m9r10_deletion_cascade_assertion$;
RESET ROLE;
DO $m9r10_deletion_content_assertion$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM public.idea_dossier_versions AS version
      WHERE version.idea_id =
        pg_catalog.current_setting('test.m9r10_delete_idea')::uuid
  ) OR EXISTS (
    SELECT 1
      FROM public.idea_dossier_edit_requests AS request
      WHERE request.idea_id =
        pg_catalog.current_setting('test.m9r10_delete_idea')::uuid
  ) THEN
    RAISE EXCEPTION 'Permanent deletion retained dossier version data';
  END IF;
END
$m9r10_deletion_content_assertion$;

ROLLBACK;
