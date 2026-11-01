-- Run against an isolated local Supabase database as supabase_admin.
-- All fixture users, ideas, evaluation data, drafts, and versions roll back.
BEGIN;

DO $package_7b_schema_test$
DECLARE
  v_count integer;
BEGIN
  IF (
    SELECT pg_catalog.count(*)
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'
        AND relation.relname IN (
          'idea_feedback_drafts',
          'idea_feedback_versions'
        )
        AND relation.relrowsecurity
        AND relation.relforcerowsecurity
  ) <> 2 THEN
    RAISE EXCEPTION 'Feedback tables must all have forced RLS enabled';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_feedback_drafts', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.idea_feedback_versions', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.idea_feedback_drafts', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.idea_feedback_versions', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'Feedback tables expose unsafe direct access';
  END IF;

  IF pg_catalog.has_function_privilege(
       'anon', 'public.create_idea_feedback_draft(uuid,text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'service_role', 'public.publish_idea_feedback_draft(uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.create_idea_feedback_draft(uuid,text)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.publish_idea_feedback_draft(uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.get_own_idea_published_feedback(uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Feedback RPC execution grants are unsafe';
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM pg_catalog.pg_proc AS procedure
    WHERE procedure.oid = 'public.publish_idea_feedback_draft(uuid)'::regprocedure;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Feedback publication RPC is missing';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM pg_catalog.pg_constraint AS constraint_row
      JOIN pg_catalog.pg_attribute AS attribute
        ON attribute.attrelid = constraint_row.conrelid
       AND attribute.attnum = constraint_row.conkey[1]
      WHERE constraint_row.conrelid =
          'public.idea_feedback_drafts'::regclass
        AND constraint_row.contype = 'u'
        AND constraint_row.conkey = ARRAY[attribute.attnum]::smallint[]
        AND attribute.attname = 'cycle_id'
  ) THEN
    RAISE EXCEPTION 'The obsolete global cycle_id uniqueness constraint remains';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_index AS index_row
      JOIN pg_catalog.pg_class AS index_relation
        ON index_relation.oid = index_row.indexrelid
      WHERE index_relation.relnamespace = 'public'::regnamespace
        AND index_relation.relname =
          'idea_feedback_drafts_one_active_cycle_idx'
        AND index_row.indrelid =
          'public.idea_feedback_drafts'::regclass
        AND index_row.indisunique
        AND index_row.indisvalid
        AND index_row.indisready
        AND index_row.indnkeyatts = 1
        AND index_row.indnatts = 1
        AND index_row.indexprs IS NULL
        AND EXISTS (
          SELECT 1
            FROM pg_catalog.pg_attribute AS attribute
            WHERE attribute.attrelid = index_row.indrelid
              AND attribute.attname = 'cycle_id'
              AND NOT attribute.attisdropped
              AND index_row.indkey[0] = attribute.attnum
        )
        AND pg_catalog.pg_get_expr(
          index_row.indpred, index_row.indrelid
        ) = '(status = ''active''::text)'
  ) THEN
    RAISE EXCEPTION 'The active-only unique cycle index is missing or incorrect';
  END IF;
END
$package_7b_schema_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    '7b3a0000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', '7b3a-owner@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    '7b3a0000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', '7b3a-evaluator@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    '7b3a0000-0000-4000-8000-000000000003', 'authenticated',
    'authenticated', '7b3a-publisher@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    '7b3a0000-0000-4000-8000-000000000004', 'authenticated',
    'authenticated', '7b3a-unauthorized@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  );

INSERT INTO public.idea_evaluation_permissions (
  user_id, permission, granted_by, reason
)
VALUES
  (
    '7b3a0000-0000-4000-8000-000000000002',
    'human_evaluator',
    '7b3a0000-0000-4000-8000-000000000001',
    'Rollback-only feedback publication fixture.'
  ),
  (
    '7b3a0000-0000-4000-8000-000000000002',
    'feedback_publisher',
    '7b3a0000-0000-4000-8000-000000000001',
    'Rollback-only self-publication guard fixture.'
  ),
  (
    '7b3a0000-0000-4000-8000-000000000003',
    'feedback_publisher',
    '7b3a0000-0000-4000-8000-000000000001',
    'Rollback-only feedback publication fixture.'
  ),
  (
    '7b3a0000-0000-4000-8000-000000000004',
    'human_evaluator',
    '7b3a0000-0000-4000-8000-000000000001',
    'Rollback-only evaluator/publisher separation fixture.'
  );

SET LOCAL ROLE javaneh_identity_executor;
INSERT INTO public.ideas (
  id, owner_id, status, revision, creation_request_id, current_step, submitted_at
)
VALUES (
  '7b3a1000-0000-4000-8000-000000000001',
  '7b3a0000-0000-4000-8000-000000000001',
  'submitted',
  1,
  '7b3a2000-0000-4000-8000-000000000001',
  7,
  pg_catalog.now() - INTERVAL '1 day'
);

INSERT INTO public.idea_stages (
  idea_id, stage_number, data, status, confirmed_at
)
SELECT
  '7b3a1000-0000-4000-8000-000000000001',
  stage_number,
  '{}'::jsonb,
  CASE
    WHEN stage_number = 7 THEN 'locked'
    WHEN stage_number <= 2 THEN 'in_progress'
    ELSE 'confirmed'
  END,
  CASE
    WHEN stage_number BETWEEN 3 AND 6 THEN pg_catalog.now()
    ELSE NULL
  END
FROM pg_catalog.generate_series(1, 7) AS stages(stage_number);

UPDATE public.idea_stages
SET status = 'confirmed',
    confirmed_at = pg_catalog.clock_timestamp()
WHERE idea_id = '7b3a1000-0000-4000-8000-000000000001'
  AND stage_number = 1;

UPDATE public.idea_stages
SET status = 'confirmed',
    confirmed_at = pg_catalog.clock_timestamp()
WHERE idea_id = '7b3a1000-0000-4000-8000-000000000001'
  AND stage_number = 2;

INSERT INTO public.idea_evaluation_cycles (
  cycle_id, idea_id, status, assigned_evaluator_id, assigned_at,
  evaluated_revision, started_at, completed_at
)
VALUES (
  '7b3a3000-0000-4000-8000-000000000001',
  '7b3a1000-0000-4000-8000-000000000001',
  'completed',
  '7b3a0000-0000-4000-8000-000000000002',
  pg_catalog.now() - INTERVAL '2 minutes',
  1,
  pg_catalog.now() - INTERVAL '1 minute',
  pg_catalog.now()
);

SET CONSTRAINTS ALL IMMEDIATE;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', '7b3a0000-0000-4000-8000-000000000002', true
);

DO $package_7b_initial_publication_test$
DECLARE
  v_idea_id uuid := '7b3a1000-0000-4000-8000-000000000001';
  v_draft_id uuid;
  v_version_id uuid;
  v_error_message text;
  v_result jsonb;
BEGIN
  v_result := public.create_idea_feedback_draft(
    v_idea_id, 'Initial private evaluator feedback'
  );
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Initial active feedback draft was not created: %', v_result;
  END IF;
  v_draft_id := (v_result->>'draft_id')::uuid;
  PERFORM pg_catalog.set_config(
    'test.package_7b_draft_one', v_draft_id::text, true
  );

  v_result := public.create_idea_feedback_draft(
    v_idea_id, 'Duplicate initial draft'
  );
  IF v_result->>'outcome' <> 'draft_exists' THEN
    RAISE EXCEPTION 'A second active initial draft was not rejected: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '7b3a0000-0000-4000-8000-000000000004', true
  );
  BEGIN
    PERFORM public.publish_idea_feedback_draft(v_draft_id);
    RAISE EXCEPTION 'An unauthorized user published an evaluator draft';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
    IF v_error_message <> 'Feedback publisher authorization required' THEN
      RAISE EXCEPTION
        'Unauthorized publication failed for an unexpected reason: %',
        v_error_message;
    END IF;
  END;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '7b3a0000-0000-4000-8000-000000000002', true
  );
  v_result := public.publish_idea_feedback_draft(v_draft_id);
  IF v_result->>'outcome' <> 'same_user' THEN
    RAISE EXCEPTION 'Evaluator self-publication was not rejected: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '7b3a0000-0000-4000-8000-000000000003', true
  );
  v_result := public.publish_idea_feedback_draft(v_draft_id);
  IF v_result->>'outcome' <> 'published'
     OR v_result->>'version_number' <> '1' THEN
    RAISE EXCEPTION 'Initial feedback publication failed: %', v_result;
  END IF;
  v_version_id := (v_result->>'version_id')::uuid;
  PERFORM pg_catalog.set_config(
    'test.package_7b_version_one', v_version_id::text, true
  );

  v_result := public.publish_idea_feedback_draft(v_draft_id);
  IF v_result->>'outcome' <> 'already_consumed' THEN
    RAISE EXCEPTION 'A consumed draft was published again: %', v_result;
  END IF;
