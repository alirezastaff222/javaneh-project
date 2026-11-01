-- Run against an isolated local/test database as supabase_admin.
-- All fixtures, stage operations, and classifications are rolled back.
BEGIN;

DO $phase7_taxonomy_test$
DECLARE
  v_count integer;
BEGIN
  IF (
    SELECT pg_catalog.count(*)
    FROM public.thematic_taxonomy_versions AS taxonomy
    WHERE taxonomy.version = 'phase7.v1' AND taxonomy.active
  ) <> 1 THEN
    RAISE EXCEPTION 'The Phase 7 taxonomy version is missing or inactive';
  END IF;

  WITH expected(axis_id, official_name, official_definition) AS (
    VALUES
      (
        'resource_efficiency',
        'بهینه‌سازی مصرف و کاهش اتلاف منابع با مشارکت مردم',
        'فعال‌سازی مشارکت مردم و شکل‌دهی رفتارهای مسئولانه و پایدار در مدیریت مصرف انرژی، آب، مواد غذایی، کالا و سایر منابع و کاهش اسراف و هدررفت'
      ),
      (
        'domestic_production',
        'تقویت فرهنگ و کنش مردمی در حمایت از تولید داخلی',
        'تقویت نگرش، ترجیحات و رفتارهای مردم در حمایت آگاهانه و پایدار از تولید داخلی و توسعه الگوهای اجتماعی و فرهنگی پشتیبان تولید ملی'
      ),
      (
        'economic_mutual_aid',
        'توسعه یاریگری و الگوهای همکاری مردمی در اقتصاد',
        'توسعه سازوکارها و الگوهای نوآورانه یاریگری، مواسات، حمایت متقابل و همکاری اقتصادی مردم از طریق به‌اشتراک‌گذاری و به‌کارگیری منابع، دارایی‌ها، مهارت‌ها و ظرفیت‌های فردی و جمعی برای پاسخ به نیازهای اقتصادی و کاهش فشارهای معیشتی'
      ),
      (
        'social_resilience',
        'ارتقای تاب‌آوری اجتماعی در مواجهه با فشارهای اقتصادی',
        'تقویت ظرفیت افراد و اجتماعات برای سازگاری و مواجهه جمعی با فشارها و پیامدهای اقتصادی از طریق تقویت پیوندهای اجتماعی، همیاری، اعتماد، امید و ظرفیت‌های حمایت متقابل'
      ),
      (
        'social_mobilization',
        'نوآوری در ارتباطات، روایت و بسیج اجتماعی',
        'توسعه روایت‌ها، الگوهای ارتباطی و ابتکارات رسانه‌ای نوآورانه برای افزایش آگاهی و انگیزه عمومی، اصلاح نگرش‌ها و رفتارها و ترغیب مردم به مشارکت و کنش هدفمند و پایدار'
      ),
      (
        'vulnerable_empowerment',
        'نوآوری در الگوهای توانمندسازی و حمایت از اقشار آسیب‌پذیر',
        'توسعه الگوها و راه‌حل‌های نوآورانه برای حمایت و توانمندسازی اقشار آسیب‌پذیر با هدف تقویت ظرفیت و عاملیت آنان، کاهش آسیب‌پذیری و افزایش توان مواجهه با فشارهای اقتصادی'
      )
  )
  SELECT pg_catalog.count(*) INTO v_count
  FROM expected AS expected
  JOIN public.thematic_axes AS axis
    ON axis.taxonomy_version = 'phase7.v1'
   AND axis.axis_id = expected.axis_id
   AND axis.official_name = expected.official_name
   AND axis.official_definition = expected.official_definition
   AND axis.active;

  IF v_count <> 6 OR (
    SELECT pg_catalog.count(*)
    FROM public.thematic_axes AS axis
    WHERE axis.taxonomy_version = 'phase7.v1' AND axis.active
  ) <> 6 THEN
    RAISE EXCEPTION 'The six official active taxonomy rows differ from the approved names or definitions';
  END IF;

  INSERT INTO public.thematic_axes (
    taxonomy_version, axis_id, official_name, official_definition, active
  )
  SELECT
    axis.taxonomy_version,
    axis.axis_id,
    axis.official_name,
    axis.official_definition,
    axis.active
  FROM public.thematic_axes AS axis
  WHERE axis.taxonomy_version = 'phase7.v1'
  ON CONFLICT (taxonomy_version, axis_id) DO UPDATE
  SET official_name = EXCLUDED.official_name,
      official_definition = EXCLUDED.official_definition,
      active = EXCLUDED.active;

  IF (
    SELECT pg_catalog.count(*)
    FROM public.thematic_axes AS axis
    WHERE axis.taxonomy_version = 'phase7.v1'
  ) <> 6 THEN
    RAISE EXCEPTION 'Idempotent taxonomy seed created duplicate axis rows';
  END IF;

  IF pg_catalog.has_table_privilege(
    'authenticated', 'public.idea_classification_results', 'INSERT'
  ) OR pg_catalog.has_table_privilege(
    'authenticated', 'public.idea_classification_results', 'UPDATE'
  ) OR pg_catalog.has_table_privilege(
    'authenticated', 'public.idea_classification_results', 'DELETE'
  ) OR pg_catalog.has_table_privilege(
    'authenticated', 'public.idea_classification_state', 'UPDATE'
  ) OR pg_catalog.has_table_privilege(
    'service_role', 'public.idea_classification_results', 'INSERT'
  ) OR pg_catalog.has_table_privilege(
    'service_role', 'public.idea_classification_state', 'UPDATE'
  ) OR pg_catalog.has_table_privilege(
    'authenticated', 'public.idea_classification_state', 'SELECT'
  ) OR pg_catalog.has_any_column_privilege(
    'authenticated', 'public.idea_classification_state', 'SELECT'
  ) OR pg_catalog.has_column_privilege(
    'authenticated', 'public.idea_classification_state', 'idea_id', 'SELECT'
  ) OR pg_catalog.has_column_privilege(
    'authenticated', 'public.idea_classification_state', 'status', 'SELECT'
  ) OR pg_catalog.has_column_privilege(
    'authenticated', 'public.idea_classification_state',
    'lease_expires_at', 'SELECT'
  ) OR pg_catalog.has_column_privilege(
    'authenticated', 'public.idea_classification_state', 'attempt_token', 'SELECT'
  ) OR pg_catalog.has_column_privilege(
    'authenticated', 'public.idea_classification_state', 'attempt_count', 'SELECT'
  ) OR pg_catalog.has_column_privilege(
    'authenticated', 'public.idea_classification_state', 'retry_after', 'SELECT'
  ) OR pg_catalog.has_column_privilege(
    'authenticated', 'public.idea_classification_state', 'updated_at', 'SELECT'
  ) OR pg_catalog.has_table_privilege(
    'authenticated', 'public.idea_classification_state', 'INSERT'
  ) OR pg_catalog.has_table_privilege(
    'authenticated', 'public.idea_classification_state', 'UPDATE'
  ) OR pg_catalog.has_table_privilege(
    'authenticated', 'public.idea_classification_state', 'DELETE'
  ) OR NOT pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_own_idea_classification_status(uuid)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'service_role',
    'public.get_own_idea_classification_status(uuid)',
    'EXECUTE'
  ) OR NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.claim_idea_classification(uuid,uuid,uuid,uuid,text,text,uuid)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'authenticated',
    'public.claim_idea_classification(uuid,uuid,uuid,uuid,text,text,uuid)',
    'EXECUTE'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS function_row
    WHERE function_row.oid =
      'public.get_own_idea_classification_status(uuid)'::pg_catalog.regprocedure
      AND function_row.proowner = 'javaneh_identity_executor'::pg_catalog.regrole
      AND function_row.prosecdef
      AND function_row.proconfig = ARRAY['search_path=pg_catalog']
  ) THEN
    RAISE EXCEPTION
      'Classification access is not limited to participant-readable metadata';
  END IF;
