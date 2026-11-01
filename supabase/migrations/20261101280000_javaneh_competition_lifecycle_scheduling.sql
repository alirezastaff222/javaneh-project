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

ALTER TABLE public.competitions
  DROP CONSTRAINT competitions_status_check,
  ADD CONSTRAINT competitions_status_check
    CHECK (status IN ('draft', 'active', 'closed', 'archived', 'retired')),
  ADD COLUMN entry_opens_at timestamptz,
  ADD COLUMN entry_closes_at timestamptz,
  ADD CONSTRAINT competitions_entry_window_pair_check
    CHECK (
      (entry_opens_at IS NULL AND entry_closes_at IS NULL)
      OR (
        entry_opens_at IS NOT NULL
        AND entry_closes_at IS NOT NULL
        AND entry_opens_at < entry_closes_at
      )
    ),
  ADD CONSTRAINT competitions_active_requires_entry_window
    CHECK (
      status <> 'active'
      OR (
        entry_opens_at IS NOT NULL
        AND entry_closes_at IS NOT NULL
        AND entry_opens_at < entry_closes_at
      )
    );

ALTER TABLE public.competition_events
  DROP CONSTRAINT competition_events_event_type_check,
  ADD CONSTRAINT competition_events_event_type_check
    CHECK (event_type IN ('activated', 'closed', 'archived', 'retired')),
  ADD COLUMN previous_status text,
  ADD COLUMN new_status text,
  ADD CONSTRAINT competition_events_status_transition_check
    CHECK (
      (previous_status IS NULL AND new_status IS NULL)
      OR (
        previous_status IS NOT NULL
        AND new_status IS NOT NULL
        AND (
          (event_type = 'activated'
            AND previous_status = 'draft' AND new_status = 'active')
          OR (event_type = 'closed'
            AND previous_status = 'active' AND new_status = 'closed')
          OR (event_type = 'archived'
            AND previous_status = 'closed' AND new_status = 'archived')
          OR (event_type = 'retired'
            AND previous_status = 'active' AND new_status = 'retired')
        )
      )
    );

COMMENT ON COLUMN public.competitions.entry_opens_at IS
  'Inclusive timestamptz boundary for accepting idea assignments.';
COMMENT ON COLUMN public.competitions.entry_closes_at IS
  'Exclusive timestamptz boundary for accepting idea assignments.';
COMMENT ON COLUMN public.competition_events.previous_status IS
  'Previous competition status for lifecycle events written after M9R4.';
COMMENT ON COLUMN public.competition_events.new_status IS
  'New competition status for lifecycle events written after M9R4.';

CREATE OR REPLACE FUNCTION public.guard_competition_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'Activated competitions cannot be deleted'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.competition_key IS DISTINCT FROM OLD.competition_key
     OR NEW.created_by IS DISTINCT FROM OLD.created_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.scoring_configuration_version_id
       IS DISTINCT FROM OLD.scoring_configuration_version_id THEN
    RAISE EXCEPTION 'Competition identity is immutable'
      USING ERRCODE = '42501';
  END IF;

  IF OLD.status <> 'draft'
     AND (
       NEW.name IS DISTINCT FROM OLD.name
       OR NEW.description IS DISTINCT FROM OLD.description
       OR NEW.entry_opens_at IS DISTINCT FROM OLD.entry_opens_at
       OR NEW.entry_closes_at IS DISTINCT FROM OLD.entry_closes_at
     ) THEN
    RAISE EXCEPTION 'Competition configuration is immutable after activation'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.status = OLD.status THEN
    IF OLD.status <> 'draft' OR current_user <> 'javaneh_identity_executor' THEN
      RAISE EXCEPTION 'Competition details can only change through authorized operations while draft'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;

  IF current_user <> 'javaneh_identity_executor'
     OR NOT (
       (OLD.status = 'draft' AND NEW.status = 'active')
       OR (OLD.status = 'active' AND NEW.status IN ('closed', 'retired'))
       OR (OLD.status = 'closed' AND NEW.status = 'archived')
     ) THEN
    RAISE EXCEPTION 'Invalid or unauthorized competition lifecycle transition'
      USING ERRCODE = '42501';
  END IF;

  IF NEW.status = 'active' THEN
    IF NEW.entry_opens_at IS NULL
       OR NEW.entry_closes_at IS NULL
       OR NEW.entry_opens_at >= NEW.entry_closes_at THEN
      RAISE EXCEPTION 'Competition activation requires a valid entry window'
        USING ERRCODE = '23514';
    END IF;

    IF NOT EXISTS (
      SELECT 1
        FROM public.scoring_configuration_versions AS version
        WHERE version.id = NEW.scoring_configuration_version_id
          AND version.status = 'active'
          AND version.approved_at IS NOT NULL
          AND version.activated_at IS NOT NULL
          AND version.development_max_points = 700
          AND version.human_jury_max_points = 300
          AND version.overall_max_points = 1000
          AND version.rounding_policy = 'floor'
    ) THEN
      RAISE EXCEPTION 'Competition scoring configuration is not ready'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION public.set_competition_status(
  p_competition_id uuid,
  p_status text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_competition public.competitions%ROWTYPE;
  v_event_type text;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_competition_id IS NULL
     OR p_status IS NULL
     OR p_status NOT IN ('active', 'closed', 'archived', 'retired')
     OR p_reason IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_reason)) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:authorization:v1:' || v_actor_id::text, 0
    )
  );
  IF NOT EXISTS (
    SELECT 1
      FROM public.scoring_role_assignments AS assignment
      WHERE assignment.user_id = v_actor_id
        AND assignment.role_name = 'scoring_administrator'
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator authorization required'
      USING ERRCODE = '42501';
  END IF;

  SELECT competition.* INTO v_competition
    FROM public.competitions AS competition
    WHERE competition.id = p_competition_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;

  IF v_competition.status = 'draft' AND p_status = 'active' THEN
    v_event_type := 'activated';
    IF v_competition.entry_opens_at IS NULL
       OR v_competition.entry_closes_at IS NULL
       OR v_competition.entry_opens_at >= v_competition.entry_closes_at THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_entry_window');
    END IF;
    IF NOT EXISTS (
         SELECT 1
           FROM public.scoring_configuration_versions AS version
           WHERE version.id = v_competition.scoring_configuration_version_id
             AND version.status = 'active'
             AND version.approved_at IS NOT NULL
             AND version.activated_at IS NOT NULL
             AND version.development_max_points = 700
             AND version.human_jury_max_points = 300
             AND version.overall_max_points = 1000
             AND version.rounding_policy = 'floor'
       ) THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'configuration_incomplete');
    END IF;
  ELSIF v_competition.status = 'active' AND p_status = 'closed' THEN
    v_event_type := 'closed';
  ELSIF v_competition.status = 'active' AND p_status = 'retired' THEN
    v_event_type := 'retired';
  ELSIF v_competition.status = 'closed' AND p_status = 'archived' THEN
    v_event_type := 'archived';
  ELSE
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  UPDATE public.competitions
    SET status = p_status,
        modified_by = v_actor_id,
        updated_at = pg_catalog.clock_timestamp()
    WHERE id = p_competition_id;

  INSERT INTO public.competition_events (
    competition_id, actor_user_id, event_type, reason,
    previous_status, new_status
  )
  VALUES (
    p_competition_id, v_actor_id, v_event_type, p_reason,
    v_competition.status, p_status
  );

  RETURN pg_catalog.jsonb_build_object('outcome', p_status);
