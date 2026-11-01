-- Run against an isolated local Supabase database as supabase_admin.
-- All fixtures and mutations are rolled back before the script exits.
BEGIN;

DO $security_test$
DECLARE
  v_count integer;
  v_role_count integer;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN (
        'ideas',
        'idea_stages',
        'idea_stage_confirmed_versions',
        'idea_deletion_audit',
        'idea_save_requests',
        'idea_dossier_versions',
        'idea_dossier_edit_requests'
      )
      AND c.relkind = 'r';
  IF v_count <> 7 OR pg_catalog.to_regclass('public.idea_sessions') IS NOT NULL THEN
    RAISE EXCEPTION 'Core model contains a missing or unapproved persistence table';
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN (
        'ideas',
        'idea_stages',
        'idea_stage_confirmed_versions',
        'idea_deletion_audit',
        'idea_save_requests',
        'idea_dossier_versions',
        'idea_dossier_edit_requests'
      )
      AND c.relrowsecurity
      AND c.relforcerowsecurity;
  IF v_count <> 7 THEN
    RAISE EXCEPTION 'All seven core tables must have forced RLS';
  END IF;

  SELECT pg_catalog.count(*) INTO v_role_count
    FROM pg_catalog.pg_roles AS r
    WHERE r.rolname IN ('javaneh_identity_bridge', 'javaneh_identity_executor')
      AND NOT r.rolcanlogin
      AND NOT r.rolinherit
      AND NOT r.rolbypassrls
      AND NOT r.rolsuper
      AND NOT r.rolcreatedb
      AND NOT r.rolcreaterole;
  IF v_role_count <> 2 THEN
    RAISE EXCEPTION 'Internal roles do not have the approved restricted attributes';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.ideas', 'DELETE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_deletion_audit', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_stage_confirmed_versions', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_stage_confirmed_versions', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_stage_confirmed_versions', 'DELETE'
     )
     OR pg_catalog.has_table_privilege(
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
       'authenticated', 'public.idea_dossier_edit_requests', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.idea_deletion_audit', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'Client roles have unapproved table privileges';
  END IF;

  IF pg_catalog.has_function_privilege(
       'anon', 'public.create_idea(uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.create_idea(uuid)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'service_role', 'public.create_idea(uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Protected RPC execution grants are too broad or incomplete';
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM pg_catalog.pg_proc AS p
    JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'create_idea',
        'save_idea_content',
        'request_idea_stage_confirmation',
        'confirm_idea_stage',
        'delete_own_idea',
        'set_idea_current_step',
        'submit_idea',
        'edit_submitted_idea'
      )
      AND p.prosecdef
      AND p.proowner = 'javaneh_identity_executor'::regrole
      AND p.proconfig @> ARRAY['search_path=pg_catalog'];
  IF v_count <> 8 THEN
    RAISE EXCEPTION 'Protected functions do not have the approved owner or search path';
  END IF;

  IF pg_catalog.pg_get_userbyid((
       SELECT p.proowner
       FROM pg_catalog.pg_proc AS p
       JOIN pg_catalog.pg_namespace AS n ON n.oid = p.pronamespace
       WHERE n.nspname = 'javaneh_private'
         AND p.proname = 'current_uid'
     )) <> 'javaneh_identity_bridge'
     OR pg_catalog.has_function_privilege(
       'anon', 'javaneh_private.current_uid()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Identity bridge ownership or execution grants are unsafe';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname IN (
          'ideas',
          'idea_stages',
          'idea_stage_confirmed_versions',
          'idea_deletion_audit',
          'idea_save_requests',
          'idea_dossier_versions',
          'idea_dossier_edit_requests'
        )
        AND c.relowner = 'javaneh_identity_executor'::regrole
  ) THEN
    RAISE EXCEPTION 'The executor must not own application tables';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_catalog.pg_roles AS r
      WHERE r.rolname IN ('anon', 'authenticated', 'service_role', 'authenticator')
        AND (
          pg_catalog.pg_has_role(r.rolname, 'javaneh_identity_bridge', 'MEMBER')
          OR pg_catalog.pg_has_role(r.rolname, 'javaneh_identity_executor', 'MEMBER')
        )
  ) THEN
    RAISE EXCEPTION 'A client-facing role can assume an internal role';
  END IF;
END
$security_test$;

CREATE FUNCTION public.m7r2_fail_stage_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.stage_number = 2
     AND pg_catalog.current_setting('m7r2.fail_create', true) = 'on' THEN
    RAISE EXCEPTION 'Injected stage-insert failure' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER m7r2_fail_stage_insert
  BEFORE INSERT ON public.idea_stages
  FOR EACH ROW EXECUTE FUNCTION public.m7r2_fail_stage_insert();

CREATE FUNCTION public.m7r2_fail_save_ledger_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.request_id = 'd1000000-0000-4000-8000-000000000009' THEN
    RAISE EXCEPTION 'Injected save-ledger failure' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER m7r2_fail_save_ledger_insert
  BEFORE INSERT ON public.idea_save_requests
  FOR EACH ROW EXECUTE FUNCTION public.m7r2_fail_save_ledger_insert();

CREATE FUNCTION public.m7r2_fail_account_audit_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.operation = 'account_cascade'
     AND NEW.owner_id = 'b1000000-0000-4000-8000-000000000002' THEN
    IF pg_catalog.current_setting('m7r2.fail_account_audit', true) = 'on' THEN
      RAISE EXCEPTION 'Injected account-audit failure' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END
$function$;

CREATE TRIGGER m7r2_fail_account_audit_insert
  BEFORE INSERT ON public.idea_deletion_audit
  FOR EACH ROW EXECUTE FUNCTION public.m7r2_fail_account_audit_insert();

INSERT INTO auth.users (
  id,
  aud,
  role,
  email,
  encrypted_password,
  raw_app_meta_data,
  raw_user_meta_data,
  created_at,
  updated_at,
  is_sso_user,
  is_anonymous
)
VALUES
  (
    'a1000000-0000-4000-8000-000000000001',
    'authenticated',
    'authenticated',
    'm7r1-owner-a@test.invalid',
    '',
    '{}'::jsonb,
    '{}'::jsonb,
    pg_catalog.now(),
    pg_catalog.now(),
    false,
    false
  ),
  (
    'b1000000-0000-4000-8000-000000000002',
    'authenticated',
    'authenticated',
    'm7r1-owner-b@test.invalid',
    '',
    '{}'::jsonb,
    '{}'::jsonb,
    pg_catalog.now(),
    pg_catalog.now(),
    false,
    false
  );

SET LOCAL ROLE authenticated;

DO $unauthenticated_test$
BEGIN
  BEGIN
    PERFORM public.create_idea('f1000000-0000-4000-8000-000000000002');
    RAISE EXCEPTION 'Unauthenticated create unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$unauthenticated_test$;

DO $test$
DECLARE
  v_owner_a constant uuid := 'a1000000-0000-4000-8000-000000000001';
  v_owner_b constant uuid := 'b1000000-0000-4000-8000-000000000002';
  v_request_a constant uuid := 'c1000000-0000-4000-8000-000000000001';
  v_request_b constant uuid := 'c1000000-0000-4000-8000-000000000002';
  v_request_c constant uuid := 'c1000000-0000-4000-8000-000000000003';
  v_request_d constant uuid := 'c1000000-0000-4000-8000-000000000004';
  v_save_a constant uuid := 'd1000000-0000-4000-8000-000000000001';
  v_save_noop constant uuid := 'd1000000-0000-4000-8000-000000000002';
  v_save_stale constant uuid := 'd1000000-0000-4000-8000-000000000003';
  v_save_confirmed_edit constant uuid := 'd1000000-0000-4000-8000-000000000004';
  v_save_failed constant uuid := 'd1000000-0000-4000-8000-000000000009';
  v_failed_create constant uuid := 'c1000000-0000-4000-8000-000000000099';
  v_idea_a uuid;
  v_idea_b uuid;
  v_idea_c uuid;
  v_idea_other uuid;
  v_result jsonb;
  v_revision integer;
  v_count integer;
  v_status text;
  v_stage_data jsonb;
  v_stage smallint;
  v_failed boolean;
BEGIN
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_owner_a::text, true);

  PERFORM pg_catalog.set_config('m7r2.fail_create', 'on', true);
  v_failed := false;
  BEGIN
    PERFORM public.create_idea(v_failed_create);
  EXCEPTION WHEN raise_exception THEN
    v_failed := true;
  END;
  PERFORM pg_catalog.set_config('m7r2.fail_create', 'off', true);
  IF NOT v_failed THEN
    RAISE EXCEPTION 'Injected creation failure did not abort create_idea';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.ideas AS i
    WHERE i.owner_id = v_owner_a
      AND i.creation_request_id = v_failed_create
  ) OR EXISTS (
    SELECT 1
      FROM public.idea_stages AS s
      JOIN public.ideas AS i ON i.id = s.idea_id
      WHERE i.owner_id = v_owner_a
        AND i.creation_request_id = v_failed_create
  ) THEN
    RAISE EXCEPTION 'Failed create left a partial idea or stage';
  END IF;

  v_result := public.create_idea(v_request_a);
  IF v_result->>'outcome' <> 'created' OR v_result->>'revision' <> '1' THEN
    RAISE EXCEPTION 'First create did not return created at revision 1: %', v_result;
  END IF;
  v_idea_a := (v_result->>'idea_id')::uuid;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.idea_stages AS s
    WHERE s.idea_id = v_idea_a;
  IF v_count <> 7 THEN
    RAISE EXCEPTION 'New idea has % stage rows, expected 7', v_count;
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.idea_stages AS s
    WHERE s.idea_id = v_idea_a
      AND (
        (s.stage_number = 1 AND s.status = 'in_progress')
        OR (s.stage_number BETWEEN 2 AND 7 AND s.status = 'locked')
      )
      AND s.data = '{}'::jsonb;
  IF v_count <> 7 THEN
    RAISE EXCEPTION 'New idea stage states or empty payloads are incorrect';
  END IF;

  v_result := public.create_idea(v_request_a);
  IF v_result->>'outcome' <> 'already_exists'
     OR (v_result->>'idea_id')::uuid <> v_idea_a THEN
    RAISE EXCEPTION 'Create idempotency failed: %', v_result;
  END IF;

  v_result := public.create_idea(v_request_b);
  v_idea_b := (v_result->>'idea_id')::uuid;
  v_result := public.create_idea(v_request_c);
  v_idea_c := (v_result->>'idea_id')::uuid;
  v_result := public.create_idea(v_request_d);
  IF v_result->>'outcome' <> 'quota_exceeded' THEN
    RAISE EXCEPTION 'Fourth active idea was not rejected: %', v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, v_save_a, 1,
    '[{"stage_number":1,"data":{"description":"first draft"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied'
     OR v_result->>'result_revision' <> '2' THEN
    RAISE EXCEPTION 'Changed save failed: %', v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, v_save_a, 1,
    '[{"stage_number":1,"data":{"description":"first draft"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'replayed'
     OR v_result->>'original_outcome' <> 'applied'
     OR v_result->>'result_revision' <> '2' THEN
    RAISE EXCEPTION 'Same-key save replay failed: %', v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, v_save_a, 1,
    '[{"stage_number":1,"data":{"description":"different payload"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'idempotency_key_reuse' THEN
    RAISE EXCEPTION 'Changed payload did not reject key reuse: %', v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, v_save_noop, 2,
    '[{"stage_number":1,"data":{"description":"first draft"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'no_op'
     OR v_result->>'result_revision' <> '2' THEN
    RAISE EXCEPTION 'No-op save changed the revision: %', v_result;
  END IF;

  SELECT i.revision INTO v_revision
    FROM public.ideas AS i WHERE i.id = v_idea_a;
  IF v_revision <> 2 THEN
    RAISE EXCEPTION 'No-op save changed idea revision to %', v_revision;
  END IF;
  SELECT i.status INTO v_status
    FROM public.ideas AS i WHERE i.id = v_idea_a;
  IF v_status <> 'in_progress' THEN
    RAISE EXCEPTION 'No-op save changed idea status to %', v_status;
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, v_save_stale, 1,
    '[{"stage_number":1,"data":{"description":"stale"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'stale_revision' THEN
    RAISE EXCEPTION 'Stale save was not rejected: %', v_result;
  END IF;
  SELECT s.data INTO v_stage_data
    FROM public.idea_stages AS s
    WHERE s.idea_id = v_idea_a AND s.stage_number = 1;
  IF v_stage_data <> '{"description":"first draft"}'::jsonb THEN
    RAISE EXCEPTION 'Stale save overwrote newer stage content';
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, 'd1000000-0000-4000-8000-000000000005', 2,
    '[{"stage_number":1,"data":{}},{"stage_number":1,"data":{}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'invalid_input' THEN
    RAISE EXCEPTION 'Duplicate stage update was not rejected: %', v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, 'd1000000-0000-4000-8000-000000000007', 2,
    '[null]'::jsonb
  );
  IF v_result->>'outcome' <> 'invalid_input' THEN
    RAISE EXCEPTION 'Non-object stage update was not rejected: %', v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, 'd1000000-0000-4000-8000-000000000008', 2,
    '[{"stage_number":1,"data":{},"extra":true}]'::jsonb
  );
  IF v_result->>'outcome' <> 'invalid_input' THEN
    RAISE EXCEPTION 'Extra stage-update key was not rejected: %', v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, 'd1000000-0000-4000-8000-000000000006', 2,
    '[{"stage_number":7,"data":{}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'invalid_state' THEN
    RAISE EXCEPTION 'Stage 7 save was not rejected: %', v_result;
  END IF;

  v_result := public.request_idea_stage_confirmation(v_idea_a, 1::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Stage 1 confirmation request failed: %', v_result;
  END IF;
  v_result := public.request_idea_stage_confirmation(v_idea_a, 1::smallint);
  IF v_result->>'outcome' <> 'already_requested' THEN
    RAISE EXCEPTION 'Pending confirmation retry failed: %', v_result;
  END IF;

  v_result := public.confirm_idea_stage(v_idea_a, 1::smallint, 2);
  IF v_result->>'outcome' <> 'confirmed' THEN
    RAISE EXCEPTION 'Stage 1 confirmation failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_a, 1::smallint, 2);
  IF v_result->>'outcome' <> 'already_confirmed' THEN
    RAISE EXCEPTION 'Same-revision confirmation retry failed: %', v_result;
  END IF;

  SELECT i.revision INTO v_revision
    FROM public.ideas AS i WHERE i.id = v_idea_a;
  IF v_revision <> 2 THEN
    RAISE EXCEPTION 'Stage confirmation changed idea revision to %', v_revision;
  END IF;

  v_failed := false;
  BEGIN
    PERFORM public.save_idea_content(
      v_idea_a, v_save_failed, 2,
      '[{"stage_number":1,"data":{"description":"must roll back"}}]'::jsonb
    );
  EXCEPTION WHEN raise_exception THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'Injected save-ledger failure did not abort save';
  END IF;
  SELECT i.revision INTO v_revision
    FROM public.ideas AS i WHERE i.id = v_idea_a;
  SELECT s.status INTO v_status
    FROM public.idea_stages AS s
    WHERE s.idea_id = v_idea_a AND s.stage_number = 1;
  IF v_revision <> 2 OR v_status <> 'confirmed' THEN
    RAISE EXCEPTION 'Failed save left a revision or stage-state change';
  END IF;
  IF (
    SELECT s.data FROM public.idea_stages AS s
    WHERE s.idea_id = v_idea_a AND s.stage_number = 1
  ) <> '{"description":"first draft"}'::jsonb THEN
    RAISE EXCEPTION 'Failed save left changed stage content';
  END IF;

  v_result := public.save_idea_content(
    v_idea_a, v_save_confirmed_edit, 2,
    '[{"stage_number":1,"data":{"description":"edited after confirm"}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied'
     OR v_result->>'result_revision' <> '3' THEN
    RAISE EXCEPTION 'Confirmed-stage edit failed: %', v_result;
  END IF;

  SELECT s.status INTO v_status
    FROM public.idea_stages AS s
    WHERE s.idea_id = v_idea_a AND s.stage_number = 1;
  IF v_status <> 'in_progress' THEN
    RAISE EXCEPTION 'Edited confirmed stage was not demoted: %', v_status;
  END IF;
  SELECT s.status INTO v_status
    FROM public.idea_stages AS s
    WHERE s.idea_id = v_idea_a AND s.stage_number = 2;
  IF v_status <> 'in_progress' THEN
    RAISE EXCEPTION 'Confirmed edit incorrectly invalidated the next stage: %', v_status;
  END IF;

  FOR v_stage IN 2..6 LOOP
    v_result := public.request_idea_stage_confirmation(v_idea_a, v_stage::smallint);
    IF v_result->>'outcome' <> 'requested' THEN
      RAISE EXCEPTION 'Stage % confirmation request failed: %', v_stage, v_result;
    END IF;
    v_result := public.confirm_idea_stage(v_idea_a, v_stage::smallint, 3);
    IF v_result->>'outcome' <> 'confirmed' THEN
      RAISE EXCEPTION 'Stage % confirmation failed: %', v_stage, v_result;
    END IF;
  END LOOP;

  SELECT s.status INTO v_status
    FROM public.idea_stages AS s
    WHERE s.idea_id = v_idea_a AND s.stage_number = 7;
  IF v_status <> 'locked' THEN
    RAISE EXCEPTION 'Confirming Stage 6 unlocked Stage 7';
  END IF;

  v_result := public.confirm_idea_stage(v_idea_a, 7::smallint, 3);
  IF v_result->>'outcome' <> 'invalid_input' THEN
    RAISE EXCEPTION 'Stage 7 confirmation was not rejected: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_a, 1::smallint, 2);
  IF v_result->>'outcome' <> 'stale_revision' THEN
    RAISE EXCEPTION 'Stale stage confirmation was not rejected: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_owner_b::text, true);
  v_result := public.create_idea('e1000000-0000-4000-8000-000000000001');
  v_idea_other := (v_result->>'idea_id')::uuid;
  v_result := public.create_idea('e1000000-0000-4000-8000-000000000002');

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_owner_a::text, true);
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas AS i WHERE i.id = v_idea_other;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'RLS exposed another owner''s idea';
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.idea_stages AS s
    WHERE s.idea_id = v_idea_other;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'RLS exposed another owner''s stage data';
  END IF;
  v_result := public.delete_own_idea(v_idea_other);
  IF v_result->>'outcome' <> 'not_found_or_already_deleted' THEN
    RAISE EXCEPTION 'Cross-owner deletion was not generic: %', v_result;
  END IF;

  BEGIN
    INSERT INTO public.ideas (owner_id, creation_request_id)
    VALUES (v_owner_a, 'f1000000-0000-4000-8000-000000000001');
    RAISE EXCEPTION 'Authenticated direct idea insert unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    DELETE FROM public.ideas WHERE id = v_idea_a;
    RAISE EXCEPTION 'Authenticated direct idea delete unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

  BEGIN
    PERFORM a.deleted_idea_id FROM public.idea_deletion_audit AS a;
    RAISE EXCEPTION 'Authenticated audit read unexpectedly succeeded';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;

END
$test$;

RESET ROLE;

DO $snapshot_test$
DECLARE
  v_idea_id uuid;
  v_snapshot jsonb;
  v_count integer;
BEGIN
  SELECT i.id INTO v_idea_id
    FROM public.ideas AS i
    WHERE i.owner_id = 'a1000000-0000-4000-8000-000000000001'
      AND i.creation_request_id = 'c1000000-0000-4000-8000-000000000001';
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.idea_stage_confirmed_versions AS v
    WHERE v.idea_id = v_idea_id AND v.stage_number = 1;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Confirmed edit created % snapshots, expected 1', v_count;
  END IF;
  SELECT v.data INTO v_snapshot
    FROM public.idea_stage_confirmed_versions AS v
    WHERE v.idea_id = v_idea_id AND v.stage_number = 1;
  IF v_snapshot <> '{"description":"first draft"}'::jsonb THEN
    RAISE EXCEPTION 'Snapshot did not preserve the prior confirmed payload: %', v_snapshot;
  END IF;
  IF (
    SELECT pg_catalog.count(*) FROM public.idea_save_requests AS r
    WHERE r.request_id = 'd1000000-0000-4000-8000-000000000009'
  ) <> 0 THEN
    RAISE EXCEPTION 'Failed save left an idempotency ledger row';
  END IF;
END
$snapshot_test$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub',
  'a1000000-0000-4000-8000-000000000001',
  true
);
DO $participant_call_test$
DECLARE
  v_idea_id uuid;
  v_result jsonb;
