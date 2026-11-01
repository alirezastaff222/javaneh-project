BEGIN;

DO $prerequisite_check$
BEGIN
  IF NOT pg_catalog.pg_has_role(
       'postgres', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'anon', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'authenticated', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'service_role', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'authenticator', 'javaneh_identity_executor', 'MEMBER'
     ) THEN
    RAISE EXCEPTION 'The existing identity executor prerequisite is missing or unsafe'
      USING ERRCODE = '42501';
  END IF;
END
$prerequisite_check$;

CREATE TABLE public.ai_mentor_circuit_breakers (
  provider_model text PRIMARY KEY
    CHECK (provider_model ~ '^[A-Za-z0-9._:/-]{1,220}$'),
  state text NOT NULL DEFAULT 'closed'
    CHECK (state IN ('closed', 'open', 'half_open')),
  failure_count integer NOT NULL DEFAULT 0 CHECK (failure_count >= 0),
  failure_window_started_at timestamptz,
  open_count integer NOT NULL DEFAULT 0 CHECK (open_count >= 0),
  open_until timestamptz,
  probe_token uuid,
  probe_started_at timestamptz,
  last_outcome text NOT NULL DEFAULT 'initialized'
    CHECK (last_outcome IN (
      'initialized', 'success', 'transient_failure', 'ignored_failure',
      'probe_started', 'probe_succeeded', 'probe_failed', 'probe_expired'
    )),
  last_failure_category text
    CHECK (last_failure_category IS NULL OR last_failure_category IN (
      'timeout', 'network', 'provider_5xx', 'rate_limited',
      'not_configured', 'authentication', 'invalid_response', 'unknown'
    )),
  last_correlation_id uuid,
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT ai_mentor_circuit_breaker_state_shape CHECK (
    (state = 'closed' AND open_until IS NULL AND probe_token IS NULL
      AND probe_started_at IS NULL)
    OR (state = 'open' AND open_until IS NOT NULL AND probe_token IS NULL
      AND probe_started_at IS NULL)
    OR (state = 'half_open' AND open_until IS NULL AND probe_token IS NOT NULL
      AND probe_started_at IS NOT NULL)
  )
);

COMMENT ON TABLE public.ai_mentor_circuit_breakers IS
  'Provider/model-scoped content-free AI mentor circuit state.';

CREATE TABLE public.ai_mentor_circuit_events (
  event_id uuid PRIMARY KEY,
  provider_model text NOT NULL,
  event_type text NOT NULL CHECK (event_type IN (
    'probe_started', 'provider_success', 'provider_failure_ignored',
    'transient_failure', 'circuit_opened', 'circuit_closed',
    'probe_failed', 'probe_expired'
  )),
  from_state text NOT NULL CHECK (from_state IN ('closed', 'open', 'half_open')),
  to_state text NOT NULL CHECK (to_state IN ('closed', 'open', 'half_open')),
  failure_category text
    CHECK (failure_category IS NULL OR failure_category IN (
      'timeout', 'network', 'provider_5xx', 'rate_limited',
      'not_configured', 'authentication', 'invalid_response', 'unknown'
    )),
  correlation_id uuid NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

COMMENT ON TABLE public.ai_mentor_circuit_events IS
  'Content-free circuit transitions and provider outcomes, retained for 90 days.';

CREATE INDEX ai_mentor_circuit_events_model_time_idx
  ON public.ai_mentor_circuit_events (provider_model, occurred_at DESC);
CREATE INDEX ai_mentor_circuit_events_cleanup_idx
  ON public.ai_mentor_circuit_events (occurred_at);

ALTER TABLE public.ai_mentor_circuit_breakers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_mentor_circuit_breakers FORCE ROW LEVEL SECURITY;
ALTER TABLE public.ai_mentor_circuit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_mentor_circuit_events FORCE ROW LEVEL SECURITY;

CREATE POLICY ai_mentor_circuit_breakers_executor_all
  ON public.ai_mentor_circuit_breakers FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY ai_mentor_circuit_events_executor_all
  ON public.ai_mentor_circuit_events FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE public.ai_mentor_circuit_breakers,
  public.ai_mentor_circuit_events
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.ai_mentor_circuit_breakers,
    public.ai_mentor_circuit_events
  TO javaneh_identity_executor;

CREATE FUNCTION public.get_mentor_circuit_status(p_provider_model text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_state text;
  v_open_until timestamptz;
  v_probe_started_at timestamptz;
  v_retry_after integer;
BEGIN
  IF p_provider_model IS NULL
     OR p_provider_model !~ '^[A-Za-z0-9._:/-]{1,220}$' THEN
    RAISE EXCEPTION 'Invalid provider/model key' USING ERRCODE = '22023';
  END IF;

  SELECT circuit.state, circuit.open_until, circuit.probe_started_at
    INTO v_state, v_open_until, v_probe_started_at
    FROM public.ai_mentor_circuit_breakers AS circuit
    WHERE circuit.provider_model = p_provider_model;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'closed', 'recovery_eligible', false
    );
  END IF;

  IF v_state = 'open' THEN
    v_retry_after := GREATEST(
      0,
      pg_catalog.ceil(
        EXTRACT(EPOCH FROM (v_open_until - pg_catalog.clock_timestamp()))
      )::integer
    );
  ELSIF v_state = 'half_open' THEN
    v_retry_after := GREATEST(
      1,
      pg_catalog.ceil(
        EXTRACT(
          EPOCH FROM (
            v_probe_started_at + INTERVAL '30 seconds'
              - pg_catalog.clock_timestamp()
          )
        )
      )::integer
    );
  END IF;

  RETURN pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
    'state', v_state,
    'recovery_eligible',
      v_state = 'open' AND v_open_until <= pg_catalog.clock_timestamp(),
    'retry_after_seconds', v_retry_after
  ));
