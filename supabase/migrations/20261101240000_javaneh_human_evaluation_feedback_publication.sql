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

ALTER TABLE public.idea_evaluation_permissions
  DROP CONSTRAINT IF EXISTS idea_evaluation_permissions_permission_check;

ALTER TABLE public.idea_evaluation_permissions
  ADD CONSTRAINT idea_evaluation_permissions_permission_check
  CHECK (permission IN ('assignment_manager', 'human_evaluator', 'feedback_publisher'));

CREATE TABLE public.idea_feedback_versions (
  version_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL REFERENCES public.ideas(id) ON DELETE CASCADE,
  cycle_id uuid NOT NULL REFERENCES public.idea_evaluation_cycles(cycle_id) ON DELETE CASCADE,
  evaluator_user_id uuid NOT NULL,
  publisher_user_id uuid NOT NULL,
  version_number integer NOT NULL CHECK (version_number > 0),
  feedback_content text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(feedback_content)) > 0),
  previous_version_id uuid REFERENCES public.idea_feedback_versions(version_id) ON DELETE RESTRICT,
  published_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT idea_feedback_versions_version_chain CHECK (
    previous_version_id IS NULL OR previous_version_id <> version_id
  ),
  CONSTRAINT idea_feedback_versions_publisher_diff CHECK (
    evaluator_user_id <> publisher_user_id
  )
);

CREATE UNIQUE INDEX idea_feedback_versions_cycle_version_idx
  ON public.idea_feedback_versions (cycle_id, version_number);

CREATE INDEX idea_feedback_versions_idea_idx
  ON public.idea_feedback_versions (idea_id, version_number DESC, version_id);

ALTER TABLE public.idea_feedback_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_feedback_versions FORCE ROW LEVEL SECURITY;

CREATE POLICY idea_feedback_versions_executor_all
  ON public.idea_feedback_versions FOR ALL
  TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE public.idea_feedback_versions
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON TABLE public.idea_feedback_versions
  TO javaneh_identity_executor;

CREATE TABLE public.idea_feedback_drafts (
  draft_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL REFERENCES public.ideas(id) ON DELETE CASCADE,
  cycle_id uuid NOT NULL UNIQUE REFERENCES public.idea_evaluation_cycles(cycle_id) ON DELETE CASCADE,
  evaluator_user_id uuid NOT NULL,
  feedback_content text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(feedback_content)) > 0),
  previous_published_version_id uuid REFERENCES public.idea_feedback_versions(version_id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'consumed')),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  consumed_at timestamptz,
  publication_version_id uuid REFERENCES public.idea_feedback_versions(version_id) ON DELETE RESTRICT,
  CONSTRAINT idea_feedback_drafts_state_shape CHECK (
    (status = 'active' AND consumed_at IS NULL AND publication_version_id IS NULL)
    OR
    (status = 'consumed' AND consumed_at IS NOT NULL AND publication_version_id IS NOT NULL)
  )
);

CREATE INDEX idea_feedback_drafts_cycle_idx
  ON public.idea_feedback_drafts (cycle_id, status, updated_at DESC);

ALTER TABLE public.idea_feedback_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_feedback_drafts FORCE ROW LEVEL SECURITY;

CREATE POLICY idea_feedback_drafts_executor_all
  ON public.idea_feedback_drafts FOR ALL
  TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE public.idea_feedback_drafts
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.idea_feedback_drafts
  TO javaneh_identity_executor;

CREATE FUNCTION public.guard_idea_feedback_version_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Published feedback history is immutable' USING ERRCODE = '42501';
  END IF;

  IF NEW.version_id IS DISTINCT FROM OLD.version_id
     OR NEW.idea_id IS DISTINCT FROM OLD.idea_id
     OR NEW.cycle_id IS DISTINCT FROM OLD.cycle_id
     OR NEW.evaluator_user_id IS DISTINCT FROM OLD.evaluator_user_id
     OR NEW.publisher_user_id IS DISTINCT FROM OLD.publisher_user_id
     OR NEW.version_number IS DISTINCT FROM OLD.version_number
     OR NEW.feedback_content IS DISTINCT FROM OLD.feedback_content
     OR NEW.previous_version_id IS DISTINCT FROM OLD.previous_version_id
     OR NEW.published_at IS DISTINCT FROM OLD.published_at THEN
    RAISE EXCEPTION 'Published feedback versions are immutable' USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_idea_feedback_version_update()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER idea_feedback_versions_guard_update
  BEFORE UPDATE OR DELETE ON public.idea_feedback_versions
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_idea_feedback_version_update();

