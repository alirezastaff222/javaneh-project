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

GRANT CREATE ON SCHEMA public TO javaneh_identity_executor;

CREATE UNIQUE INDEX competitions_one_active_global_idx
  ON public.competitions (status)
  WHERE status = 'active';

ALTER TABLE public.ideas
  ADD COLUMN competition_id uuid
    REFERENCES public.competitions(id) ON DELETE RESTRICT;

CREATE INDEX ideas_competition_id_idx
  ON public.ideas (competition_id)
  WHERE competition_id IS NOT NULL;

CREATE FUNCTION public.guard_idea_competition_assignment()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF NEW.competition_id IS DISTINCT FROM OLD.competition_id THEN
    IF OLD.competition_id IS NOT NULL THEN
      RAISE EXCEPTION 'An idea competition assignment is immutable'
        USING ERRCODE = '42501';
    END IF;
    IF current_user <> 'javaneh_identity_executor' THEN
      RAISE EXCEPTION 'Idea competition assignment requires the authorized RPC'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_idea_competition_assignment()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER ideas_competition_assignment_guard
  BEFORE UPDATE OF competition_id ON public.ideas
  FOR EACH ROW EXECUTE FUNCTION public.guard_idea_competition_assignment();

CREATE FUNCTION public.assign_idea_competition(
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
ALTER FUNCTION public.assign_idea_competition(uuid, uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.assign_idea_competition(uuid, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.assign_idea_competition(uuid, uuid)
  TO authenticated;

CREATE FUNCTION public.guard_idea_competition_ledger_entry()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_idea_competition_id uuid;
  v_competition_version_id uuid;
  v_competition_status text;
BEGIN
  IF NEW.entry_kind = 'compensation'
     AND NEW.catalog_version IS NULL
     AND NEW.competition_id IS NULL
     AND EXISTS (
       SELECT 1
         FROM public.official_points_ledger AS original
         WHERE original.entry_id = NEW.original_entry_id
           AND original.entry_kind = 'award'
           AND original.catalog_version IS NULL
           AND original.competition_id IS NULL
     ) THEN
    RETURN NEW;
  END IF;

  SELECT idea.competition_id INTO v_idea_competition_id
    FROM public.ideas AS idea
    WHERE idea.id = NEW.idea_id;
  IF NOT FOUND OR v_idea_competition_id IS DISTINCT FROM NEW.competition_id THEN
    RAISE EXCEPTION 'Official points require an explicit matching idea competition assignment'
      USING ERRCODE = '23514';
  END IF;

  SELECT competition.scoring_configuration_version_id, competition.status
    INTO v_competition_version_id, v_competition_status
    FROM public.competitions AS competition
    WHERE competition.id = NEW.competition_id;
  IF NOT FOUND
     OR v_competition_version_id IS DISTINCT FROM NEW.configuration_version_id THEN
    RAISE EXCEPTION 'Official points do not match the competition scoring version'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.entry_kind = 'award' AND v_competition_status <> 'active' THEN
    RAISE EXCEPTION 'Official points cannot be awarded outside an active competition'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_idea_competition_ledger_entry()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER official_points_ledger_competition_applicability_guard
  BEFORE INSERT ON public.official_points_ledger
  FOR EACH ROW EXECUTE FUNCTION public.guard_idea_competition_ledger_entry();

REVOKE SELECT ON TABLE
  public.official_points_ledger,
  public.milestone_validation_requests,
  public.milestone_validation_events
  FROM authenticated;
REVOKE SELECT ON TABLE
  public.user_point_totals,
  public.user_points_by_stage,
  public.user_points_by_milestone
  FROM authenticated;
DROP POLICY official_points_ledger_owner_read
  ON public.official_points_ledger;
DROP POLICY milestone_validation_requests_owner_read
  ON public.milestone_validation_requests;
DROP POLICY milestone_validation_events_owner_read
  ON public.milestone_validation_events;

CREATE FUNCTION public.get_participant_idea_scorecard(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_competition public.competitions%ROWTYPE;
  v_version public.scoring_configuration_versions%ROWTYPE;
  v_catalog_version text;
  v_catalog_count integer;
  v_milestones jsonb;
  v_stages jsonb;
  v_history jsonb;
  v_total_points integer;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'not_found'
    );
  END IF;

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'not_found'
    );
  END IF;
  IF v_idea.competition_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'not_assigned'
    );
  END IF;

  SELECT competition.* INTO v_competition
    FROM public.competitions AS competition
    WHERE competition.id = v_idea.competition_id;
  IF NOT FOUND OR v_competition.status <> 'active'
     OR (SELECT pg_catalog.count(*)
           FROM public.competitions AS active_competition
           WHERE active_competition.status = 'active') <> 1 THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'competition_inactive'
    );
  END IF;

  SELECT version.* INTO v_version
    FROM public.scoring_configuration_versions AS version
    WHERE version.id = v_competition.scoring_configuration_version_id;
  IF NOT FOUND OR v_version.status <> 'active'
     OR v_version.development_max_points IS DISTINCT FROM 700
      OR v_version.human_jury_max_points IS DISTINCT FROM 300
      OR v_version.overall_max_points IS DISTINCT FROM 1000
      OR v_version.rounding_policy IS DISTINCT FROM 'floor'
      OR v_version.approved_at IS NULL
      OR v_version.activated_at IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'scoring_unavailable'
    );
  END IF;

  SELECT pg_catalog.min(milestone.catalog_version),
         pg_catalog.count(*)::integer
    INTO v_catalog_version, v_catalog_count
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = v_version.id
      AND milestone.catalog_version IS NOT NULL
      AND milestone.stage_number BETWEEN 1 AND 6
      AND milestone.is_active
      AND milestone.catalog_status = 'active'
      AND milestone.participant_description IS NOT NULL
      AND pg_catalog.length(pg_catalog.btrim(milestone.participant_description)) > 0;
  IF v_catalog_count <> 28 OR v_catalog_version IS NULL
     OR EXISTS (
       SELECT 1
         FROM public.scoring_milestone_catalog AS milestone
         WHERE milestone.configuration_version_id = v_version.id
           AND milestone.catalog_version IS NOT NULL
           AND milestone.catalog_version IS DISTINCT FROM v_catalog_version
     ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'scoring_unavailable'
    );
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.milestone_validation_requests AS request
      WHERE request.idea_id = v_idea.id
        AND (
          request.configuration_version_id IS DISTINCT FROM v_version.id
          OR NOT EXISTS (
            SELECT 1
              FROM public.scoring_milestone_catalog AS milestone
              WHERE milestone.configuration_version_id = v_version.id
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
          ledger.user_id IS DISTINCT FROM v_owner_id
          OR ledger.configuration_version_id IS DISTINCT FROM v_version.id
          OR ledger.competition_id IS DISTINCT FROM v_competition.id
          OR ledger.catalog_version IS DISTINCT FROM v_catalog_version
          OR ledger.stage_number NOT BETWEEN 1 AND 6
        )
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'inconsistent_history'
    );
  END IF;

  SELECT pg_catalog.jsonb_agg(
           pg_catalog.jsonb_build_object(
             'stage_number', milestone.stage_number,
             'name', milestone.display_name,
             'criteria', milestone.participant_description,
             'status', CASE
               WHEN ledger.has_award AND ledger.net_points <= 0 THEN 'corrected'
               WHEN ledger.has_award THEN 'awarded'
               ELSE COALESCE(request.status, 'not_submitted')
             END,
             'awarded_points', GREATEST(0, ledger.net_points)
           )
           ORDER BY milestone.stage_number, milestone.sort_order
         )
    INTO v_milestones
    FROM public.scoring_milestone_catalog AS milestone
    LEFT JOIN LATERAL (
      SELECT pg_catalog.bool_or(ledger.entry_kind = 'award') AS has_award,
             COALESCE(pg_catalog.sum(ledger.points), 0)::integer AS net_points
        FROM public.official_points_ledger AS ledger
        WHERE ledger.idea_id = v_idea.id
          AND ledger.configuration_version_id = v_version.id
          AND ledger.competition_id = v_competition.id
          AND ledger.milestone_key = milestone.milestone_key
    ) AS ledger ON true
    LEFT JOIN LATERAL (
      SELECT validation_request.status
        FROM public.milestone_validation_requests AS validation_request
        WHERE validation_request.idea_id = v_idea.id
          AND validation_request.configuration_version_id = v_version.id
          AND validation_request.milestone_key = milestone.milestone_key
        ORDER BY validation_request.submitted_at DESC,
                 validation_request.request_id DESC
        LIMIT 1
    ) AS request ON true
    WHERE milestone.configuration_version_id = v_version.id
      AND milestone.catalog_version = v_catalog_version
      AND milestone.stage_number BETWEEN 1 AND 6
      AND milestone.is_active
      AND milestone.catalog_status = 'active';

  SELECT pg_catalog.jsonb_agg(
           pg_catalog.jsonb_build_object(
             'stage_number', stage.stage_number,
             'points', LEAST(
               stage.maximum_points,
               GREATEST(0, COALESCE(points.net_points, 0))
             ),
             'maximum_points', stage.maximum_points
           )
           ORDER BY stage.stage_number
         )
    INTO v_stages
    FROM public.scoring_stage_catalog AS stage
    LEFT JOIN LATERAL (
      SELECT pg_catalog.sum(ledger.points)::integer AS net_points
        FROM public.official_points_ledger AS ledger
        JOIN public.scoring_milestone_catalog AS milestone
          ON milestone.configuration_version_id = ledger.configuration_version_id
         AND milestone.milestone_key = ledger.milestone_key
        WHERE ledger.idea_id = v_idea.id
          AND ledger.configuration_version_id = v_version.id
          AND ledger.competition_id = v_competition.id
          AND milestone.stage_number = stage.stage_number
    ) AS points ON true
    WHERE stage.configuration_version_id = v_version.id
      AND stage.stage_number BETWEEN 1 AND 6
      AND stage.stage_kind = 'development';

  SELECT LEAST(
           700,
           GREATEST(0, COALESCE(pg_catalog.sum(ledger.points), 0))
         )::integer
    INTO v_total_points
    FROM public.official_points_ledger AS ledger
    WHERE ledger.idea_id = v_idea.id
      AND ledger.configuration_version_id = v_version.id
      AND ledger.competition_id = v_competition.id
      AND ledger.stage_number BETWEEN 1 AND 6;

  SELECT COALESCE(
           pg_catalog.jsonb_agg(
             pg_catalog.jsonb_build_object(
               'stage_number', ledger.stage_number,
               'milestone', milestone.display_name,
               'kind', CASE ledger.entry_kind
                 WHEN 'award' THEN 'award'
                 ELSE 'correction'
               END,
               'points', ledger.points,
               'recorded_at', ledger.recorded_at
             )
             ORDER BY ledger.recorded_at, ledger.entry_id
           ),
           '[]'::jsonb
         )
    INTO v_history
    FROM public.official_points_ledger AS ledger
    JOIN public.scoring_milestone_catalog AS milestone
      ON milestone.configuration_version_id = ledger.configuration_version_id
     AND milestone.milestone_key = ledger.milestone_key
    WHERE ledger.idea_id = v_idea.id
      AND ledger.configuration_version_id = v_version.id
      AND ledger.competition_id = v_competition.id
      AND ledger.stage_number BETWEEN 1 AND 6;

  RETURN pg_catalog.jsonb_build_object(
    'state', 'available',
    'version_number', v_version.version_number,
    'catalog_version', v_catalog_version,
    'maximum_points', 700,
    'total_points', v_total_points,
    'stages', COALESCE(v_stages, '[]'::jsonb),
    'milestones', COALESCE(v_milestones, '[]'::jsonb),
    'history', v_history
  );
END
$function$;
ALTER FUNCTION public.get_participant_idea_scorecard(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_participant_idea_scorecard(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_participant_idea_scorecard(uuid)
  TO authenticated;

COMMENT ON FUNCTION public.assign_idea_competition(uuid, uuid) IS
  'One-time staff-authorized idea participation assignment; refuses incompatible scoring history.';
COMMENT ON FUNCTION public.get_participant_idea_scorecard(uuid) IS
  'Read-only owner scorecard; exposes participant criteria and sanitized ledger-derived points only.';

COMMIT;