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

ALTER TABLE public.idea_stages
  ADD COLUMN stage_key text GENERATED ALWAYS AS (
    CASE stage_number
      WHEN 1 THEN 'define_problem'
      WHEN 2 THEN 'identify_social_capacities'
      WHEN 3 THEN 'develop_ideas'
      WHEN 4 THEN 'implementation_plan'
      WHEN 5 THEN 'feasibility_resilience'
      WHEN 6 THEN 'idea_dossier'
      WHEN 7 THEN 'human_review'
    END
  ) STORED NOT NULL;

COMMENT ON COLUMN public.idea_stages.stage_key IS
  'Stable M9R9 identifier derived from stage_number; stage 7 is reserved for human review.';

CREATE OR REPLACE FUNCTION public.request_idea_stage_confirmation(
  p_idea_id uuid,
  p_stage_number smallint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_stage public.idea_stages%ROWTYPE;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_stage_number IS NULL
     OR p_stage_number < 1 OR p_stage_number > 6 THEN
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
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  SELECT stage.* INTO v_stage
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = p_stage_number
    FOR UPDATE;
  IF NOT FOUND OR v_stage.status NOT IN ('in_progress', 'pending_confirmation') THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF v_stage.status = 'pending_confirmation' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_requested');
  END IF;

  UPDATE public.idea_stages AS stage
    SET status = 'pending_confirmation'
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = p_stage_number;
  RETURN pg_catalog.jsonb_build_object('outcome', 'requested');
END
$function$;

CREATE OR REPLACE FUNCTION public.confirm_idea_stage(
  p_idea_id uuid,
  p_stage_number smallint,
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
  v_stage public.idea_stages%ROWTYPE;
  v_next_step smallint;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_stage_number IS NULL
     OR p_stage_number < 1 OR p_stage_number > 6
     OR p_expected_revision IS NULL OR p_expected_revision < 1 THEN
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
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF v_idea.revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_revision',
      'current_revision', v_idea.revision
    );
  END IF;

  SELECT stage.* INTO v_stage
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = p_stage_number
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF v_stage.status = 'confirmed' THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_confirmed',
      'current_step', v_idea.current_step
    );
  END IF;
  IF v_stage.status <> 'pending_confirmation' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  UPDATE public.idea_stages AS stage
    SET status = 'confirmed',
        confirmed_at = pg_catalog.clock_timestamp()
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = p_stage_number;

  IF p_stage_number < 6 THEN
    UPDATE public.idea_stages AS stage
      SET status = 'in_progress'
      WHERE stage.idea_id = p_idea_id
        AND stage.stage_number = p_stage_number + 1
        AND stage.status = 'locked';
  END IF;

  v_next_step := CASE
    WHEN p_stage_number < 6 THEN p_stage_number + 1
    ELSE 6
  END;
  IF v_idea.current_step = p_stage_number THEN
    UPDATE public.ideas AS idea
      SET current_step = v_next_step
      WHERE idea.id = p_idea_id
        AND idea.owner_id = v_owner_id;
  ELSE
    v_next_step := v_idea.current_step;
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'confirmed',
    'current_step', v_next_step
  );
END
$function$;

CREATE OR REPLACE FUNCTION public.submit_idea(
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
        'revision', v_idea.revision,
        'current_step', v_idea.current_step
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_submitted',
      'idea_id', v_idea.id,
      'current_step', v_idea.current_step
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
        current_step = 7,
        submission_request_id = p_request_id,
        submission_expected_revision = p_expected_revision
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'submitted',
    'idea_id', p_idea_id,
    'revision', v_idea.revision,
    'current_step', 7
  );
END
$function$;

COMMIT;