CREATE FUNCTION public.guard_idea_feedback_draft_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
  v_latest_version public.idea_feedback_versions%ROWTYPE;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Feedback drafts are not deleted through ordinary update paths' USING ERRCODE = '42501';
  END IF;

  IF NEW.draft_id IS DISTINCT FROM OLD.draft_id
     OR NEW.idea_id IS DISTINCT FROM OLD.idea_id
     OR NEW.cycle_id IS DISTINCT FROM OLD.cycle_id
     OR NEW.evaluator_user_id IS DISTINCT FROM OLD.evaluator_user_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'Feedback draft identity and creation time are immutable' USING ERRCODE = '42501';
  END IF;

  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.cycle_id = NEW.cycle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Feedback draft must reference a valid evaluation cycle' USING ERRCODE = '23514';
  END IF;
  IF v_cycle.idea_id IS DISTINCT FROM NEW.idea_id THEN
    RAISE EXCEPTION 'Feedback draft idea and cycle must match' USING ERRCODE = '23514';
  END IF;
  IF v_cycle.status IS DISTINCT FROM 'completed' OR v_cycle.completed_at IS NULL THEN
    RAISE EXCEPTION 'Feedback operations require a completed evaluation cycle' USING ERRCODE = '23514';
  END IF;
  IF v_cycle.assigned_evaluator_id IS DISTINCT FROM NEW.evaluator_user_id THEN
    RAISE EXCEPTION 'Only the assigned evaluator may own the draft' USING ERRCODE = '42501';
  END IF;
  IF NEW.status = 'consumed' THEN
    IF NEW.consumed_at IS NULL OR NEW.publication_version_id IS NULL THEN
      RAISE EXCEPTION 'Consumed drafts require a publication record' USING ERRCODE = '23514';
    END IF;
  ELSE
    IF NEW.consumed_at IS NOT NULL OR NEW.publication_version_id IS NOT NULL THEN
      RAISE EXCEPTION 'Active drafts cannot reference a published version' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NEW.previous_published_version_id IS NOT NULL THEN
    SELECT version.* INTO v_latest_version
      FROM public.idea_feedback_versions AS version
      WHERE version.version_id = NEW.previous_published_version_id
        AND version.cycle_id = NEW.cycle_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Correction draft must reference a valid cycle version' USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_idea_feedback_draft_update()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER idea_feedback_drafts_guard_update
  BEFORE UPDATE OR DELETE ON public.idea_feedback_drafts
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_idea_feedback_draft_update();

CREATE FUNCTION public.create_idea_feedback_draft(
  p_idea_id uuid,
  p_feedback_content text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
  v_draft_id uuid;
  v_latest_version public.idea_feedback_versions%ROWTYPE;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_feedback_content IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_feedback_content)) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_evaluation_permissions AS permission
      WHERE permission.user_id = v_actor_id
        AND permission.permission = 'human_evaluator'
  ) THEN
    RAISE EXCEPTION 'Human evaluator authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;

  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.idea_id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_cycle.status IS DISTINCT FROM 'completed' OR v_cycle.completed_at IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_completed');
  END IF;
  IF v_cycle.assigned_evaluator_id IS DISTINCT FROM v_actor_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_assigned');
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.idea_feedback_drafts AS draft
      WHERE draft.cycle_id = v_cycle.cycle_id
        AND draft.status = 'active'
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'draft_exists');
  END IF;

  SELECT version.* INTO v_latest_version
    FROM public.idea_feedback_versions AS version
    WHERE version.cycle_id = v_cycle.cycle_id
    ORDER BY version.version_number DESC, version.published_at DESC
    LIMIT 1;

  INSERT INTO public.idea_feedback_drafts (
    idea_id,
    cycle_id,
    evaluator_user_id,
    feedback_content,
    previous_published_version_id
  )
  VALUES (
    v_cycle.idea_id,
    v_cycle.cycle_id,
    v_actor_id,
    p_feedback_content,
    v_latest_version.version_id
  )
  RETURNING draft_id INTO v_draft_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'created',
    'draft_id', v_draft_id,
    'previous_published_version_id', v_latest_version.version_id
  );