BEGIN
  SELECT i.id INTO v_idea_id
    FROM public.ideas AS i
    WHERE i.creation_request_id = 'c1000000-0000-4000-8000-000000000001';
  v_result := public.delete_own_idea(v_idea_id);
  IF v_result->>'outcome' <> 'deleted' THEN
    RAISE EXCEPTION 'Participant deletion failed: %', v_result;
  END IF;
  v_result := public.create_idea('c1000000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'already_deleted' THEN
    RAISE EXCEPTION 'Deletion tombstone did not block creation-key reuse: %', v_result;
  END IF;
  v_result := public.create_idea('c1000000-0000-4000-8000-000000000004');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Participant deletion did not release a quota slot: %', v_result;
  END IF;
END
$participant_call_test$;

RESET ROLE;

DO $participant_deletion_test$
DECLARE
  v_deleted_idea uuid;
  v_count integer;
BEGIN
  SELECT a.deleted_idea_id INTO v_deleted_idea
    FROM public.idea_deletion_audit AS a
    WHERE a.owner_id = 'a1000000-0000-4000-8000-000000000001'
      AND a.creation_request_id = 'c1000000-0000-4000-8000-000000000001'
      AND a.operation = 'participant_delete'
      AND a.reason_code = 'participant_requested_deletion'
      AND a.actor_id = 'a1000000-0000-4000-8000-000000000001';
  IF v_deleted_idea IS NULL THEN
    RAISE EXCEPTION 'Participant deletion audit record is missing or incorrect';
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.idea_deletion_audit AS a
    WHERE a.deleted_idea_id = v_deleted_idea;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Participant deletion produced % audit records', v_count;
  END IF;

  IF EXISTS (SELECT 1 FROM public.idea_stages WHERE idea_id = v_deleted_idea)
     OR EXISTS (
       SELECT 1 FROM public.idea_stage_confirmed_versions
       WHERE idea_id = v_deleted_idea
     )
     OR EXISTS (
       SELECT 1 FROM public.idea_save_requests
       WHERE idea_id = v_deleted_idea
     )
     OR EXISTS (
       SELECT 1 FROM public.idea_dossier_versions
       WHERE idea_id = v_deleted_idea
     )
     OR EXISTS (
       SELECT 1 FROM public.idea_dossier_edit_requests
       WHERE idea_id = v_deleted_idea
     ) THEN
    RAISE EXCEPTION 'Participant deletion left dependent idea records';
  END IF;
END
$participant_deletion_test$;

UPDATE public.ideas
  SET status = 'submitted',
      submitted_at = pg_catalog.clock_timestamp()
  WHERE owner_id = 'a1000000-0000-4000-8000-000000000001'
    AND creation_request_id = 'c1000000-0000-4000-8000-000000000002';

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub',
  'a1000000-0000-4000-8000-000000000001',
  true
);
DO $submitted_test$
DECLARE
  v_idea_id uuid;
  v_result jsonb;
