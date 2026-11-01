BEGIN;

REVOKE SELECT ON TABLE public.idea_classification_state
  FROM authenticated;
REVOKE SELECT (
  idea_id,
  status,
  source_stage_1_revision_id,
  source_stage_2_revision_id,
  current_classification_id,
  lease_expires_at,
  last_failure_category,
  attempt_count,
  retry_after
) ON TABLE public.idea_classification_state
  FROM authenticated;

CREATE OR REPLACE FUNCTION public.get_own_idea_classification_status(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_state public.idea_classification_state%ROWTYPE;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_status text;
  v_wait_ms integer;
BEGIN
  IF p_idea_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'not_found',
      'current_classification_id', NULL,
      'source_stage_1_revision_id', NULL,
      'source_stage_2_revision_id', NULL,
      'wait_ms', NULL
    );
  END IF;

  SELECT idea.owner_id
  INTO v_owner_id
  FROM public.ideas AS idea
  WHERE idea.id = p_idea_id;

  IF NOT FOUND
     OR v_owner_id IS DISTINCT FROM javaneh_private.current_uid() THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'not_found',
      'current_classification_id', NULL,
      'source_stage_1_revision_id', NULL,
      'source_stage_2_revision_id', NULL,
      'wait_ms', NULL
    );
  END IF;

  SELECT state.*
  INTO v_state
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = p_idea_id;

  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'missing',
      'current_classification_id', NULL,
      'source_stage_1_revision_id', NULL,
      'source_stage_2_revision_id', NULL,
      'wait_ms', NULL
    );
  END IF;

  CASE v_state.status
    WHEN 'pending' THEN
      v_status := 'pending';
    WHEN 'processing' THEN
      IF v_state.lease_expires_at > v_now THEN
        v_status := 'processing_active';
        v_wait_ms := GREATEST(
          1,
          LEAST(
            120000,
            pg_catalog.ceil(
              EXTRACT(
                EPOCH FROM (v_state.lease_expires_at - v_now)
              ) * 1000
            )::integer
          )
        );
      ELSE
        v_status := 'processing_expired';
      END IF;
    WHEN 'current' THEN
      v_status := 'current';
    WHEN 'stale' THEN
      v_status := 'stale';
    WHEN 'failed' THEN
      IF v_state.attempt_count < 3
         AND v_state.last_failure_category IN (
           'circuit_open',
           'circuit_control_unavailable',
           'timeout',
           'network',
           'rate_limited',
           'unavailable',
           'persistence_unavailable'
         ) THEN
        IF v_state.retry_after > v_now THEN
          v_status := 'retry_wait';
          v_wait_ms := GREATEST(
            1,
            LEAST(
              120000,
              pg_catalog.ceil(
                EXTRACT(
                  EPOCH FROM (v_state.retry_after - v_now)
                ) * 1000
              )::integer
            )
          );
        ELSE
          v_status := 'retry_ready';
        END IF;
      ELSE
        v_status := 'failed';
      END IF;
  END CASE;

  RETURN pg_catalog.jsonb_build_object(
    'status', v_status,
    'current_classification_id',
      CASE WHEN v_status = 'current'
        THEN v_state.current_classification_id
        ELSE NULL
      END,
    'source_stage_1_revision_id', v_state.source_stage_1_revision_id,
    'source_stage_2_revision_id', v_state.source_stage_2_revision_id,
    'wait_ms', v_wait_ms
  );
END
$function$;

DO $executor_create_check$
BEGIN
  IF pg_catalog.has_schema_privilege(
       'javaneh_identity_executor', 'public', 'CREATE'
     ) THEN
    RAISE EXCEPTION
      'javaneh_identity_executor already has CREATE on public; refusing temporary privilege window'
      USING ERRCODE = '42501';
  END IF;
END
$executor_create_check$;
GRANT CREATE ON SCHEMA public TO javaneh_identity_executor;
ALTER FUNCTION public.get_own_idea_classification_status(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_own_idea_classification_status(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_own_idea_classification_status(uuid)
  TO authenticated;

DROP POLICY idea_classification_current_owner_read
  ON public.idea_classification_results;
CREATE POLICY idea_classification_current_owner_read
  ON public.idea_classification_results FOR SELECT TO authenticated
  USING (
    public.get_own_idea_classification_status(
      idea_classification_results.idea_id
    )->>'current_classification_id' =
      idea_classification_results.classification_id::text
  );

COMMIT;