END
$package_7b_initial_publication_test$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', '7b3a0000-0000-4000-8000-000000000002', true
);

DO $package_7b_correction_creation_test$
DECLARE
  v_idea_id uuid := '7b3a1000-0000-4000-8000-000000000001';
  v_version_one uuid :=
    pg_catalog.current_setting('test.package_7b_version_one')::uuid;
  v_draft_id uuid;
  v_result jsonb;
BEGIN
  v_result := public.create_correction_idea_feedback_draft(
    v_idea_id, 'First correction feedback'
  );
  IF v_result->>'outcome' <> 'created'
     OR (v_result->>'previous_published_version_id')::uuid
       IS DISTINCT FROM v_version_one THEN
    RAISE EXCEPTION 'First correction did not reference version one: %',
      v_result;
  END IF;
  v_draft_id := (v_result->>'draft_id')::uuid;
  PERFORM pg_catalog.set_config(
    'test.package_7b_draft_two', v_draft_id::text, true
  );

  v_result := public.create_correction_idea_feedback_draft(
    v_idea_id, 'Second simultaneous correction'
  );
  IF v_result->>'outcome' <> 'draft_exists' THEN
    RAISE EXCEPTION 'A second active correction draft was not rejected: %',
      v_result;
  END IF;
END
$package_7b_correction_creation_test$;