END
$phase7_taxonomy_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a9940000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', 'phase7-owner-a@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9940000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', 'phase7-owner-b@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  );

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9940000-0000-4000-8000-000000000001', true
);

DO $phase7_lifecycle_test$
DECLARE
  v_idea_id uuid;
  v_result jsonb;
  v_revision integer;
  v_stage_1_revision_id uuid;
  v_stage_2_revision_id uuid;
  v_projection jsonb;
BEGIN
  v_result := public.create_idea('a9950000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Phase 7 idea fixture creation failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;
  PERFORM pg_catalog.set_config('test.phase7_idea_id', v_idea_id::text, true);

  v_result := public.save_idea_content(
    v_idea_id, 'a9960000-0000-4000-8000-000000000001', 1,
    '[{"stage_number":1,"data":{"content":"A confirmed problem statement about reducing household food waste."}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Stage 1 draft save failed: %', v_result;
  END IF;
  v_revision := (v_result->>'result_revision')::integer;
  v_result := public.request_idea_stage_confirmation(v_idea_id, 1::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Stage 1 confirmation request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 1::smallint, v_revision);
  IF v_result->>'outcome' <> 'confirmed'
     OR public.get_own_idea_classification_status(v_idea_id)->>'status'
       <> 'missing' THEN
    RAISE EXCEPTION 'Classification was scheduled before Stage 2 confirmation';
  END IF;

  v_result := public.save_idea_content(
    v_idea_id, 'a9960000-0000-4000-8000-000000000002', v_revision,
    '[{"stage_number":2,"data":{"content":"Local households can share cooking skills and coordinate food distribution."}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Stage 2 draft save failed: %', v_result;
  END IF;
  IF public.get_own_idea_classification_status(v_idea_id)->>'status'
     <> 'missing' THEN
    RAISE EXCEPTION 'Stage 2 autosave scheduled classification before confirmation';
  END IF;
  v_revision := (v_result->>'result_revision')::integer;
  v_result := public.request_idea_stage_confirmation(v_idea_id, 2::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Stage 2 confirmation request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 2::smallint, v_revision);
  IF v_result->>'outcome' <> 'confirmed' THEN
    RAISE EXCEPTION 'Stage 2 confirmation failed: %', v_result;
  END IF;

  SELECT stage.confirmed_version_id INTO v_stage_1_revision_id
  FROM public.idea_stages AS stage
  WHERE stage.idea_id = v_idea_id AND stage.stage_number = 1;
  SELECT stage.confirmed_version_id INTO v_stage_2_revision_id
  FROM public.idea_stages AS stage
  WHERE stage.idea_id = v_idea_id AND stage.stage_number = 2;
  v_projection := public.get_own_idea_classification_status(v_idea_id);
  IF v_stage_1_revision_id IS NULL OR v_stage_2_revision_id IS NULL
     OR v_projection->>'status' <> 'pending'
     OR (v_projection->>'source_stage_1_revision_id')::uuid
       <> v_stage_1_revision_id
     OR (v_projection->>'source_stage_2_revision_id')::uuid
       <> v_stage_2_revision_id THEN
    RAISE EXCEPTION 'Stage 2 confirmation did not durably queue the current source revisions';
  END IF;
  IF v_projection ?| ARRAY[
    'attempt_token', 'lease_expires_at', 'attempt_count', 'retry_after',
    'last_failure_category', 'updated_at'
  ] OR (
    SELECT pg_catalog.count(*)
    FROM pg_catalog.jsonb_object_keys(v_projection)
  ) <> 5 THEN
    RAISE EXCEPTION 'Status projection exposed operational metadata: %',
      v_projection;
  END IF;

  PERFORM pg_catalog.set_config(
    'test.phase7_source_1', v_stage_1_revision_id::text, true
  );
  PERFORM pg_catalog.set_config(
    'test.phase7_source_2', v_stage_2_revision_id::text, true
  );
  PERFORM pg_catalog.set_config('test.phase7_revision', v_revision::text, true);
END
$phase7_lifecycle_test$;

RESET ROLE;
DO $phase7_backfill_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_first_run integer;
  v_second_run integer;
BEGIN
  DELETE FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;

  v_first_run := public.backfill_phase7_classification_state();
  IF v_first_run <> 1
     OR (
       SELECT state.status
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) <> 'pending'
     OR (
       SELECT state.source_stage_1_revision_id
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) <> pg_catalog.current_setting('test.phase7_source_1')::uuid
     OR (
       SELECT state.source_stage_2_revision_id
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) <> pg_catalog.current_setting('test.phase7_source_2')::uuid THEN
    RAISE EXCEPTION 'The backfill did not queue the eligible legacy idea';
  END IF;

  v_second_run := public.backfill_phase7_classification_state();
  IF v_second_run <> 0 OR (
    SELECT pg_catalog.count(*)
    FROM public.idea_classification_state AS state
    WHERE state.idea_id = v_idea_id
  ) <> 1 THEN
    RAISE EXCEPTION 'Rerunning the backfill duplicated or changed queued work';
  END IF;
END
$phase7_backfill_test$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9940000-0000-4000-8000-000000000002', true
);
DO $phase7_incomplete_backfill_test$
DECLARE
  v_idea_id uuid;
  v_revision integer;
  v_result jsonb;
BEGIN
  v_result := public.create_idea('a9950000-0000-4000-8000-000000000002');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Incomplete backfill fixture creation failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;

  v_result := public.save_idea_content(
    v_idea_id, 'a9960000-0000-4000-8000-000000000006', 1,
    '[{"stage_number":1,"data":{"content":"Only Stage 1 is confirmed."}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Incomplete backfill Stage 1 save failed: %', v_result;
  END IF;
  v_revision := (v_result->>'result_revision')::integer;
  v_result := public.request_idea_stage_confirmation(v_idea_id, 1::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Incomplete backfill confirmation request failed: %',
      v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 1::smallint, v_revision);
  IF v_result->>'outcome' <> 'confirmed' THEN
    RAISE EXCEPTION 'Incomplete backfill Stage 1 confirmation failed: %',
      v_result;
  END IF;
  IF public.get_own_idea_classification_status(v_idea_id)->>'status'
     <> 'missing' THEN
    RAISE EXCEPTION 'An incomplete idea was queued before backfill';
  END IF;
  PERFORM pg_catalog.set_config(
    'test.phase7_incomplete_idea_id', v_idea_id::text, true
  );
END
$phase7_incomplete_backfill_test$;
RESET ROLE;
DO $phase7_incomplete_backfill_assertion$
DECLARE
  v_idea_id uuid :=
    pg_catalog.current_setting('test.phase7_incomplete_idea_id')::uuid;
BEGIN
  IF public.backfill_phase7_classification_state() <> 0
     OR public.get_own_idea_classification_status(v_idea_id)->>'status'
       <> 'missing' THEN
    RAISE EXCEPTION 'The backfill queued an idea without confirmed Stage 2';
  END IF;
END
$phase7_incomplete_backfill_assertion$;

SET LOCAL ROLE service_role;

DO $phase7_classifier_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_owner_id uuid := 'a9940000-0000-4000-8000-000000000001';
  v_stage_1 uuid := pg_catalog.current_setting('test.phase7_source_1')::uuid;
  v_stage_2 uuid := pg_catalog.current_setting('test.phase7_source_2')::uuid;
  v_result jsonb;
  v_attempt uuid := 'a9970000-0000-4000-8000-000000000001';
  v_retry uuid := 'a9970000-0000-4000-8000-000000000002';
BEGIN
  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_attempt
  );
  IF v_result->>'outcome' <> 'claimed' THEN
    RAISE EXCEPTION 'First classification claim failed: %', v_result;
  END IF;

  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_retry
  );
  IF v_result->>'outcome' <> 'in_progress' THEN
    RAISE EXCEPTION 'Concurrent logical classification was not deduplicated: %',
      v_result;
  END IF;

  v_result := public.fail_idea_classification(v_idea_id, v_attempt, 'timeout');
  IF v_result->>'outcome' <> 'failed' THEN
    RAISE EXCEPTION 'Classification failure was not safely persisted: %', v_result;
  END IF;
  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_retry
  );
  IF v_result->>'outcome' <> 'retry_wait' THEN
    RAISE EXCEPTION 'Retryable failure ignored its persisted backoff: %',
      v_result;
  END IF;

  v_result := public.complete_idea_classification(
    v_idea_id, v_retry, 'phase7.v1', 'unknown_axis',
    ARRAY['domestic_production', 'economic_mutual_aid'],
    60, ARRAY[25, 15],
    '{"unknown_axis":"Primary rationale","domestic_production":"Rationale two","economic_mutual_aid":"Rationale three"}'::jsonb,
    0.8, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'invalid_axes' THEN
    RAISE EXCEPTION 'Unknown taxonomy axis was accepted: %', v_result;
  END IF;

  v_result := public.complete_idea_classification(
    v_idea_id, v_retry, 'phase7.v1', 'resource_efficiency',
    ARRAY['resource_efficiency', 'economic_mutual_aid'],
    60, ARRAY[25, 15],
    '{"resource_efficiency":"Primary rationale","economic_mutual_aid":"Rationale two"}'::jsonb,
    NULL, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'invalid_axes' THEN
    RAISE EXCEPTION 'Duplicate taxonomy axes were accepted: %', v_result;
  END IF;

  v_result := public.complete_idea_classification(
    v_idea_id, v_retry, 'phase7.v1', 'resource_efficiency',
    ARRAY['domestic_production', 'economic_mutual_aid'],
    40, ARRAY[40, 20],
    '{"resource_efficiency":"Primary rationale","domestic_production":"Rationale two","economic_mutual_aid":"Rationale three"}'::jsonb,
    NULL, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'invalid_percentages' THEN
    RAISE EXCEPTION 'A tied primary percentage was accepted: %', v_result;
  END IF;

  v_result := public.complete_idea_classification(
    v_idea_id, v_retry, 'phase7.v1', 'resource_efficiency',
    ARRAY['domestic_production', 'economic_mutual_aid'],
    61, ARRAY[25, 15],
    '{"resource_efficiency":"Primary rationale","domestic_production":"Rationale two","economic_mutual_aid":"Rationale three"}'::jsonb,
    NULL, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'invalid_percentages' THEN
    RAISE EXCEPTION 'A percentage total other than 100 was accepted: %', v_result;
  END IF;

  v_result := public.complete_idea_classification(
    v_idea_id, v_retry, 'phase7.v1', 'resource_efficiency',
    ARRAY['domestic_production', 'economic_mutual_aid'],
    60, ARRAY[25, 15],
    '{"resource_efficiency":"Primary rationale","domestic_production":"Rationale two"}'::jsonb,
    101, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'invalid_rationales' THEN
    RAISE EXCEPTION 'Missing axis rationale was accepted: %', v_result;
  END IF;

  v_result := public.complete_idea_classification(
    v_idea_id, v_retry, 'phase7.v1', 'resource_efficiency',
    ARRAY['domestic_production', 'economic_mutual_aid'],
    60, ARRAY[25, 15],
    '{"resource_efficiency":"Primary rationale","domestic_production":"Rationale two","economic_mutual_aid":"Rationale three","social_resilience":"Unexpected rationale"}'::jsonb,
    NULL, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'invalid_rationales' THEN
    RAISE EXCEPTION 'An extra axis rationale was accepted: %', v_result;
  END IF;

  v_result := public.complete_idea_classification(
    v_idea_id, v_retry, 'phase7.v1', 'resource_efficiency',
    ARRAY['domestic_production', 'economic_mutual_aid'],
    60, ARRAY[25, 15],
    '{"resource_efficiency":"Primary rationale","domestic_production":"Rationale two","economic_mutual_aid":"Rationale three"}'::jsonb,
    1.1, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'invalid_confidence' THEN
    RAISE EXCEPTION 'Out-of-range confidence was accepted: %', v_result;
  END IF;
END
$phase7_classifier_test$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9940000-0000-4000-8000-000000000001', true
);
DO $phase7_retry_wait_projection_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_projection jsonb;
BEGIN
  v_projection := public.get_own_idea_classification_status(v_idea_id);
  IF v_projection->>'status' <> 'retry_wait'
     OR (v_projection->>'wait_ms')::integer <= 0
     OR v_projection ?| ARRAY[
       'attempt_token', 'lease_expires_at', 'attempt_count', 'retry_after',
       'last_failure_category', 'updated_at'
     ] THEN
    RAISE EXCEPTION 'Retry wait was not safely projected: %', v_projection;
  END IF;
END
$phase7_retry_wait_projection_test$;
RESET ROLE;
DO $phase7_retry_backoff_test_setup$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
BEGIN
  IF (
    SELECT state.attempt_count
    FROM public.idea_classification_state AS state
    WHERE state.idea_id = v_idea_id
  ) <> 1 OR (
    SELECT state.retry_after
    FROM public.idea_classification_state AS state
    WHERE state.idea_id = v_idea_id
  ) IS NULL THEN
    RAISE EXCEPTION 'Retryable failure did not persist bounded retry metadata';
  END IF;
  UPDATE public.idea_classification_state AS state
  SET last_failure_category = 'not_configured',
      retry_after = NULL
  WHERE state.idea_id = v_idea_id;
END
$phase7_retry_backoff_test_setup$;

SET LOCAL ROLE service_role;
DO $phase7_permanent_failure_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_owner_id uuid := 'a9940000-0000-4000-8000-000000000001';
  v_stage_1 uuid := pg_catalog.current_setting('test.phase7_source_1')::uuid;
  v_stage_2 uuid := pg_catalog.current_setting('test.phase7_source_2')::uuid;
  v_result jsonb;
BEGIN
  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1',
    'a9970000-0000-4000-8000-000000000099'
  );
  IF v_result->>'outcome' <> 'retry_exhausted' THEN
    RAISE EXCEPTION 'Permanent configuration failure was retried: %', v_result;
  END IF;
END
$phase7_permanent_failure_test$;
RESET ROLE;

DO $phase7_retry_backoff_expire$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
BEGIN
  UPDATE public.idea_classification_state AS state
  SET last_failure_category = 'timeout',
      retry_after = pg_catalog.clock_timestamp() - INTERVAL '1 second'
  WHERE state.idea_id = v_idea_id;
END
$phase7_retry_backoff_expire$;

SET LOCAL ROLE service_role;
DO $phase7_retry_claim_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_owner_id uuid := 'a9940000-0000-4000-8000-000000000001';
  v_stage_1 uuid := pg_catalog.current_setting('test.phase7_source_1')::uuid;
  v_stage_2 uuid := pg_catalog.current_setting('test.phase7_source_2')::uuid;
  v_result jsonb;
BEGIN
  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1',
    'a9970000-0000-4000-8000-000000000002'
  );
  IF v_result->>'outcome' <> 'claimed' THEN
    RAISE EXCEPTION 'An expired retry backoff could not be claimed: %', v_result;
  END IF;
  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1',
    'a9970000-0000-4000-8000-000000000003'
  );
  IF v_result->>'outcome' <> 'in_progress' THEN
    RAISE EXCEPTION 'An active retry attempt was claimed twice: %', v_result;
  END IF;
END
$phase7_retry_claim_test$;
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9940000-0000-4000-8000-000000000001', true
);
DO $phase7_active_lease_projection_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_projection jsonb;
BEGIN
  v_projection := public.get_own_idea_classification_status(v_idea_id);
  IF v_projection->>'status' <> 'processing_active'
     OR (v_projection->>'wait_ms')::integer <= 0 THEN
    RAISE EXCEPTION 'Active lease was not safely projected: %', v_projection;
  END IF;
END
$phase7_active_lease_projection_test$;
RESET ROLE;

DO $phase7_expired_lease_test_setup$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
BEGIN
  UPDATE public.idea_classification_state AS state
  SET lease_expires_at = pg_catalog.clock_timestamp() - INTERVAL '1 second'
  WHERE state.idea_id = v_idea_id
    AND state.status = 'processing';
END
$phase7_expired_lease_test_setup$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9940000-0000-4000-8000-000000000001', true
);
DO $phase7_expired_lease_projection_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_projection jsonb;
BEGIN
  v_projection := public.get_own_idea_classification_status(v_idea_id);
  IF v_projection->>'status' <> 'processing_expired'
     OR v_projection->>'wait_ms' IS NOT NULL THEN
    RAISE EXCEPTION 'Expired lease was not safely projected: %', v_projection;
  END IF;
END
$phase7_expired_lease_projection_test$;
RESET ROLE;

SET LOCAL ROLE service_role;
DO $phase7_expired_lease_recovery_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_owner_id uuid := 'a9940000-0000-4000-8000-000000000001';
  v_stage_1 uuid := pg_catalog.current_setting('test.phase7_source_1')::uuid;
  v_stage_2 uuid := pg_catalog.current_setting('test.phase7_source_2')::uuid;
  v_result jsonb;
  v_attempt uuid := 'a9970000-0000-4000-8000-000000000004';
BEGIN
  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_attempt
  );
  IF v_result->>'outcome' <> 'claimed' THEN
    RAISE EXCEPTION 'An expired abandoned attempt was not reclaimed: %',
      v_result;
  END IF;
  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1',
    'a9970000-0000-4000-8000-000000000005'
  );
  IF v_result->>'outcome' <> 'in_progress' THEN
    RAISE EXCEPTION 'The reclaimed attempt was not exclusive: %', v_result;
  END IF;

  v_result := public.complete_idea_classification(
    v_idea_id, v_attempt, 'phase7.v1', 'resource_efficiency',
    ARRAY['domestic_production', 'economic_mutual_aid'],
    60, ARRAY[25, 15],
    '{"resource_efficiency":"محور اصلی با مسئله ارتباط مستقیم دارد.","domestic_production":"این محور با ظرفیت شناسایی‌شده پیوند دارد.","economic_mutual_aid":"همکاری منابع محلی این محور را پشتیبانی می‌کند."}'::jsonb,
    0.82, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'completed' THEN
    RAISE EXCEPTION 'A valid classification was not persisted as current: %',
      v_result;
  END IF;

  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1',
    'a9970000-0000-4000-8000-000000000006'
  );
  IF v_result->>'outcome' <> 'already_current' THEN
    RAISE EXCEPTION 'A completed classification was repeated: %', v_result;
  END IF;