BEGIN
  SELECT i.id INTO v_idea_id
    FROM public.ideas AS i
    WHERE i.creation_request_id = 'c1000000-0000-4000-8000-000000000002';
  v_result := public.delete_own_idea(v_idea_id);
  IF v_result->>'outcome' <> 'invalid_state' THEN
    RAISE EXCEPTION 'Submitted idea deletion was not rejected: %', v_result;
  END IF;
END
$submitted_test$;
RESET ROLE;

DO $account_cascade_test$
DECLARE
  v_count integer;
  v_failed boolean := false;
BEGIN
  PERFORM pg_catalog.set_config('m7r2.fail_account_audit', 'on', true);
  BEGIN
    DELETE FROM auth.users
      WHERE id = 'b1000000-0000-4000-8000-000000000002';
  EXCEPTION WHEN raise_exception THEN
    v_failed := true;
  END;
  PERFORM pg_catalog.set_config('m7r2.fail_account_audit', 'off', true);
  IF NOT v_failed THEN
    RAISE EXCEPTION 'Injected account-audit failure did not abort account deletion';
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.idea_deletion_audit AS a
    WHERE a.owner_id = 'b1000000-0000-4000-8000-000000000002';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Failed account deletion left % audit rows', v_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM auth.users AS u
      WHERE u.id = 'b1000000-0000-4000-8000-000000000002'
  ) OR (
    SELECT pg_catalog.count(*)
      FROM public.ideas AS i
      WHERE i.owner_id = 'b1000000-0000-4000-8000-000000000002'
  ) <> 2 THEN
    RAISE EXCEPTION 'Failed account deletion left partial user or idea removal';
  END IF;

  DELETE FROM auth.users
    WHERE id = 'b1000000-0000-4000-8000-000000000002';

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.idea_deletion_audit AS a
    WHERE a.owner_id = 'b1000000-0000-4000-8000-000000000002'
      AND a.operation = 'account_cascade'
      AND a.reason_code = 'account_deletion_cascade'
      AND a.actor_id IS NULL;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Account deletion created % audit rows, expected 2', v_count;
  END IF;
  IF (
    SELECT pg_catalog.count(*) FROM public.idea_deletion_audit AS a
    WHERE a.owner_id = 'b1000000-0000-4000-8000-000000000002'
      AND a.creation_request_id IN (
        'e1000000-0000-4000-8000-000000000001',
        'e1000000-0000-4000-8000-000000000002'
      )
  ) <> 2 THEN
    RAISE EXCEPTION 'Account deletion audit does not match both idea creation keys';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.ideas
    WHERE owner_id = 'b1000000-0000-4000-8000-000000000002'
  ) THEN
    RAISE EXCEPTION 'Successful account deletion left ideas';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.idea_stages AS s
    JOIN public.idea_deletion_audit AS a ON a.deleted_idea_id = s.idea_id
    WHERE a.owner_id = 'b1000000-0000-4000-8000-000000000002'
  ) THEN
    RAISE EXCEPTION 'Account deletion left dependent stage rows';
  END IF;
END
$account_cascade_test$;

ROLLBACK;