RESET ROLE;
SET LOCAL ROLE javaneh_identity_executor;
DO $package_7b_active_index_test$
DECLARE
  v_constraint_name text;
BEGIN
  BEGIN
    INSERT INTO public.idea_feedback_drafts (
      draft_id, idea_id, cycle_id, evaluator_user_id,
      feedback_content, status
    )
    VALUES (
      '7b3a4000-0000-4000-8000-000000000099',
      '7b3a1000-0000-4000-8000-000000000001',
      '7b3a3000-0000-4000-8000-000000000001',
      '7b3a0000-0000-4000-8000-000000000002',
      'Duplicate active row',
      'active'
    );
    RAISE EXCEPTION 'The partial unique index allowed a duplicate active row';
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint_name = CONSTRAINT_NAME;
    IF v_constraint_name <> 'idea_feedback_drafts_one_active_cycle_idx' THEN
      RAISE EXCEPTION
        'Duplicate active row violated unexpected constraint/index: %',
        v_constraint_name;
    END IF;
  END;
END
$package_7b_active_index_test$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', '7b3a0000-0000-4000-8000-000000000003', true
);

DO $package_7b_correction_publication_test$
DECLARE
  v_idea_id uuid := '7b3a1000-0000-4000-8000-000000000001';
  v_draft_two uuid :=
    pg_catalog.current_setting('test.package_7b_draft_two')::uuid;
  v_version_two uuid;
  v_draft_three uuid;
  v_version_three uuid;
  v_result jsonb;
BEGIN
  v_result := public.publish_idea_feedback_draft(v_draft_two);
  IF v_result->>'outcome' <> 'published'
     OR v_result->>'version_number' <> '2' THEN
    RAISE EXCEPTION 'First correction publication was not version two: %',
      v_result;
  END IF;
  v_version_two := (v_result->>'version_id')::uuid;
  PERFORM pg_catalog.set_config(
    'test.package_7b_version_two', v_version_two::text, true
  );

  v_result := public.publish_idea_feedback_draft(v_draft_two);
  IF v_result->>'outcome' <> 'already_consumed' THEN
    RAISE EXCEPTION 'A consumed correction draft was published again: %',
      v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '7b3a0000-0000-4000-8000-000000000002', true
  );
  v_result := public.create_correction_idea_feedback_draft(
    v_idea_id, 'Second correction feedback'
  );
  IF v_result->>'outcome' <> 'created'
     OR (v_result->>'previous_published_version_id')::uuid
       IS DISTINCT FROM v_version_two THEN
    RAISE EXCEPTION 'Second correction did not reference version two: %',
      v_result;
  END IF;
  v_draft_three := (v_result->>'draft_id')::uuid;
  PERFORM pg_catalog.set_config(
    'test.package_7b_draft_three', v_draft_three::text, true
  );

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '7b3a0000-0000-4000-8000-000000000003', true
  );
  v_result := public.publish_idea_feedback_draft(v_draft_three);
  IF v_result->>'outcome' <> 'published'
     OR v_result->>'version_number' <> '3' THEN
    RAISE EXCEPTION 'Second correction publication was not version three: %',
      v_result;
  END IF;
  v_version_three := (v_result->>'version_id')::uuid;
  PERFORM pg_catalog.set_config(
    'test.package_7b_version_three', v_version_three::text, true
  );

  v_result := public.publish_idea_feedback_draft(v_draft_three);
  IF v_result->>'outcome' <> 'already_consumed' THEN
    RAISE EXCEPTION 'The latest consumed draft was published again: %',
      v_result;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '7b3a0000-0000-4000-8000-000000000001', true
  );
  v_result := public.get_own_idea_published_feedback(v_idea_id);
  IF v_result->>'outcome' <> 'available'
     OR v_result->>'version_number' <> '3'
     OR v_result->>'feedback_content' <> 'Second correction feedback'
     OR v_result ? 'versions'
     OR v_result ? 'history' THEN
    RAISE EXCEPTION 'Participant feedback did not expose latest version only: %',
      v_result;
  END IF;
END
$package_7b_correction_publication_test$;