END
$function$;
ALTER FUNCTION public.get_mentor_circuit_status(text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_mentor_circuit_status(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_mentor_circuit_status(text)
  TO service_role;

CREATE FUNCTION public.admit_mentor_provider_call(
  p_provider_model text,
  p_probe_token uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_state text;
  v_open_until timestamptz;
  v_probe_started_at timestamptz;
  v_open_count integer;
  v_retry_after integer;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF p_provider_model IS NULL
     OR p_provider_model !~ '^[A-Za-z0-9._:/-]{1,220}$'
     OR p_probe_token IS NULL THEN
    RAISE EXCEPTION 'Invalid circuit admission input' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  IF pg_catalog.pg_try_advisory_xact_lock(
       pg_catalog.hashtextextended('javaneh:mentor-circuit-cleanup:v1', 0)
     ) THEN
    DELETE FROM public.ai_mentor_circuit_events
      WHERE occurred_at < v_now - INTERVAL '90 days';
    DELETE FROM public.ai_mentor_circuit_breakers
      WHERE provider_model <> p_provider_model
        AND updated_at < v_now - INTERVAL '90 days';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:mentor-circuit:v1:' || p_provider_model,
      0
    )
  );

  INSERT INTO public.ai_mentor_circuit_breakers (provider_model)
    VALUES (p_provider_model)
    ON CONFLICT (provider_model) DO NOTHING;

  SELECT circuit.state, circuit.open_until, circuit.probe_started_at,
         circuit.open_count
    INTO v_state, v_open_until, v_probe_started_at, v_open_count
    FROM public.ai_mentor_circuit_breakers AS circuit
    WHERE circuit.provider_model = p_provider_model
    FOR UPDATE;

  IF v_state = 'open' AND v_open_until <= v_now THEN
    UPDATE public.ai_mentor_circuit_breakers
      SET state = 'half_open',
          open_until = NULL,
          probe_token = p_probe_token,
          probe_started_at = v_now,
          last_outcome = 'probe_started',
          last_correlation_id = p_probe_token,
          updated_at = v_now
      WHERE provider_model = p_provider_model;
    INSERT INTO public.ai_mentor_circuit_events (
      event_id, provider_model, event_type, from_state, to_state, correlation_id
    )
    VALUES (
      pg_catalog.gen_random_uuid(), p_provider_model, 'probe_started',
      'open', 'half_open', p_probe_token
    );
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'probe', 'state', 'half_open', 'probe_token', p_probe_token
    );
  END IF;

  IF v_state = 'open' THEN
    v_retry_after := GREATEST(
      1,
      pg_catalog.ceil(EXTRACT(EPOCH FROM (v_open_until - v_now)))::integer
    );
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'blocked', 'state', 'open',
      'retry_after_seconds', v_retry_after
    );
  END IF;

  IF v_state = 'half_open' THEN
    IF v_probe_started_at <= v_now - INTERVAL '30 seconds' THEN
      UPDATE public.ai_mentor_circuit_breakers
        SET state = 'open',
            open_count = open_count + 1,
            open_until = v_now + CASE
              WHEN open_count + 1 = 2 THEN INTERVAL '120 seconds'
              WHEN open_count + 1 = 3 THEN INTERVAL '240 seconds'
              ELSE INTERVAL '300 seconds'
            END,
            probe_token = NULL,
            probe_started_at = NULL,
            last_outcome = 'probe_expired',
            last_failure_category = 'timeout',
            last_correlation_id = p_probe_token,
            updated_at = v_now
        WHERE provider_model = p_provider_model;
      INSERT INTO public.ai_mentor_circuit_events (
        event_id, provider_model, event_type, from_state, to_state,
        failure_category, correlation_id
      )
      VALUES (
        pg_catalog.gen_random_uuid(), p_provider_model, 'probe_expired',
        'half_open', 'open', 'timeout', p_probe_token
      );
      RETURN pg_catalog.jsonb_build_object(
        'outcome', 'blocked', 'state', 'open',
        'retry_after_seconds', CASE
          WHEN v_open_count + 1 = 2 THEN 120
          WHEN v_open_count + 1 = 3 THEN 240
          ELSE 300
        END
      );
    END IF;

    v_retry_after := GREATEST(
      1,
      pg_catalog.ceil(
        EXTRACT(
          EPOCH FROM (v_probe_started_at + INTERVAL '30 seconds' - v_now)
        )
      )::integer
    );
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'blocked', 'state', 'half_open',
      'retry_after_seconds', v_retry_after
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'admitted', 'state', 'closed'
  );
