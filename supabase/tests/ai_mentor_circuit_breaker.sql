-- Run against an isolated database after the Phase 6 migration; rolls back.
BEGIN;

DO $permissions_test$
BEGIN
  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.ai_mentor_circuit_breakers', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.ai_mentor_circuit_events', 'SELECT'
     )
     OR pg_catalog.has_function_privilege(
       'authenticated', 'public.admit_mentor_provider_call(text,uuid)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.get_mentor_circuit_status(text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'authenticated', 'public.get_mentor_circuit_status(text)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'service_role',
       'public.admit_mentor_provider_call(text,uuid)',
       'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'service_role',
       'public.record_mentor_provider_result(text,uuid,text,text,uuid)',
       'EXECUTE'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.ai_mentor_circuit_breakers', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.ai_mentor_circuit_events', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'Circuit state is not restricted to trusted server execution';
  END IF;
END
$permissions_test$;

SET LOCAL ROLE service_role;
DO $closed_to_open_test$
DECLARE
  v_result jsonb;
  v_probe uuid;
  v_model constant text := 'test:phase6-transition';
  v_correlation uuid;
  v_count integer;
BEGIN
  v_result := public.get_mentor_circuit_status(v_model);
  IF v_result->>'state' <> 'closed' THEN
    RAISE EXCEPTION 'New provider state was not closed: %', v_result;
  END IF;

  v_probe := pg_catalog.gen_random_uuid();
  v_result := public.admit_mentor_provider_call(v_model, v_probe);
  IF v_result->>'outcome' <> 'admitted' THEN
    RAISE EXCEPTION 'Closed circuit did not admit request: %', v_result;
  END IF;
  v_result := public.record_mentor_provider_result(
    v_model, NULL, 'ignored_failure', 'not_configured',
    pg_catalog.gen_random_uuid()
  );
  IF v_result->>'state' <> 'closed' THEN
    RAISE EXCEPTION 'Configuration failure opened the circuit: %', v_result;
  END IF;
  IF (v_result->>'failure_count')::integer <> 0 THEN
    RAISE EXCEPTION 'Configuration failure affected transient count: %', v_result;
  END IF;
  v_result := public.get_mentor_circuit_status(v_model);
  IF v_result ? 'retry_after_seconds' THEN
    RAISE EXCEPTION 'Closed status returned an invalid retry-after value: %',
      v_result;
  END IF;

  FOR v_count IN 1..3 LOOP
    v_probe := pg_catalog.gen_random_uuid();
    v_result := public.admit_mentor_provider_call(v_model, v_probe);
    IF v_result->>'outcome' <> 'admitted' THEN
      RAISE EXCEPTION 'Closed circuit stopped admitting before threshold: %',
        v_result;
    END IF;
    v_correlation := pg_catalog.gen_random_uuid();
    v_result := public.record_mentor_provider_result(
      v_model, NULL, 'transient_failure', 'provider_5xx', v_correlation
    );
  END LOOP;

  IF v_result->>'state' <> 'open' THEN
    RAISE EXCEPTION 'Three transient failures did not open the circuit: %',
      v_result;
  END IF;
  v_result := public.admit_mentor_provider_call(
    v_model, pg_catalog.gen_random_uuid()
  );
  IF v_result->>'outcome' <> 'blocked'
     OR v_result->>'state' <> 'open'
     OR (v_result->>'retry_after_seconds')::integer < 1 THEN
    RAISE EXCEPTION 'Open circuit did not block a request: %', v_result;
  END IF;
END
$closed_to_open_test$;
RESET ROLE;

UPDATE public.ai_mentor_circuit_breakers
  SET open_until = pg_catalog.clock_timestamp() - INTERVAL '1 second'
  WHERE provider_model = 'test:phase6-transition';

SET LOCAL ROLE service_role;
DO $recovery_probe_test$
DECLARE
  v_model constant text := 'test:phase6-transition';
  v_token uuid := pg_catalog.gen_random_uuid();
  v_result jsonb;
  v_count integer;
BEGIN
  v_result := public.admit_mentor_provider_call(v_model, v_token);
  IF v_result->>'outcome' <> 'probe'
     OR v_result->>'state' <> 'half_open' THEN
    RAISE EXCEPTION 'Expired cooldown did not admit one probe: %', v_result;
  END IF;

  v_result := public.admit_mentor_provider_call(
    v_model, pg_catalog.gen_random_uuid()
  );
  IF v_result->>'outcome' <> 'blocked'
     OR v_result->>'state' <> 'half_open' THEN
    RAISE EXCEPTION 'Half-open circuit admitted a second probe: %', v_result;
  END IF;

  v_result := public.record_mentor_provider_result(
    v_model, v_token, 'success', NULL, pg_catalog.gen_random_uuid()
  );
  IF v_result->>'state' <> 'closed' THEN
    RAISE EXCEPTION 'Successful probe did not close the circuit: %', v_result;
  END IF;

  FOR v_count IN 1..3 LOOP
    v_result := public.admit_mentor_provider_call(
      v_model, pg_catalog.gen_random_uuid()
    );
    v_result := public.record_mentor_provider_result(
      v_model, NULL, 'transient_failure', 'rate_limited',
      pg_catalog.gen_random_uuid()
    );
  END LOOP;
  IF v_result->>'state' <> 'open' THEN
    RAISE EXCEPTION 'Rate limits did not open the circuit: %', v_result;
  END IF;
END
$recovery_probe_test$;
RESET ROLE;

UPDATE public.ai_mentor_circuit_breakers
  SET open_until = pg_catalog.clock_timestamp() - INTERVAL '1 second'
  WHERE provider_model = 'test:phase6-transition';

SET LOCAL ROLE service_role;
DO $failed_probe_test$
DECLARE
  v_model constant text := 'test:phase6-transition';
  v_token uuid;
  v_result jsonb;
BEGIN
  v_token := pg_catalog.gen_random_uuid();
  v_result := public.admit_mentor_provider_call(v_model, v_token);
  v_result := public.record_mentor_provider_result(
    v_model, v_token, 'transient_failure', 'timeout',
    pg_catalog.gen_random_uuid()
  );
  IF v_result->>'state' <> 'open'
     OR (v_result->>'open_until')::timestamptz
       < pg_catalog.clock_timestamp() + INTERVAL '119 seconds' THEN
    RAISE EXCEPTION 'Failed probe did not reopen with cooldown: %', v_result;
  END IF;
END
$failed_probe_test$;
RESET ROLE;

UPDATE public.ai_mentor_circuit_breakers
  SET open_until = pg_catalog.clock_timestamp() - INTERVAL '1 second'
  WHERE provider_model = 'test:phase6-transition';

SET LOCAL ROLE service_role;
DO $stale_probe_start_test$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.admit_mentor_provider_call(
    'test:phase6-transition', pg_catalog.gen_random_uuid()
  );
  IF v_result->>'outcome' <> 'probe' THEN
    RAISE EXCEPTION 'Expired cooldown did not admit a fresh probe: %', v_result;
  END IF;
END
$stale_probe_start_test$;
RESET ROLE;

UPDATE public.ai_mentor_circuit_breakers
  SET probe_started_at = pg_catalog.clock_timestamp() - INTERVAL '31 seconds'
  WHERE provider_model = 'test:phase6-transition';

SET LOCAL ROLE service_role;
DO $stale_probe_expiry_test$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.admit_mentor_provider_call(
    'test:phase6-transition', pg_catalog.gen_random_uuid()
  );
  IF v_result->>'outcome' <> 'blocked'
     OR v_result->>'state' <> 'open'
     OR (v_result->>'retry_after_seconds')::integer < 239 THEN
    RAISE EXCEPTION 'Stale probe did not reopen with bounded backoff: %',
      v_result;
  END IF;
END
$stale_probe_expiry_test$;
RESET ROLE;

DO $event_log_test$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM public.ai_mentor_circuit_events AS event
      WHERE event.provider_model = 'test:phase6-transition'
        AND event.event_type = 'probe_failed'
  ) THEN
    RAISE EXCEPTION 'Recovery result was not recorded operationally';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM public.ai_mentor_circuit_events AS event
      WHERE event.provider_model = 'test:phase6-transition'
        AND event.event_type = 'probe_expired'
        AND event.failure_category = 'timeout'
  ) THEN
    RAISE EXCEPTION 'An expired probe was not recorded as a timeout';
  END IF;
END
$event_log_test$;

ROLLBACK;