END
$phase7_expired_lease_recovery_test$;

RESET ROLE;
DO $phase7_current_backfill_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_inserted_count integer;
BEGIN
  DELETE FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;

  v_inserted_count := public.backfill_phase7_classification_state();
  IF v_inserted_count <> 1
     OR (
       SELECT state.status
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) <> 'current'
     OR (
       SELECT pg_catalog.count(*)
       FROM public.idea_classification_results AS result
       WHERE result.idea_id = v_idea_id
     ) <> 1 THEN
    RAISE EXCEPTION 'The backfill failed to restore an existing current result';
  END IF;
END
$phase7_current_backfill_test$;

DO $phase7_backfill_taxonomy_validation_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_inserted_count integer;
  v_result_count integer;
BEGIN
  UPDATE public.thematic_axes AS axis
  SET active = false
  WHERE axis.taxonomy_version = 'phase7.v1'
    AND axis.axis_id = 'vulnerable_empowerment';
  DELETE FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;

  v_inserted_count := public.backfill_phase7_classification_state();
  SELECT pg_catalog.count(*) INTO v_result_count
  FROM public.idea_classification_results AS result
  WHERE result.idea_id = v_idea_id;
  IF v_inserted_count <> 1
     OR (
       SELECT state.status
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) <> 'pending'
     OR (
       SELECT state.current_classification_id
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) IS NOT NULL
     OR v_result_count <> 1 THEN
    RAISE EXCEPTION
      'A result was restored under a taxonomy with fewer than six active axes';
  END IF;
  IF public.backfill_phase7_classification_state() <> 0 THEN
    RAISE EXCEPTION 'The fewer-than-six taxonomy backfill was not idempotent';
  END IF;

  UPDATE public.thematic_axes AS axis
  SET active = true
  WHERE axis.taxonomy_version = 'phase7.v1'
    AND axis.axis_id = 'vulnerable_empowerment';
  DELETE FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  INSERT INTO public.thematic_axes (
    taxonomy_version, axis_id, official_name, official_definition, active
  )
  VALUES (
    'phase7.v1',
    'phase7_test_extra_axis',
    'Test-only extra axis',
    'An extra active taxonomy row used only to verify safe backfill behavior.',
    true
  );

  v_inserted_count := public.backfill_phase7_classification_state();
  IF v_inserted_count <> 1
     OR (
       SELECT state.status
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) <> 'pending'
     OR (
       SELECT state.current_classification_id
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) IS NOT NULL
     OR (
       SELECT pg_catalog.count(*)
       FROM public.idea_classification_results AS result
       WHERE result.idea_id = v_idea_id
     ) <> 1 THEN
    RAISE EXCEPTION
      'A result was restored under a taxonomy with more than six active axes';
  END IF;
  IF public.backfill_phase7_classification_state() <> 0 THEN
    RAISE EXCEPTION 'The more-than-six taxonomy backfill was not idempotent';
  END IF;

  DELETE FROM public.thematic_axes AS axis
  WHERE axis.taxonomy_version = 'phase7.v1'
    AND axis.axis_id = 'phase7_test_extra_axis';
  DELETE FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  v_inserted_count := public.backfill_phase7_classification_state();
  IF v_inserted_count <> 1
     OR (
       SELECT state.status
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) <> 'current'
     OR (
       SELECT state.current_classification_id
       FROM public.idea_classification_state AS state
       WHERE state.idea_id = v_idea_id
     ) IS NULL
     OR (
       SELECT pg_catalog.count(*)
       FROM public.idea_classification_results AS result
       WHERE result.idea_id = v_idea_id
     ) <> 1 THEN
    RAISE EXCEPTION
      'A valid six-axis taxonomy failed to restore its matching result';
  END IF;
