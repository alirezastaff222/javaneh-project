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
    RAISE EXCEPTION 'The existing scorecard executor prerequisite is missing or unsafe'
      USING ERRCODE = '42501';
  END IF;
END
$prerequisite_check$;

CREATE OR REPLACE FUNCTION public.get_participant_idea_scorecard(p_idea_id uuid)
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
             'awarded_points', GREATEST(0, ledger.net_points),
             'maximum_points', milestone.point_value
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

COMMENT ON FUNCTION public.get_participant_idea_scorecard(uuid) IS
  'Read-only owner scorecard; exposes participant criteria, configured milestone maxima, and sanitized ledger-derived points only.';

COMMIT;
