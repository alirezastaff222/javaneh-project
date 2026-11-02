BEGIN;

CREATE FUNCTION public.get_participant_milestone_evaluations(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_competition public.competitions%ROWTYPE;
  v_version public.scoring_configuration_versions%ROWTYPE;
  v_catalog_version text;
  v_milestones jsonb;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
   WHERE idea.id = p_idea_id
     AND idea.owner_id = v_actor_id;
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
  IF NOT FOUND OR v_competition.status <> 'active' THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'competition_inactive'
    );
  END IF;
  SELECT version.* INTO v_version
    FROM public.scoring_configuration_versions AS version
   WHERE version.id = v_competition.scoring_configuration_version_id;
  IF NOT FOUND OR v_version.status <> 'active' THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'scoring_unavailable'
    );
  END IF;
  SELECT pg_catalog.min(milestone.catalog_version)
    INTO v_catalog_version
    FROM public.scoring_milestone_catalog AS milestone
   WHERE milestone.configuration_version_id = v_version.id
     AND milestone.stage_number BETWEEN 1 AND 6
     AND milestone.is_active
     AND milestone.catalog_status = 'active';
  IF v_catalog_version IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'scoring_unavailable'
    );
  END IF;

  SELECT pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'milestone_key', milestone.milestone_key,
      'stage_number', milestone.stage_number,
      'name', milestone.display_name,
      'criteria', milestone.participant_description,
      'validation_mode', milestone.validation_mode,
      'status', COALESCE(request.status, 'not_submitted'),
      'request_id', request.request_id,
      'objective_passed', request.objective_passed,
      'objective_result', request.objective_result,
      'feedback', validation.reason,
      'evaluation_level', validation.evaluation_level,
      'submitted_at', request.submitted_at,
      'updated_at', request.updated_at
    )
    ORDER BY milestone.stage_number, milestone.sort_order
  ) INTO v_milestones
    FROM public.scoring_milestone_catalog AS milestone
    LEFT JOIN LATERAL (
      SELECT validation_request.*
        FROM public.milestone_validation_requests AS validation_request
       WHERE validation_request.idea_id = v_idea.id
         AND validation_request.configuration_version_id = v_version.id
         AND validation_request.milestone_key = milestone.milestone_key
       ORDER BY validation_request.idea_revision DESC,
                validation_request.submitted_at DESC
       LIMIT 1
    ) AS request ON true
    LEFT JOIN LATERAL (
      SELECT decision.reason, decision.evaluation_level
        FROM public.milestone_validations AS decision
       WHERE decision.validation_request_id = request.request_id
       ORDER BY decision.validated_at DESC
       LIMIT 1
    ) AS validation ON true
   WHERE milestone.configuration_version_id = v_version.id
     AND milestone.catalog_version = v_catalog_version
     AND milestone.stage_number BETWEEN 1 AND 6
     AND milestone.is_active
     AND milestone.catalog_status = 'active';

  RETURN pg_catalog.jsonb_build_object(
    'state', 'available',
    'idea_revision', v_idea.revision,
    'configuration_version_id', v_version.id,
    'catalog_version', v_catalog_version,
    'milestones', COALESCE(v_milestones, '[]'::jsonb)
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
ALTER FUNCTION public.get_participant_milestone_evaluations(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_participant_milestone_evaluations(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_participant_milestone_evaluations(uuid)
  TO authenticated;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