END
$phase7_backfill_taxonomy_validation_test$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9940000-0000-4000-8000-000000000001', true
);

DO $phase7_owner_read_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_count integer;
  v_projection jsonb;
BEGIN
  v_projection := public.get_own_idea_classification_status(v_idea_id);
  IF v_projection->>'status' <> 'current'
     OR (v_projection->>'current_classification_id') IS NULL
     OR v_projection ?| ARRAY[
       'attempt_token', 'lease_expires_at', 'attempt_count', 'retry_after',
       'last_failure_category', 'updated_at'
     ] THEN
    RAISE EXCEPTION 'The owner could not read current classification state';
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
  FROM public.idea_classification_results AS result
  WHERE result.idea_id = v_idea_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'The owner could not read the current successful result';
  END IF;
END
$phase7_owner_read_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9940000-0000-4000-8000-000000000002', true
);
DO $phase7_other_participant_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_count integer;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
  FROM pg_catalog.jsonb_object_keys(
    public.get_own_idea_classification_status(v_idea_id)
  ) AS projection_key;
  IF public.get_own_idea_classification_status(v_idea_id)->>'status'
       <> 'not_found'
     OR v_count <> 5 THEN
    RAISE EXCEPTION 'Another participant read classification state';
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
  FROM public.idea_classification_results AS result
  WHERE result.idea_id = v_idea_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Another participant read classification history';
  END IF;