END
$function$;
ALTER FUNCTION public.admit_mentor_provider_call(text, uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.admit_mentor_provider_call(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admit_mentor_provider_call(text, uuid)
  TO service_role;

CREATE FUNCTION public.record_mentor_provider_result(
  p_provider_model text,
  p_probe_token uuid,
  p_outcome text,
  p_failure_category text,
  p_correlation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_state text;
  v_failure_count integer;
  v_window_started_at timestamptz;
  v_open_count integer;
  v_next_failure_count integer;
  v_next_window timestamptz;
  v_next_state text;
  v_next_open_until timestamptz;
  v_event_type text;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF p_provider_model IS NULL
     OR p_provider_model !~ '^[A-Za-z0-9._:/-]{1,220}$'
     OR p_outcome IS NULL
     OR p_outcome NOT IN ('success', 'transient_failure', 'ignored_failure')
     OR (p_failure_category IS NOT NULL AND p_failure_category NOT IN (
       'timeout', 'network', 'provider_5xx', 'rate_limited',
       'not_configured', 'authentication', 'invalid_response', 'unknown'
     ))
     OR (p_outcome = 'success' AND p_failure_category IS NOT NULL)
     OR p_correlation_id IS NULL
     OR (p_outcome = 'transient_failure' AND (
       p_failure_category IS NULL OR p_failure_category NOT IN (
         'timeout', 'network', 'provider_5xx', 'rate_limited'
       )
     ))
     OR (p_outcome = 'ignored_failure' AND (
       p_failure_category IS NULL OR p_failure_category IN (
         'timeout', 'network', 'provider_5xx', 'rate_limited'
       )
     )) THEN
    RAISE EXCEPTION 'Invalid provider result' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:mentor-circuit:v1:' || p_provider_model,
      0
    )
  );

  SELECT circuit.state, circuit.failure_count,
         circuit.failure_window_started_at, circuit.open_count
    INTO v_state, v_failure_count, v_window_started_at, v_open_count
    FROM public.ai_mentor_circuit_breakers AS circuit
    WHERE circuit.provider_model = p_provider_model
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Circuit state does not exist' USING ERRCODE = 'P0002';
  END IF;

  v_next_state := v_state;
  v_next_open_until := NULL;
  v_next_failure_count := v_failure_count;
  v_next_window := v_window_started_at;

  IF p_probe_token IS NOT NULL THEN
    IF v_state <> 'half_open' OR NOT EXISTS (
      SELECT 1
        FROM public.ai_mentor_circuit_breakers AS circuit
        WHERE circuit.provider_model = p_provider_model
          AND circuit.probe_token = p_probe_token
    ) THEN
      RAISE EXCEPTION 'Recovery probe lease is invalid' USING ERRCODE = '42501';
    END IF;

    IF p_outcome = 'success' THEN
      v_next_state := 'closed';
      v_next_failure_count := 0;
      v_next_window := NULL;
      v_open_count := 0;
      v_event_type := 'circuit_closed';
    ELSIF p_outcome = 'transient_failure' THEN
      v_open_count := v_open_count + 1;
      v_next_state := 'open';
      v_next_open_until := v_now + CASE
        WHEN v_open_count = 2 THEN INTERVAL '120 seconds'
        WHEN v_open_count = 3 THEN INTERVAL '240 seconds'
        ELSE INTERVAL '300 seconds'
      END;
      v_event_type := 'probe_failed';
    ELSE
      v_next_state := 'closed';
      v_next_failure_count := 0;
      v_next_window := NULL;
      v_open_count := 0;
      v_event_type := 'provider_failure_ignored';
    END IF;

    UPDATE public.ai_mentor_circuit_breakers
      SET state = v_next_state,
          failure_count = v_next_failure_count,
          failure_window_started_at = v_next_window,
          open_count = v_open_count,
          open_until = v_next_open_until,
          probe_token = NULL,
          probe_started_at = NULL,
          last_outcome = CASE p_outcome
            WHEN 'success' THEN 'probe_succeeded'
            WHEN 'transient_failure' THEN 'probe_failed'
            ELSE 'ignored_failure'
          END,
          last_failure_category =
            CASE WHEN p_outcome = 'success' THEN NULL ELSE p_failure_category END,
          last_correlation_id = p_correlation_id,
          updated_at = v_now
      WHERE provider_model = p_provider_model;
  ELSIF v_state = 'closed' THEN
    IF p_outcome = 'success' THEN
      v_next_failure_count := 0;
      v_next_window := NULL;
      v_event_type := 'provider_success';
    ELSIF p_outcome = 'transient_failure' THEN
      IF v_window_started_at IS NULL
         OR v_window_started_at < v_now - INTERVAL '5 minutes' THEN
        v_next_failure_count := 1;
        v_next_window := v_now;
      ELSE
        v_next_failure_count := v_failure_count + 1;
      END IF;
      v_event_type := 'transient_failure';
      IF v_next_failure_count >= 3 THEN
        v_next_state := 'open';
        v_next_open_until := v_now + INTERVAL '60 seconds';
        v_open_count := 1;
        v_event_type := 'circuit_opened';
      END IF;
    ELSE
      v_event_type := 'provider_failure_ignored';
    END IF;

    UPDATE public.ai_mentor_circuit_breakers
      SET state = v_next_state,
          failure_count = v_next_failure_count,
          failure_window_started_at = v_next_window,
          open_count = v_open_count,
          open_until = v_next_open_until,
          last_outcome = p_outcome,
          last_failure_category =
            CASE WHEN p_outcome = 'success' THEN NULL ELSE p_failure_category END,
          last_correlation_id = p_correlation_id,
          updated_at = v_now
      WHERE provider_model = p_provider_model;
  ELSE
    v_event_type := CASE
      WHEN p_outcome = 'success' THEN 'provider_success'
      ELSE 'provider_failure_ignored'
    END;
    UPDATE public.ai_mentor_circuit_breakers
      SET last_outcome = p_outcome,
          last_failure_category =
            CASE WHEN p_outcome = 'success' THEN NULL ELSE p_failure_category END,
          last_correlation_id = p_correlation_id,
          updated_at = v_now
      WHERE provider_model = p_provider_model;
  END IF;

  INSERT INTO public.ai_mentor_circuit_events (
    event_id, provider_model, event_type, from_state, to_state,
    failure_category, correlation_id
  )
  VALUES (
    pg_catalog.gen_random_uuid(), p_provider_model, v_event_type,
    v_state, v_next_state,
    CASE WHEN p_outcome = 'success' THEN NULL ELSE p_failure_category END,
    p_correlation_id
  );

  RETURN pg_catalog.jsonb_build_object(
    'state', v_next_state,
    'failure_count', v_next_failure_count,
    'open_until', v_next_open_until
  );
END
$function$;
ALTER FUNCTION public.record_mentor_provider_result(text, uuid, text, text, uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.record_mentor_provider_result(text, uuid, text, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_mentor_provider_result(text, uuid, text, text, uuid)
  TO service_role;

COMMIT;
