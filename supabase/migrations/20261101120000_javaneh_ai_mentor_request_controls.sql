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

CREATE TABLE public.ai_mentor_request_controls (
  participant_id uuid NOT NULL
    REFERENCES auth.users(id) ON DELETE CASCADE,
  request_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  state text NOT NULL DEFAULT 'processing'
    CHECK (state IN ('processing', 'completed', 'failed')),
  finished_at timestamptz,
  PRIMARY KEY (participant_id, request_id),
  CONSTRAINT ai_mentor_request_controls_state_timestamp
    CHECK (
      (state = 'processing' AND finished_at IS NULL)
      OR (state IN ('completed', 'failed') AND finished_at IS NOT NULL)
    )
);

COMMENT ON TABLE public.ai_mentor_request_controls IS
  'Content-free AI mentor admission and idempotency records, retained for at most 24 hours after cleanup.';

CREATE INDEX ai_mentor_request_controls_participant_time_idx
  ON public.ai_mentor_request_controls (participant_id, created_at);
CREATE INDEX ai_mentor_request_controls_created_at_idx
  ON public.ai_mentor_request_controls (created_at);

ALTER TABLE public.ai_mentor_request_controls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_mentor_request_controls FORCE ROW LEVEL SECURITY;

CREATE POLICY ai_mentor_request_controls_executor_all
  ON public.ai_mentor_request_controls FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE public.ai_mentor_request_controls
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE public.ai_mentor_request_controls
  TO javaneh_identity_executor;

CREATE FUNCTION public.reserve_mentor_request(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_participant_id uuid;
  v_state text;
  v_request_count integer;
  v_oldest_request timestamptz;
  v_retry_after integer;
  v_inserted_count integer;
BEGIN
  v_participant_id := javaneh_private.current_uid();
  IF v_participant_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_request_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:mentor-admission:v1:' || v_participant_id::text,
      0
    )
  );

  IF pg_catalog.pg_try_advisory_xact_lock(
       pg_catalog.hashtextextended('javaneh:mentor-cleanup:v1', 0)
     ) THEN
    DELETE FROM public.ai_mentor_request_controls AS request_control
      WHERE request_control.created_at <
        pg_catalog.clock_timestamp() - INTERVAL '24 hours';
  END IF;

  SELECT request_control.state
    INTO v_state
    FROM public.ai_mentor_request_controls AS request_control
    WHERE request_control.participant_id = v_participant_id
      AND request_control.request_id = p_request_id;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'duplicate',
      'state', v_state
    );
  END IF;

  SELECT pg_catalog.count(*)::integer, pg_catalog.min(request_control.created_at)
    INTO v_request_count, v_oldest_request
    FROM public.ai_mentor_request_controls AS request_control
    WHERE request_control.participant_id = v_participant_id
      AND request_control.created_at >
        pg_catalog.clock_timestamp() - INTERVAL '1 minute';
  IF v_request_count >= 5 THEN
    v_retry_after := pg_catalog.ceil(
      EXTRACT(
        EPOCH FROM (
          v_oldest_request + INTERVAL '1 minute'
            - pg_catalog.clock_timestamp()
        )
      )
    )::integer;
    IF v_retry_after < 1 THEN
      v_retry_after := 1;
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'rate_limited',
      'retry_after_seconds', v_retry_after
    );
  END IF;

  INSERT INTO public.ai_mentor_request_controls (
    participant_id, request_id
  )
  VALUES (v_participant_id, p_request_id)
  ON CONFLICT (participant_id, request_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;
  IF v_inserted_count = 0 THEN
    SELECT request_control.state
      INTO v_state
      FROM public.ai_mentor_request_controls AS request_control
      WHERE request_control.participant_id = v_participant_id
        AND request_control.request_id = p_request_id;
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'duplicate',
      'state', v_state
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object('outcome', 'admitted');
END
$function$;
ALTER FUNCTION public.reserve_mentor_request(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.reserve_mentor_request(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reserve_mentor_request(uuid)
  TO authenticated;

CREATE FUNCTION public.finish_mentor_request(
  p_request_id uuid,
  p_succeeded boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_participant_id uuid;
  v_state text;
  v_updated_count integer;
BEGIN
  v_participant_id := javaneh_private.current_uid();
  IF v_participant_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_request_id IS NULL OR p_succeeded IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:mentor-admission:v1:' || v_participant_id::text,
      0
    )
  );

  UPDATE public.ai_mentor_request_controls AS request_control
    SET state = CASE WHEN p_succeeded THEN 'completed' ELSE 'failed' END,
        finished_at = pg_catalog.clock_timestamp()
    WHERE request_control.participant_id = v_participant_id
      AND request_control.request_id = p_request_id
      AND request_control.state = 'processing';
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  IF v_updated_count = 1 THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'finished',
      'state', CASE WHEN p_succeeded THEN 'completed' ELSE 'failed' END
    );
  END IF;

  SELECT request_control.state
    INTO v_state
    FROM public.ai_mentor_request_controls AS request_control
    WHERE request_control.participant_id = v_participant_id
      AND request_control.request_id = p_request_id;
  IF FOUND AND v_state IN ('completed', 'failed') THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_finished',
      'state', v_state
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
END
$function$;
ALTER FUNCTION public.finish_mentor_request(uuid, boolean)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.finish_mentor_request(uuid, boolean)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finish_mentor_request(uuid, boolean)
  TO authenticated;

COMMIT;