END
$phase7_other_participant_test$;

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9940000-0000-4000-8000-000000000001', true
);

DO $phase7_stale_history_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_revision integer := pg_catalog.current_setting('test.phase7_revision')::integer;
  v_count integer;
  v_result jsonb;
  v_old_source_id uuid := pg_catalog.current_setting('test.phase7_source_1')::uuid;
  v_new_source_id uuid;
BEGIN
  v_result := public.save_idea_content(
    v_idea_id, 'a9960000-0000-4000-8000-000000000003', v_revision,
    '[{"stage_number":3,"data":{"content":"An unrelated Stage 3 edit."}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied'
     OR public.get_own_idea_classification_status(v_idea_id)->>'status'
       <> 'current' THEN
    RAISE EXCEPTION 'An unrelated Stage 3 edit changed classification state';
  END IF;
  v_revision := (v_result->>'result_revision')::integer;

  v_result := public.save_idea_content(
    v_idea_id, 'a9960000-0000-4000-8000-000000000004', v_revision,
    '[{"stage_number":1,"data":{"content":"A revised problem statement about reducing avoidable food waste."}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied'
     OR public.get_own_idea_classification_status(v_idea_id)->>'status'
       <> 'stale' THEN
    RAISE EXCEPTION 'A confirmed source edit failed to stale the current result';
  END IF;
  v_revision := (v_result->>'result_revision')::integer;
  SELECT pg_catalog.count(*) INTO v_count
  FROM public.idea_classification_results AS result
  WHERE result.idea_id = v_idea_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'A stale classification was still visible to its owner';
  END IF;

  v_result := public.request_idea_stage_confirmation(v_idea_id, 1::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Revised Stage 1 confirmation request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 1::smallint, v_revision);
  IF v_result->>'outcome' <> 'confirmed'
     OR public.get_own_idea_classification_status(v_idea_id)->>'status'
       <> 'pending' THEN
    RAISE EXCEPTION 'Reconfirming Stage 1 did not queue a fresh classification';
  END IF;

  SELECT stage.confirmed_version_id INTO v_new_source_id
  FROM public.idea_stages AS stage
  WHERE stage.idea_id = v_idea_id AND stage.stage_number = 1;
  IF v_new_source_id = v_old_source_id THEN
    RAISE EXCEPTION 'Reconfirmed Stage 1 did not receive a new source revision';
  END IF;
  PERFORM pg_catalog.set_config(
    'test.phase7_source_1_new', v_new_source_id::text, true
  );
  PERFORM pg_catalog.set_config(
    'test.phase7_revision_new', v_revision::text, true
  );
END
$phase7_stale_history_test$;

RESET ROLE;
DO $phase7_stage1_snapshot_assertion$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_old_source_id uuid :=
    pg_catalog.current_setting('test.phase7_source_1')::uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.idea_stage_confirmed_versions AS snapshot
    WHERE snapshot.idea_id = v_idea_id
      AND snapshot.stage_number = 1
      AND snapshot.source_confirmation_version_id = v_old_source_id
  ) THEN
    RAISE EXCEPTION 'Confirmed source revision was not preserved for audit';
  END IF;
END
$phase7_stage1_snapshot_assertion$;

SET LOCAL ROLE service_role;

DO $phase7_history_append_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_owner_id uuid := 'a9940000-0000-4000-8000-000000000001';
  v_stage_1 uuid := pg_catalog.current_setting('test.phase7_source_1_new')::uuid;
  v_stage_2 uuid := pg_catalog.current_setting('test.phase7_source_2')::uuid;
  v_attempt uuid := 'a9970000-0000-4000-8000-000000000004';
  v_result jsonb;
BEGIN
  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_attempt
  );
  IF v_result->>'outcome' <> 'claimed' THEN
    RAISE EXCEPTION 'Reclassification claim failed: %', v_result;
  END IF;

  v_result := public.complete_idea_classification(
    v_idea_id, v_attempt, 'phase7.v1', 'social_resilience',
    ARRAY['resource_efficiency', 'economic_mutual_aid'],
    55, ARRAY[30, 15],
    '{"social_resilience":"پیوندهای اجتماعی به سازگاری جمعی کمک می‌کنند.","resource_efficiency":"کاهش اتلاف منابع در مسئله نقش دارد.","economic_mutual_aid":"همکاری اقتصادی از ظرفیت‌های شناسایی‌شده پشتیبانی می‌کند."}'::jsonb,
    NULL, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'completed' THEN
    RAISE EXCEPTION 'Reclassification overwrote or lost immutable history: %',
      v_result;
  END IF;
END
$phase7_history_append_test$;

RESET ROLE;
DO $phase7_history_assertion$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
BEGIN
  IF (
    SELECT pg_catalog.count(*)
    FROM public.idea_classification_results AS result
    WHERE result.idea_id = v_idea_id
  ) <> 2 OR (
    SELECT state.status
    FROM public.idea_classification_state AS state
    WHERE state.idea_id = v_idea_id
  ) <> 'current' THEN
    RAISE EXCEPTION 'Reclassification overwrote or lost immutable history';
  END IF;
END
$phase7_history_assertion$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9940000-0000-4000-8000-000000000001', true
);