END
$function$;
ALTER FUNCTION public.create_idea_feedback_draft(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.create_idea_feedback_draft(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_idea_feedback_draft(uuid, text)
  TO authenticated;

CREATE FUNCTION public.get_own_idea_feedback_draft(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
  v_draft public.idea_feedback_drafts%ROWTYPE;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_idea_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;

  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.idea_id = p_idea_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_cycle.status IS DISTINCT FROM 'completed' OR v_cycle.completed_at IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_completed');
  END IF;
  IF v_cycle.assigned_evaluator_id IS DISTINCT FROM v_actor_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_assigned');
  END IF;

  SELECT draft.* INTO v_draft
    FROM public.idea_feedback_drafts AS draft
    WHERE draft.cycle_id = v_cycle.cycle_id
      AND draft.status = 'active';
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'available',
    'draft_id', v_draft.draft_id,
    'feedback_content', v_draft.feedback_content,
    'previous_published_version_id', v_draft.previous_published_version_id,
    'updated_at', v_draft.updated_at
  );
END
$function$;
ALTER FUNCTION public.get_own_idea_feedback_draft(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_own_idea_feedback_draft(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_own_idea_feedback_draft(uuid)
  TO authenticated;

CREATE FUNCTION public.update_idea_feedback_draft(
  p_draft_id uuid,
  p_feedback_content text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_draft public.idea_feedback_drafts%ROWTYPE;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_draft_id IS NULL OR p_feedback_content IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_feedback_content)) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_evaluation_permissions AS permission
      WHERE permission.user_id = v_actor_id
        AND permission.permission = 'human_evaluator'
  ) THEN
    RAISE EXCEPTION 'Human evaluator authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT draft.* INTO v_draft
    FROM public.idea_feedback_drafts AS draft
    WHERE draft.draft_id = p_draft_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_draft.status IS DISTINCT FROM 'active' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'consumed');
  END IF;
  IF v_draft.evaluator_user_id IS DISTINCT FROM v_actor_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_assigned');
  END IF;

  UPDATE public.idea_feedback_drafts AS draft
    SET feedback_content = p_feedback_content,
        updated_at = pg_catalog.clock_timestamp()
    WHERE draft.draft_id = v_draft.draft_id;

  RETURN pg_catalog.jsonb_build_object('outcome', 'updated');
END
$function$;
ALTER FUNCTION public.update_idea_feedback_draft(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.update_idea_feedback_draft(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.update_idea_feedback_draft(uuid, text)
  TO authenticated;

CREATE FUNCTION public.create_correction_idea_feedback_draft(
  p_idea_id uuid,
  p_feedback_content text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
  v_latest_version public.idea_feedback_versions%ROWTYPE;
  v_draft_id uuid;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_feedback_content IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_feedback_content)) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.idea_id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_cycle.status IS DISTINCT FROM 'completed' OR v_cycle.completed_at IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_completed');
  END IF;
  IF v_cycle.assigned_evaluator_id IS DISTINCT FROM v_actor_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_assigned');
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_evaluation_permissions AS permission
      WHERE permission.user_id = v_actor_id
        AND permission.permission = 'human_evaluator'
  ) THEN
    RAISE EXCEPTION 'Human evaluator authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT version.* INTO v_latest_version
    FROM public.idea_feedback_versions AS version
    WHERE version.cycle_id = v_cycle.cycle_id
    ORDER BY version.version_number DESC, version.published_at DESC
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'no_published_version');
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.idea_feedback_drafts AS draft
      WHERE draft.cycle_id = v_cycle.cycle_id
        AND draft.status = 'active'
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'draft_exists');
  END IF;

  INSERT INTO public.idea_feedback_drafts (
    idea_id,
    cycle_id,
    evaluator_user_id,
    feedback_content,
    previous_published_version_id
  )
  VALUES (
    v_cycle.idea_id,
    v_cycle.cycle_id,
    v_actor_id,
    p_feedback_content,
    v_latest_version.version_id
  )
  RETURNING draft_id INTO v_draft_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'created',
    'draft_id', v_draft_id,
    'previous_published_version_id', v_latest_version.version_id
  );
