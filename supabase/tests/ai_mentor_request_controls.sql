-- Rollback-only security, admission, deduplication, and retention tests.
BEGIN;

DO $m9r11_schema_test$
BEGIN
  IF NOT (
    SELECT c.relrowsecurity AND c.relforcerowsecurity
      FROM pg_catalog.pg_class AS c
      JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND c.relname = 'ai_mentor_request_controls'
  ) THEN
    RAISE EXCEPTION 'Mentor request-control table must force RLS';
  END IF;
  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.ai_mentor_request_controls', 'SELECT'
     ) OR pg_catalog.has_table_privilege(
       'authenticated', 'public.ai_mentor_request_controls', 'INSERT'
     ) OR pg_catalog.has_table_privilege(
       'anon', 'public.ai_mentor_request_controls', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'Authenticated users have direct control-table access';
  END IF;
  IF pg_catalog.has_table_privilege(
       'service_role', 'public.ai_mentor_request_controls', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'service_role has direct control-table access';
  END IF;
END
$m9r11_schema_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a9b11000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', 'm9r11-controls-a@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9b11000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', 'm9r11-controls-b@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9b11000-0000-4000-8000-000000000003', 'authenticated',
    'authenticated', 'm9r11-controls-limit@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9b11000-0000-4000-8000-000000000004', 'authenticated',
    'authenticated', 'm9r11-controls-expiry@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  );

INSERT INTO public.ai_mentor_request_controls (
  participant_id, request_id, created_at, state, finished_at
)
VALUES (
  'a9b11000-0000-4000-8000-000000000004',
  'a9b12000-0000-4000-8000-000000000001',
  pg_catalog.clock_timestamp() - INTERVAL '25 hours',
  'completed',
  pg_catalog.clock_timestamp() - INTERVAL '25 hours'
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b11000-0000-4000-8000-000000000001', true
);

DO $m9r11_request_semantics$
DECLARE
  v_result jsonb;
  v_request_id uuid := 'a9b12000-0000-4000-8000-000000000010';
  v_retry_seconds integer;
BEGIN
  v_result := public.reserve_mentor_request(v_request_id);
  IF v_result->>'outcome' <> 'admitted' THEN
    RAISE EXCEPTION 'New request was not admitted: %', v_result;
  END IF;
  v_result := public.reserve_mentor_request(v_request_id);
  IF v_result->>'outcome' <> 'duplicate'
     OR v_result->>'state' <> 'processing' THEN
    RAISE EXCEPTION 'Processing duplicate was not rejected: %', v_result;
  END IF;

  v_result := public.finish_mentor_request(v_request_id, true);
  IF v_result->>'outcome' <> 'finished'
     OR v_result->>'state' <> 'completed' THEN
    RAISE EXCEPTION 'Successful request was not finalized: %', v_result;
  END IF;
  v_result := public.reserve_mentor_request(v_request_id);
  IF v_result->>'outcome' <> 'duplicate'
     OR v_result->>'state' <> 'completed' THEN
    RAISE EXCEPTION 'Completed duplicate was not rejected: %', v_result;
  END IF;

  v_request_id := 'a9b12000-0000-4000-8000-000000000011';
  v_result := public.reserve_mentor_request(v_request_id);
  IF v_result->>'outcome' <> 'admitted' THEN
    RAISE EXCEPTION 'Failure fixture was not admitted: %', v_result;
  END IF;
  v_result := public.finish_mentor_request(v_request_id, false);
  IF v_result->>'outcome' <> 'finished'
     OR v_result->>'state' <> 'failed' THEN
    RAISE EXCEPTION 'Failed request was not finalized: %', v_result;
  END IF;
  v_result := public.reserve_mentor_request(v_request_id);
  IF v_result->>'outcome' <> 'duplicate'
     OR v_result->>'state' <> 'failed' THEN
    RAISE EXCEPTION 'Failed request retry was not rejected: %', v_result;
  END IF;
END
$m9r11_request_semantics$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b11000-0000-4000-8000-000000000002', true
);
DO $m9r11_user_isolation$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.finish_mentor_request(
    'a9b12000-0000-4000-8000-000000000011', false
  );
  IF v_result->>'outcome' <> 'not_found' THEN
    RAISE EXCEPTION 'A different user finalized another user request: %', v_result;
  END IF;

  v_result := public.reserve_mentor_request(
    'a9b12000-0000-4000-8000-000000000010'
  );
  IF v_result->>'outcome' <> 'admitted' THEN
    RAISE EXCEPTION 'A different user could not reuse an independent request ID: %',
      v_result;
  END IF;
  v_result := public.finish_mentor_request(
    'a9b12000-0000-4000-8000-000000000010', false
  );
  IF v_result->>'state' <> 'failed' THEN
    RAISE EXCEPTION 'Second user could not finalize their own request: %', v_result;
  END IF;
END
$m9r11_user_isolation$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b11000-0000-4000-8000-000000000003', true
);
DO $m9r11_rate_boundary$
DECLARE
  v_index integer;
  v_request_id uuid;
  v_result jsonb;
  v_retry_seconds integer;
BEGIN
  FOR v_index IN 1..5 LOOP
    v_request_id := (
      'a9b12000-0000-4000-8000-' || pg_catalog.lpad(v_index::text, 12, '0')
    )::uuid;
    v_result := public.reserve_mentor_request(v_request_id);
    IF v_result->>'outcome' <> 'admitted' THEN
      RAISE EXCEPTION 'Request % within the five-request limit was rejected: %',
        v_index, v_result;
    END IF;
  END LOOP;

  v_result := public.reserve_mentor_request(
    'a9b12000-0000-4000-8000-000000000006'
  );
  v_retry_seconds := (v_result->>'retry_after_seconds')::integer;
  IF v_result->>'outcome' <> 'rate_limited'
      OR v_retry_seconds IS NULL
      OR v_retry_seconds < 1 OR v_retry_seconds > 60 THEN
    RAISE EXCEPTION 'Sixth request did not receive a bounded rate limit: %',
      v_result;
  END IF;
END
$m9r11_rate_boundary$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b11000-0000-4000-8000-000000000004', true
);
DO $m9r11_expired_request_reuse$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.reserve_mentor_request(
    'a9b12000-0000-4000-8000-000000000001'
  );
  IF v_result->>'outcome' <> 'admitted' THEN
    RAISE EXCEPTION 'Expired request record was not cleaned before reuse: %',
      v_result;
  END IF;
END
$m9r11_expired_request_reuse$;

RESET ROLE;

DO $m9r11_cleanup_assertion$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM public.ai_mentor_request_controls AS request_control
      WHERE request_control.participant_id =
        'a9b11000-0000-4000-8000-000000000004'
        AND request_control.request_id =
          'a9b12000-0000-4000-8000-000000000001'
        AND request_control.created_at <
          pg_catalog.clock_timestamp() - INTERVAL '24 hours'
  ) THEN
    RAISE EXCEPTION 'Expired request control was not removed';
  END IF;
END
$m9r11_cleanup_assertion$;

ROLLBACK;