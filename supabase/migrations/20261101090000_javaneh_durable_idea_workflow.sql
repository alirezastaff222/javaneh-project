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

ALTER TABLE public.ideas
  ADD COLUMN current_step smallint NOT NULL DEFAULT 1
    CHECK (current_step BETWEEN 1 AND 7),
  ADD COLUMN submission_request_id uuid,
  ADD COLUMN submission_expected_revision integer
    CHECK (
      submission_expected_revision IS NULL
      OR submission_expected_revision > 0
    );

CREATE UNIQUE INDEX ideas_owner_submission_request_key
  ON public.ideas (owner_id, submission_request_id)
  WHERE submission_request_id IS NOT NULL;

ALTER TABLE public.idea_stages
  ADD CONSTRAINT idea_stages_content_must_be_text
    CHECK (
      NOT (data ? 'content')
      OR pg_catalog.jsonb_typeof(data->'content') = 'string'
    );

CREATE FUNCTION public.set_idea_current_step(
  p_idea_id uuid,
  p_current_step smallint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_stage_status text;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_current_step IS NULL
     OR p_current_step NOT BETWEEN 1 AND 7 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  IF v_idea.status = 'submitted' THEN
    IF v_idea.current_step = p_current_step THEN
      RETURN pg_catalog.jsonb_build_object(
        'outcome', 'already_current',
        'current_step', v_idea.current_step
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  SELECT stage.status INTO v_stage_status
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = p_current_step;
  IF NOT FOUND OR (p_current_step < 7 AND v_stage_status = 'locked')
     OR (p_current_step = 7 AND v_stage_status <> 'locked') THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  IF v_idea.current_step = p_current_step THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_current',
      'current_step', v_idea.current_step
    );
  END IF;

  UPDATE public.ideas AS idea
    SET current_step = p_current_step
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'saved',
    'current_step', p_current_step
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
ALTER FUNCTION public.set_idea_current_step(uuid, smallint)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.set_idea_current_step(uuid, smallint)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_idea_current_step(uuid, smallint)
  TO authenticated;

CREATE FUNCTION public.submit_idea(
  p_idea_id uuid,
  p_request_id uuid,
  p_expected_revision integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_existing_idea_id uuid;
  v_stage_count integer;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_request_id IS NULL
     OR p_expected_revision IS NULL OR p_expected_revision < 1 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:idea-submission:v1:' || v_owner_id::text || ':'
        || p_request_id::text,
      0
    )
  );

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;

  IF v_idea.status = 'submitted' THEN
    IF v_idea.submission_request_id = p_request_id
       AND v_idea.submission_expected_revision = p_expected_revision THEN
      RETURN pg_catalog.jsonb_build_object(
        'outcome', 'replayed',
        'idea_id', v_idea.id,
        'revision', v_idea.revision
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_submitted',
      'idea_id', v_idea.id
    );
  END IF;

  SELECT idea.id INTO v_existing_idea_id
    FROM public.ideas AS idea
    WHERE idea.owner_id = v_owner_id
      AND idea.submission_request_id = p_request_id
      AND idea.id <> p_idea_id;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'idempotency_key_reuse');
  END IF;

  IF v_idea.status NOT IN ('draft', 'in_progress') THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF v_idea.revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_revision',
      'current_revision', v_idea.revision
    );
  END IF;

  SELECT pg_catalog.count(*) INTO v_stage_count
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id;
  IF v_stage_count <> 7 OR EXISTS (
    SELECT 1
      FROM public.idea_stages AS stage
      WHERE stage.idea_id = p_idea_id
        AND (
          (stage.stage_number BETWEEN 1 AND 6
            AND stage.status <> 'confirmed')
          OR (stage.stage_number = 7
            AND (stage.status <> 'locked' OR stage.data <> '{}'::jsonb))
        )
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'incomplete');
  END IF;

  UPDATE public.ideas AS idea
    SET status = 'submitted',
        submission_request_id = p_request_id,
        submission_expected_revision = p_expected_revision
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'submitted',
    'idea_id', p_idea_id,
    'revision', v_idea.revision
  );
END
$function$;
ALTER FUNCTION public.submit_idea(uuid, uuid, integer)
  OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.submit_idea(uuid, uuid, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.submit_idea(uuid, uuid, integer)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_own_idea(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_status text;
  v_rows integer;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_already_deleted');
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('javaneh:quota:v1:' || v_owner_id::text, 0)
  );

  SELECT idea.status INTO v_status
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_already_deleted');
  END IF;
  IF v_status NOT IN ('draft', 'in_progress') THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF EXISTS (
    SELECT 1
      FROM public.milestone_validation_requests AS request
      WHERE request.idea_id = p_idea_id
  ) OR EXISTS (
    SELECT 1
      FROM public.milestone_validations AS validation
      WHERE validation.idea_id = p_idea_id
  ) OR EXISTS (
    SELECT 1
      FROM public.official_points_ledger AS ledger
      WHERE ledger.idea_id = p_idea_id
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'evaluation_history_exists'
    );
  END IF;

  PERFORM pg_catalog.set_config('javaneh.delete_path', 'participant_delete', true);
  PERFORM pg_catalog.set_config('javaneh.delete_idea_id', p_idea_id::text, true);
  PERFORM pg_catalog.set_config('javaneh.delete_owner_id', v_owner_id::text, true);

  DELETE FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_already_deleted');
  END IF;

  PERFORM pg_catalog.set_config('javaneh.delete_path', '', true);
  PERFORM pg_catalog.set_config('javaneh.delete_idea_id', '', true);
  PERFORM pg_catalog.set_config('javaneh.delete_owner_id', '', true);

  RETURN pg_catalog.jsonb_build_object('outcome', 'deleted');
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
ALTER FUNCTION public.delete_own_idea(uuid) OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.delete_own_idea(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.delete_own_idea(uuid) TO authenticated;

COMMIT;