END
$function$;
REVOKE ALL ON FUNCTION public.set_competition_status(uuid, text, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_competition_status(uuid, text, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.assign_idea_competition(
  p_idea_id uuid,
  p_competition_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_competition public.competitions%ROWTYPE;
  v_now timestamptz;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_competition_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:authorization:v1:' || v_actor_id::text, 0
    )
  );
  IF NOT EXISTS (
    SELECT 1
      FROM public.scoring_role_assignments AS assignment
      WHERE assignment.user_id = v_actor_id
        AND assignment.role_name IN ('platform_owner', 'scoring_administrator')
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator authorization required'
      USING ERRCODE = '42501';
  END IF;

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_idea.competition_id IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_assigned');
  END IF;

  SELECT competition.* INTO v_competition
    FROM public.competitions AS competition
    WHERE competition.id = p_competition_id
    FOR SHARE;
  IF NOT FOUND OR v_competition.status <> 'active' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'competition_unavailable');
  END IF;

  v_now := pg_catalog.clock_timestamp();
  IF v_competition.entry_opens_at IS NULL
     OR v_competition.entry_closes_at IS NULL
     OR v_competition.entry_opens_at >= v_competition.entry_closes_at THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'entry_window_invalid');
  END IF;
  IF v_now < v_competition.entry_opens_at THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'entry_window_not_open');
  END IF;
  IF v_now >= v_competition.entry_closes_at THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'entry_window_closed');
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.scoring_configuration_versions AS version
      WHERE version.id = v_competition.scoring_configuration_version_id
        AND version.status = 'active'
        AND version.approved_at IS NOT NULL
        AND version.activated_at IS NOT NULL
        AND version.development_max_points = 700
        AND version.human_jury_max_points = 300
        AND version.overall_max_points = 1000
        AND version.rounding_policy = 'floor'
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'scoring_unavailable');
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.milestone_validation_requests AS request
      WHERE request.idea_id = v_idea.id
        AND (
          request.configuration_version_id
            IS DISTINCT FROM v_competition.scoring_configuration_version_id
          OR NOT EXISTS (
            SELECT 1
              FROM public.scoring_milestone_catalog AS milestone
              WHERE milestone.configuration_version_id =
                      request.configuration_version_id
                AND milestone.milestone_key = request.milestone_key
                AND milestone.catalog_version = request.catalog_version
                AND milestone.stage_number = request.stage_number
          )
        )
  ) OR EXISTS (
    SELECT 1
      FROM public.official_points_ledger AS ledger
      WHERE ledger.idea_id = v_idea.id
        AND (
          ledger.configuration_version_id
            IS DISTINCT FROM v_competition.scoring_configuration_version_id
          OR ledger.competition_id IS DISTINCT FROM v_competition.id
        )
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'incompatible_history');
  END IF;

  UPDATE public.ideas AS idea
    SET competition_id = v_competition.id
    WHERE idea.id = v_idea.id;

  RETURN pg_catalog.jsonb_build_object('outcome', 'assigned');
END
$function$;
REVOKE ALL ON FUNCTION public.assign_idea_competition(uuid, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.assign_idea_competition(uuid, uuid)
  TO authenticated;

COMMIT;
