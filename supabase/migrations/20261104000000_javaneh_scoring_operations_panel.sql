BEGIN;

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

CREATE FUNCTION public.get_scoring_operations_summary()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_result jsonb;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM public.scoring_role_assignments AS role_assignment
     WHERE role_assignment.user_id = v_actor_id
       AND role_assignment.role_name IN ('platform_owner', 'scoring_administrator')
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator access required' USING ERRCODE = '42501';
  END IF;

  SELECT pg_catalog.jsonb_build_object(
    'configurations', COALESCE(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'configuration_id', configuration.id,
        'configuration_key', COALESCE(configuration.configuration_key, 'unkeyed'),
        'version_id', version.id,
        'version_number', version.version_number,
        'status', version.status,
        'ready', public.scoring_configuration_is_ready(version.id),
        'development_max_points', COALESCE(version.development_max_points, 0),
        'human_jury_max_points', COALESCE(version.human_jury_max_points, 0),
        'overall_max_points', COALESCE(version.overall_max_points, 0),
        'rounding_policy', COALESCE(version.rounding_policy, ''),
        'competition', CASE WHEN competition.id IS NULL THEN NULL ELSE
          pg_catalog.jsonb_build_object(
            'id', competition.id,
            'key', competition.competition_key,
            'name', competition.name,
            'status', competition.status
          ) END,
        'milestones', COALESCE((
          SELECT pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'milestone_key', milestone.milestone_key,
              'stage_number', milestone.stage_number,
              'definition', COALESCE(milestone.participant_description, milestone.definition),
              'validation_mode', milestone.validation_mode,
              'point_value', milestone.point_value,
              'is_active', milestone.is_active
            ) ORDER BY milestone.stage_number, milestone.sort_order, milestone.milestone_key
          )
          FROM public.scoring_milestone_catalog AS milestone
          WHERE milestone.configuration_version_id = version.id
        ), '[]'::jsonb),
        'pending_evaluations', (
          SELECT pg_catalog.count(*)
            FROM public.milestone_validation_requests AS request
           WHERE request.configuration_version_id = version.id
             AND request.status = 'pending_validation'
        ),
        'awarded_development_points', (
          SELECT COALESCE(pg_catalog.sum(ledger.points), 0)
            FROM public.official_points_ledger AS ledger
           WHERE ledger.configuration_version_id = version.id
             AND ledger.entry_kind IN ('award', 'compensation')
        )
      ) ORDER BY version.created_at DESC
    ), '[]'::jsonb)
  ) INTO v_result
  FROM public.scoring_configurations AS configuration
  JOIN public.scoring_configuration_versions AS version
    ON version.configuration_id = configuration.id
  LEFT JOIN public.competitions AS competition
    ON competition.scoring_configuration_version_id = version.id;

  RETURN v_result;
END
$function$;

ALTER FUNCTION public.get_scoring_operations_summary()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_scoring_operations_summary()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_scoring_operations_summary()
  TO authenticated;

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