RESET ROLE;
SET LOCAL ROLE javaneh_identity_executor;
DO $package_7b_feedback_storage_test$
DECLARE
  v_cycle_id uuid := '7b3a3000-0000-4000-8000-000000000001';
  v_version_one uuid :=
    pg_catalog.current_setting('test.package_7b_version_one')::uuid;
  v_version_two uuid :=
    pg_catalog.current_setting('test.package_7b_version_two')::uuid;
  v_version_three uuid :=
    pg_catalog.current_setting('test.package_7b_version_three')::uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_feedback_drafts AS draft
      WHERE draft.draft_id =
          pg_catalog.current_setting('test.package_7b_draft_one')::uuid
        AND draft.cycle_id = v_cycle_id
        AND draft.status = 'consumed'
        AND draft.publication_version_id = v_version_one
  )
     OR NOT EXISTS (
       SELECT 1
         FROM public.idea_feedback_drafts AS draft
         WHERE draft.draft_id =
             pg_catalog.current_setting('test.package_7b_draft_two')::uuid
           AND draft.cycle_id = v_cycle_id
           AND draft.status = 'consumed'
           AND draft.publication_version_id = v_version_two
           AND draft.previous_published_version_id = v_version_one
     )
     OR NOT EXISTS (
       SELECT 1
         FROM public.idea_feedback_drafts AS draft
         WHERE draft.draft_id =
             pg_catalog.current_setting('test.package_7b_draft_three')::uuid
           AND draft.cycle_id = v_cycle_id
           AND draft.status = 'consumed'
           AND draft.publication_version_id = v_version_three
           AND draft.previous_published_version_id = v_version_two
     )
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_feedback_drafts AS draft
         WHERE draft.cycle_id = v_cycle_id
     ) <> 3 THEN
    RAISE EXCEPTION 'Published drafts were not preserved as consumed history';
  END IF;

  IF (
    SELECT version.previous_version_id
      FROM public.idea_feedback_versions AS version
      WHERE version.version_id = v_version_one
  ) IS NOT NULL
     OR (
       SELECT version.previous_version_id
         FROM public.idea_feedback_versions AS version
         WHERE version.version_id = v_version_two
     ) IS DISTINCT FROM v_version_one
     OR (
       SELECT version.previous_version_id
         FROM public.idea_feedback_versions AS version
         WHERE version.version_id = v_version_three
     ) IS DISTINCT FROM v_version_two
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_feedback_versions AS version
         WHERE version.cycle_id = v_cycle_id
     ) <> 3
     OR (
       SELECT version.version_number
         FROM public.idea_feedback_versions AS version
         WHERE version.version_id = v_version_one
     ) <> 1
     OR (
       SELECT version.version_number
         FROM public.idea_feedback_versions AS version
         WHERE version.version_id = v_version_two
     ) <> 2
     OR (
       SELECT version.version_number
         FROM public.idea_feedback_versions AS version
         WHERE version.version_id = v_version_three
     ) <> 3 THEN
    RAISE EXCEPTION 'Published versions are not sequentially linked';
  END IF;
END
$package_7b_feedback_storage_test$;

RESET ROLE;
DO $package_7b_feedback_immutability_test$
DECLARE
  v_version_one uuid :=
    pg_catalog.current_setting('test.package_7b_version_one')::uuid;
  v_version_two uuid :=
    pg_catalog.current_setting('test.package_7b_version_two')::uuid;
  v_error_message text;
BEGIN
  BEGIN
    UPDATE public.idea_feedback_versions
      SET feedback_content = 'Tampered published feedback'
      WHERE version_id = v_version_one;
    RAISE EXCEPTION 'A published feedback version was modified';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
    IF v_error_message <> 'Published feedback versions are immutable' THEN
      RAISE EXCEPTION
        'Published feedback update failed for an unexpected reason: %',
        v_error_message;
    END IF;
  END;

  IF (
    SELECT version.feedback_content
      FROM public.idea_feedback_versions AS version
      WHERE version.version_id = v_version_one
  ) <> 'Initial private evaluator feedback' THEN
    RAISE EXCEPTION 'Published feedback content changed after rejected update';
  END IF;

  BEGIN
    DELETE FROM public.idea_feedback_versions
      WHERE version_id = v_version_two;
    RAISE EXCEPTION 'A published feedback version was deleted';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
    IF v_error_message <> 'Published feedback history is immutable' THEN
      RAISE EXCEPTION
        'Published feedback deletion failed for an unexpected reason: %',
        v_error_message;
    END IF;
  END;

  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_feedback_versions AS version
      WHERE version.version_id = v_version_two
        AND version.feedback_content = 'First correction feedback'
  ) THEN
    RAISE EXCEPTION 'Published feedback version was removed after rejected delete';
  END IF;
END
$package_7b_feedback_immutability_test$;

ROLLBACK;