DO $phase7_stage2_revision_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_revision integer := pg_catalog.current_setting('test.phase7_revision_new')::integer;
  v_old_source_id uuid := pg_catalog.current_setting('test.phase7_source_2')::uuid;
  v_new_source_id uuid;
  v_result jsonb;
  v_count integer;
BEGIN
  v_result := public.save_idea_content(
    v_idea_id, 'a9960000-0000-4000-8000-000000000005', v_revision,
    '[{"stage_number":2,"data":{"content":"Revised capacities include shared storage and community cooking sessions."}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied'
     OR public.get_own_idea_classification_status(v_idea_id)->>'status'
       <> 'stale' THEN
    RAISE EXCEPTION 'A confirmed Stage 2 edit did not stale its classification';
  END IF;
  v_revision := (v_result->>'result_revision')::integer;
  SELECT pg_catalog.count(*) INTO v_count
  FROM public.idea_classification_results AS result
  WHERE result.idea_id = v_idea_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'A stale Stage 2 classification remained visible';
  END IF;

  v_result := public.request_idea_stage_confirmation(v_idea_id, 2::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Revised Stage 2 confirmation request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 2::smallint, v_revision);
  IF v_result->>'outcome' <> 'confirmed'
     OR public.get_own_idea_classification_status(v_idea_id)->>'status'
       <> 'pending' THEN
    RAISE EXCEPTION 'Reconfirming Stage 2 did not queue a fresh classification';
  END IF;

  SELECT stage.confirmed_version_id INTO v_new_source_id
  FROM public.idea_stages AS stage
  WHERE stage.idea_id = v_idea_id AND stage.stage_number = 2;
  IF v_new_source_id = v_old_source_id THEN
    RAISE EXCEPTION 'Reconfirmed Stage 2 did not receive a new source revision';
  END IF;
  PERFORM pg_catalog.set_config(
    'test.phase7_source_2_new', v_new_source_id::text, true
  );
END
$phase7_stage2_revision_test$;

RESET ROLE;
DO $phase7_stage2_snapshot_assertion$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_old_source_id uuid :=
    pg_catalog.current_setting('test.phase7_source_2')::uuid;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.idea_stage_confirmed_versions AS snapshot
    WHERE snapshot.idea_id = v_idea_id
      AND snapshot.stage_number = 2
      AND snapshot.source_confirmation_version_id = v_old_source_id
  ) THEN
    RAISE EXCEPTION 'The superseded Stage 2 revision was not traceable';
  END IF;
