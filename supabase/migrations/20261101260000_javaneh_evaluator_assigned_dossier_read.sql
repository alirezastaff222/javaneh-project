BEGIN;

CREATE FUNCTION public.get_assigned_idea_evaluation_dossier(
  p_idea_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
  v_idea public.ideas%ROWTYPE;
  v_revision integer;
  v_dossier jsonb;
  v_stage_count integer;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL OR p_idea_id IS NULL THEN
    RAISE EXCEPTION 'Dossier unavailable'
      USING ERRCODE = '42501';
  END IF;

  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.idea_id = p_idea_id
      AND cycle.assigned_evaluator_id = v_actor_id
      AND EXISTS (
        SELECT 1
          FROM public.idea_evaluation_permissions AS permission
          WHERE permission.user_id = v_actor_id
            AND permission.permission = 'human_evaluator'
      );
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.status = 'submitted'
      AND idea.submitted_at IS NOT NULL;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;

  IF v_cycle.status = 'awaiting_review'
     AND v_cycle.evaluated_revision IS NULL THEN
    v_revision := v_idea.revision;
  ELSIF v_cycle.status IN ('in_progress', 'completed')
        AND v_cycle.evaluated_revision IS NOT NULL
        AND v_cycle.evaluated_revision = v_idea.revision THEN
    v_revision := v_cycle.evaluated_revision;
  ELSE
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;

  SELECT
    pg_catalog.jsonb_build_object(
      'stages',
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'stage_number', stage.stage_number,
          'stage_key', stage.stage_key,
          'data', stage.data,
          'confirmed_at', stage.confirmed_at
        )
        ORDER BY stage.stage_number
      )
    ),
    pg_catalog.count(*)::integer
    INTO v_dossier, v_stage_count
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number BETWEEN 1 AND 6;

  IF v_stage_count <> 6 THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'available',
    'revision', v_revision,
    'dossier', v_dossier
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
ALTER FUNCTION public.get_assigned_idea_evaluation_dossier(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION
  public.get_assigned_idea_evaluation_dossier(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.get_assigned_idea_evaluation_dossier(uuid)
  TO authenticated;

COMMENT ON FUNCTION public.get_assigned_idea_evaluation_dossier(uuid) IS
  'Returns only the six current submitted dossier stages for the calling, authorized evaluator; after start, the cycle revision must still match.';

COMMIT;