END
$function$;
ALTER FUNCTION public.create_correction_idea_feedback_draft(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.create_correction_idea_feedback_draft(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_correction_idea_feedback_draft(uuid, text)
  TO authenticated;

CREATE FUNCTION public.get_eligible_feedback_draft_for_publication(p_draft_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_draft public.idea_feedback_drafts%ROWTYPE;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF p_draft_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_evaluation_permissions AS permission
      WHERE permission.user_id = v_actor_id
        AND permission.permission = 'feedback_publisher'
  ) THEN
    RAISE EXCEPTION 'Feedback publisher authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT draft.* INTO v_draft
    FROM public.idea_feedback_drafts AS draft
    WHERE draft.draft_id = p_draft_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;

  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.cycle_id = v_draft.cycle_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_draft.status IS DISTINCT FROM 'active' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_consumed');
  END IF;
  IF v_cycle.status IS DISTINCT FROM 'completed' OR v_cycle.completed_at IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_completed');
  END IF;
  IF v_draft.evaluator_user_id = v_actor_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'same_user');
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'available',
    'draft_id', v_draft.draft_id,
    'idea_id', v_draft.idea_id,
    'cycle_id', v_draft.cycle_id,
    'feedback_content', v_draft.feedback_content,
    'previous_published_version_id', v_draft.previous_published_version_id,
    'evaluator_user_id', v_draft.evaluator_user_id
  );
END
$function$;
ALTER FUNCTION public.get_eligible_feedback_draft_for_publication(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_eligible_feedback_draft_for_publication(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_eligible_feedback_draft_for_publication(uuid)
  TO authenticated;

CREATE FUNCTION public.get_eligible_feedback_drafts_for_publication()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_drafts jsonb;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_evaluation_permissions AS permission
      WHERE permission.user_id = v_actor_id
        AND permission.permission = 'feedback_publisher'
  ) THEN
    RAISE EXCEPTION 'Feedback publisher authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'draft_id', draft.draft_id,
        'idea_id', draft.idea_id,
        'cycle_id', draft.cycle_id,
        'feedback_content', draft.feedback_content,
        'previous_published_version_id', draft.previous_published_version_id,
        'evaluator_user_id', draft.evaluator_user_id,
        'updated_at', draft.updated_at
      )
      ORDER BY draft.updated_at DESC
    ),
    '[]'::jsonb
  )
    INTO v_drafts
    FROM public.idea_feedback_drafts AS draft
    JOIN public.idea_evaluation_cycles AS cycle
      ON cycle.cycle_id = draft.cycle_id
    WHERE draft.status = 'active'
      AND cycle.status = 'completed'
      AND cycle.completed_at IS NOT NULL
      AND draft.evaluator_user_id <> v_actor_id;

  RETURN pg_catalog.jsonb_build_object('outcome', 'available', 'drafts', v_drafts);
END
$function$;
ALTER FUNCTION public.get_eligible_feedback_drafts_for_publication()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_eligible_feedback_drafts_for_publication()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_eligible_feedback_drafts_for_publication()
  TO authenticated;