END
$phase7_stage2_snapshot_assertion$;

DO $phase7_lease_expiry_finalization_test$
DECLARE
  v_idea_id uuid := pg_catalog.current_setting('test.phase7_idea_id')::uuid;
  v_owner_id uuid := 'a9940000-0000-4000-8000-000000000001';
  v_stage_1 uuid :=
    pg_catalog.current_setting('test.phase7_source_1_new')::uuid;
  v_stage_2 uuid :=
    pg_catalog.current_setting('test.phase7_source_2_new')::uuid;
  v_attempt_a uuid := 'a9980000-0000-4000-8000-000000000011';
  v_attempt_b uuid := 'a9980000-0000-4000-8000-000000000012';
  v_attempt_c uuid := 'a9980000-0000-4000-8000-000000000013';
  v_attempt_d uuid := 'a9980000-0000-4000-8000-000000000014';
  v_attempt_e uuid := 'a9980000-0000-4000-8000-000000000015';
  v_result jsonb;
  v_before_count integer;
  v_after_count integer;
  v_lease timestamptz;
  v_boundary timestamptz;
  v_attempt_count smallint;
  v_state public.idea_classification_state%ROWTYPE;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS function_row
    WHERE function_row.oid =
      'public.complete_idea_classification(uuid,uuid,text,text,text[],integer,integer[],jsonb,numeric,text,text,uuid,uuid)'::pg_catalog.regprocedure
      AND function_row.proowner =
        'javaneh_identity_executor'::pg_catalog.regrole
      AND function_row.prosecdef
      AND function_row.proconfig = ARRAY['search_path=pg_catalog']
      AND pg_catalog.has_function_privilege(
        'service_role', function_row.oid, 'EXECUTE'
      )
      AND NOT pg_catalog.has_function_privilege(
        'authenticated', function_row.oid, 'EXECUTE'
      )
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_proc AS function_row
    WHERE function_row.oid =
      'public.fail_idea_classification(uuid,uuid,text)'::pg_catalog.regprocedure
      AND function_row.proowner =
        'javaneh_identity_executor'::pg_catalog.regrole
      AND function_row.prosecdef
      AND function_row.proconfig = ARRAY['search_path=pg_catalog']
      AND pg_catalog.has_function_privilege(
        'service_role', function_row.oid, 'EXECUTE'
      )
      AND NOT pg_catalog.has_function_privilege(
        'authenticated', function_row.oid, 'EXECUTE'
      )
  ) OR pg_catalog.has_function_privilege(
    'service_role',
    'public.complete_idea_classification_without_lease_guard(uuid,uuid,text,text,text[],integer,integer[],jsonb,numeric,text,text,uuid,uuid)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'service_role',
    'public.fail_idea_classification_without_lease_guard(uuid,uuid,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION
      'Lease-guarded RPC ownership, security settings, or grants are invalid';
  END IF;

  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_attempt_a
  );
  IF v_result->>'outcome' <> 'claimed' THEN
    RAISE EXCEPTION 'Lease-expiry completion fixture claim failed: %', v_result;
  END IF;

  SELECT pg_catalog.count(*) INTO v_before_count
  FROM public.idea_classification_results AS result
  WHERE result.idea_id = v_idea_id;
  UPDATE public.idea_classification_state AS state
  SET lease_expires_at = '2000-01-01 00:00:00+00'::timestamptz
  WHERE state.idea_id = v_idea_id;
  SELECT state.lease_expires_at INTO v_lease
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  SELECT state.attempt_count INTO v_attempt_count
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;

  v_result := public.complete_idea_classification(
    v_idea_id, v_attempt_a, 'phase7.v1', 'social_resilience',
    ARRAY['resource_efficiency', 'economic_mutual_aid'],
    55, ARRAY[30, 15],
    '{"social_resilience":"A valid primary rationale.","resource_efficiency":"A valid secondary rationale.","economic_mutual_aid":"Another valid secondary rationale."}'::jsonb,
    NULL, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'stale_attempt' THEN
    RAISE EXCEPTION 'Completion after lease expiry was not rejected: %',
      v_result;
  END IF;
  SELECT state.* INTO v_state
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  SELECT pg_catalog.count(*) INTO v_after_count
  FROM public.idea_classification_results AS result
  WHERE result.idea_id = v_idea_id;
  IF v_state.status <> 'processing'
     OR v_state.attempt_token IS DISTINCT FROM v_attempt_a
     OR v_state.lease_expires_at IS DISTINCT FROM v_lease
     OR v_state.attempt_count IS DISTINCT FROM v_attempt_count
     OR v_after_count <> v_before_count THEN
    RAISE EXCEPTION
      'Expired completion changed state, lease metadata, or result history';
  END IF;

  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_attempt_b
  );
  IF v_result->>'outcome' <> 'claimed' THEN
    RAISE EXCEPTION 'Expired completion left work unrecoverable: %', v_result;
  END IF;
  SELECT state.* INTO v_state
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  v_lease := v_state.lease_expires_at;

  v_result := public.complete_idea_classification(
    v_idea_id, v_attempt_a, 'phase7.v1', 'social_resilience',
    ARRAY['resource_efficiency', 'economic_mutual_aid'],
    55, ARRAY[30, 15],
    '{"social_resilience":"A valid primary rationale.","resource_efficiency":"A valid secondary rationale.","economic_mutual_aid":"Another valid secondary rationale."}'::jsonb,
    NULL, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'stale_attempt' THEN
    RAISE EXCEPTION 'A reclaimed attempt accepted stale completion: %',
      v_result;
  END IF;
  v_result := public.fail_idea_classification(
    v_idea_id, v_attempt_a, 'timeout'
  );
  IF v_result->>'outcome' <> 'stale_attempt' THEN
    RAISE EXCEPTION 'A reclaimed attempt accepted stale failure: %', v_result;
  END IF;
  SELECT state.* INTO v_state
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  IF v_state.status <> 'processing'
     OR v_state.attempt_token IS DISTINCT FROM v_attempt_b
     OR v_state.lease_expires_at IS DISTINCT FROM v_lease THEN
    RAISE EXCEPTION 'A stale worker altered the reclaimed attempt';
  END IF;

  UPDATE public.idea_classification_state AS state
  SET lease_expires_at = '2000-01-01 00:00:00+00'::timestamptz
  WHERE state.idea_id = v_idea_id;
  SELECT state.lease_expires_at INTO v_lease
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  SELECT state.attempt_count INTO v_attempt_count
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  v_result := public.fail_idea_classification(
    v_idea_id, v_attempt_b, 'timeout'
  );
  IF v_result->>'outcome' <> 'stale_attempt' THEN
    RAISE EXCEPTION 'Failure after lease expiry was not rejected: %',
      v_result;
  END IF;
  SELECT state.* INTO v_state
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  IF v_state.status <> 'processing'
     OR v_state.attempt_token IS DISTINCT FROM v_attempt_b
     OR v_state.lease_expires_at IS DISTINCT FROM v_lease
     OR v_state.attempt_count IS DISTINCT FROM v_attempt_count
     OR v_state.retry_after IS NOT NULL
     OR v_state.last_failure_category IS NOT NULL THEN
    RAISE EXCEPTION 'Expired failure mutated processing state or retry data';
  END IF;

  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_attempt_c
  );
  IF v_result->>'outcome' <> 'claimed' THEN
    RAISE EXCEPTION 'Expired failure left work unrecoverable: %', v_result;
  END IF;
  v_result := public.fail_idea_classification(
    v_idea_id, v_attempt_c, 'timeout'
  );
  IF v_result->>'outcome' <> 'failed' THEN
    RAISE EXCEPTION 'A valid worker failure was rejected: %', v_result;
  END IF;

  UPDATE public.idea_classification_state AS state
  SET status = 'pending',
      current_classification_id = NULL,
      attempt_token = NULL,
      lease_expires_at = NULL,
      retry_after = NULL,
      attempt_count = 0,
      last_failure_category = NULL
  WHERE state.idea_id = v_idea_id;

  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_attempt_d
  );
  IF v_result->>'outcome' <> 'claimed' THEN
    RAISE EXCEPTION 'Lease-boundary fixture claim failed: %', v_result;
  END IF;
  v_boundary := pg_catalog.clock_timestamp();
  UPDATE public.idea_classification_state AS state
  SET lease_expires_at = v_boundary
  WHERE state.idea_id = v_idea_id;
  SELECT pg_catalog.count(*) INTO v_before_count
  FROM public.idea_classification_results AS result
  WHERE result.idea_id = v_idea_id;

  v_result := public.complete_idea_classification(
    v_idea_id, v_attempt_d, 'phase7.v1', 'social_resilience',
    ARRAY['resource_efficiency', 'economic_mutual_aid'],
    55, ARRAY[30, 15],
    '{"social_resilience":"A valid primary rationale.","resource_efficiency":"A valid secondary rationale.","economic_mutual_aid":"Another valid secondary rationale."}'::jsonb,
    NULL, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'stale_attempt' THEN
    RAISE EXCEPTION 'Completion at the lease boundary was accepted: %',
      v_result;
  END IF;
  v_result := public.fail_idea_classification(
    v_idea_id, v_attempt_d, 'timeout'
  );
  IF v_result->>'outcome' <> 'stale_attempt' THEN
    RAISE EXCEPTION 'Failure at the lease boundary was accepted: %', v_result;
  END IF;
  SELECT state.* INTO v_state
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = v_idea_id;
  SELECT pg_catalog.count(*) INTO v_after_count
  FROM public.idea_classification_results AS result
  WHERE result.idea_id = v_idea_id;
  IF v_state.status <> 'processing'
     OR v_state.attempt_token IS DISTINCT FROM v_attempt_d
     OR v_state.lease_expires_at > pg_catalog.clock_timestamp()
     OR v_after_count <> v_before_count THEN
    RAISE EXCEPTION 'Lease-boundary rejection mutated work or inserted a result';
  END IF;

  v_result := public.claim_idea_classification(
    v_idea_id, v_owner_id, v_stage_1, v_stage_2,
    'phase7.v1', 'phase7.classification.v1', v_attempt_e
  );
  IF v_result->>'outcome' <> 'claimed' THEN
    RAISE EXCEPTION 'Boundary-expired work could not be reclaimed: %',
      v_result;
  END IF;
  v_result := public.complete_idea_classification(
    v_idea_id, v_attempt_e, 'phase7.v1', 'social_resilience',
    ARRAY['resource_efficiency', 'economic_mutual_aid'],
    55, ARRAY[30, 15],
    '{"social_resilience":"A valid primary rationale.","resource_efficiency":"A valid secondary rationale.","economic_mutual_aid":"Another valid secondary rationale."}'::jsonb,
    NULL, 'test/model', 'phase7.classification.v1', v_stage_1, v_stage_2
  );
  IF v_result->>'outcome' <> 'completed' THEN
    RAISE EXCEPTION 'A valid non-expired lease could not complete: %',
      v_result;
  END IF;
END
$phase7_lease_expiry_finalization_test$;

ROLLBACK;
