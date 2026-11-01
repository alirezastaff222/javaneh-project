BEGIN;

CREATE FUNCTION public.get_own_submitted_idea_dossier_history(
  p_idea_id uuid
)
RETURNS TABLE (
  revision integer,
  dossier jsonb,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_authorized_idea_id uuid;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL OR p_idea_id IS NULL THEN
    RAISE EXCEPTION 'Dossier history is unavailable'
      USING ERRCODE = '42501';
  END IF;

  SELECT idea.id INTO v_authorized_idea_id
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id
      AND idea.status = 'submitted';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dossier history is unavailable'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT version.revision, version.dossier, version.created_at
      FROM public.idea_dossier_versions AS version
      WHERE version.idea_id = v_authorized_idea_id
      ORDER BY version.revision ASC;
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
ALTER FUNCTION public.get_own_submitted_idea_dossier_history(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION
  public.get_own_submitted_idea_dossier_history(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION
  public.get_own_submitted_idea_dossier_history(uuid)
  TO authenticated;

COMMENT ON FUNCTION public.get_own_submitted_idea_dossier_history(uuid) IS
  'Read-only participant access to prior snapshots of the caller own submitted dossier.';

COMMIT;