CREATE FUNCTION public.publish_idea_feedback_draft(p_draft_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_draft public.idea_feedback_drafts%ROWTYPE;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
  v_latest_version public.idea_feedback_versions%ROWTYPE;
  v_next_version_number integer;
  v_new_version_id uuid;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_draft_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_evaluation_permissions AS permission
      WHERE permission.user_id = v_actor_id
        AND permission.permission = 'feedback_publisher'
  ) THEN
    RAISE EXCEPTION 'Feedback publisher authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT draft.* INTO v_draft
    FROM public.idea_feedback_drafts AS draft
    WHERE draft.draft_id = p_draft_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_draft.status IS DISTINCT FROM 'active' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_consumed');
  END IF;

  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.cycle_id = v_draft.cycle_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_cycle.status IS DISTINCT FROM 'completed' OR v_cycle.completed_at IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_completed');
  END IF;
  IF v_draft.evaluator_user_id = v_actor_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'same_user');
  END IF;
  IF v_draft.evaluator_user_id IS DISTINCT FROM v_cycle.assigned_evaluator_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_assigned');
  END IF;

  SELECT version.* INTO v_latest_version
    FROM public.idea_feedback_versions AS version
    WHERE version.cycle_id = v_cycle.cycle_id
    ORDER BY version.version_number DESC, version.published_at DESC
    LIMIT 1;

  IF v_draft.previous_published_version_id IS NOT NULL THEN
    IF v_latest_version.version_id IS DISTINCT FROM v_draft.previous_published_version_id THEN
      RETURN pg_catalog.jsonb_build_object(
        'outcome', 'stale_draft',
        'latest_version_id', v_latest_version.version_id,
        'expected_version_id', v_draft.previous_published_version_id
      );
    END IF;
  ELSIF v_latest_version.version_id IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_draft',
      'latest_version_id', v_latest_version.version_id,
      'expected_version_id', NULL
    );
  END IF;

  v_next_version_number := COALESCE(v_latest_version.version_number, 0) + 1;

  INSERT INTO public.idea_feedback_versions (
    idea_id,
    cycle_id,
    evaluator_user_id,
    publisher_user_id,
    version_number,
    feedback_content,
    previous_version_id,
    published_at
  )
  VALUES (
    v_draft.idea_id,
    v_draft.cycle_id,
    v_draft.evaluator_user_id,
    v_actor_id,
    v_next_version_number,
    v_draft.feedback_content,
    v_draft.previous_published_version_id,
    pg_catalog.clock_timestamp()
  )
  RETURNING version_id INTO v_new_version_id;

  UPDATE public.idea_feedback_drafts AS draft
    SET status = 'consumed',
        consumed_at = pg_catalog.clock_timestamp(),
        publication_version_id = v_new_version_id,
        updated_at = pg_catalog.clock_timestamp()
    WHERE draft.draft_id = v_draft.draft_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'published',
    'version_id', v_new_version_id,
    'version_number', v_next_version_number,
    'published_at', pg_catalog.clock_timestamp()
  );
END
$function$;
ALTER FUNCTION public.publish_idea_feedback_draft(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.publish_idea_feedback_draft(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.publish_idea_feedback_draft(uuid)
  TO authenticated;

CREATE FUNCTION public.get_own_idea_published_feedback(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_version public.idea_feedback_versions%ROWTYPE;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_actor_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;

  SELECT version.* INTO v_version
    FROM public.idea_feedback_versions AS version
    WHERE version.idea_id = p_idea_id
    ORDER BY version.version_number DESC, version.published_at DESC
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'empty');
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'available',
    'feedback_content', v_version.feedback_content,
    'version_number', v_version.version_number,
    'published_at', v_version.published_at
  );
END
$function$;
ALTER FUNCTION public.get_own_idea_published_feedback(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_own_idea_published_feedback(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_own_idea_published_feedback(uuid)
  TO authenticated;

COMMENT ON TABLE public.idea_feedback_versions IS
  'Immutable published human-evaluation feedback versions created by an authorized publisher.';
COMMENT ON TABLE public.idea_feedback_drafts IS
  'Private evaluator-authored draft feedback for completed evaluations.';
COMMENT ON FUNCTION public.publish_idea_feedback_draft(uuid) IS
  'Publishes a completed evaluation draft atomically while enforcing evaluator/publisher separation.';
COMMENT ON FUNCTION public.get_own_idea_published_feedback(uuid) IS
  'Owner-scoped participant read of the latest published feedback only.';

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
