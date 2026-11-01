BEGIN;

CREATE FUNCTION public.get_own_assigned_idea_evaluations()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_items jsonb;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_evaluation_permissions AS permission
      WHERE permission.user_id = v_actor_id
        AND permission.permission = 'human_evaluator'
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'available',
      'items', '[]'::jsonb
    );
  END IF;

  SELECT pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'idea_id', cycle.idea_id,
      'status', cycle.status,
      'assigned_at', cycle.assigned_at,
      'started_at', cycle.started_at,
      'completed_at', cycle.completed_at,
      'submitted_at', idea.submitted_at,
      'current_step', idea.current_step
    )
    ORDER BY cycle.assigned_at DESC NULLS LAST, cycle.idea_id
  ) INTO v_items
    FROM public.idea_evaluation_cycles AS cycle
    JOIN public.ideas AS idea
      ON idea.id = cycle.idea_id
    WHERE cycle.assigned_evaluator_id = v_actor_id
      AND idea.status = 'submitted';

  IF v_items IS NULL THEN
    v_items := '[]'::jsonb;
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'available',
    'items', v_items
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
ALTER FUNCTION public.get_own_assigned_idea_evaluations()
  OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_own_assigned_idea_evaluations()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_own_assigned_idea_evaluations()
  TO authenticated;

COMMENT ON FUNCTION public.get_own_assigned_idea_evaluations() IS
  'Returns the submitted ideas currently assigned to the calling evaluator.';

COMMIT;
