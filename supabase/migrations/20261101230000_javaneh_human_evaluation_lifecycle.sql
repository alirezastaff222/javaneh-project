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

CREATE TABLE public.idea_evaluation_permissions (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  permission text NOT NULL CHECK (
    permission IN ('assignment_manager', 'human_evaluator')
  ),
  granted_by uuid NOT NULL,
  granted_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(reason)) > 0),
  PRIMARY KEY (user_id, permission)
);

ALTER TABLE public.idea_evaluation_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_evaluation_permissions FORCE ROW LEVEL SECURITY;

CREATE POLICY idea_evaluation_permissions_executor_read
  ON public.idea_evaluation_permissions FOR SELECT
  TO javaneh_identity_executor
  USING (true);

REVOKE ALL ON TABLE public.idea_evaluation_permissions
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE public.idea_evaluation_permissions
  TO javaneh_identity_executor;

CREATE TABLE public.idea_evaluation_cycles (
  cycle_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL UNIQUE
    REFERENCES public.ideas(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'awaiting_review'
    CHECK (status IN ('awaiting_review', 'in_progress', 'completed')),
  assigned_evaluator_id uuid,
  assigned_at timestamptz,
  evaluated_revision integer CHECK (
    evaluated_revision IS NULL OR evaluated_revision > 0
  ),
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT idea_evaluation_cycles_assignment_shape CHECK (
    (assigned_evaluator_id IS NULL) = (assigned_at IS NULL)
  ),
  CONSTRAINT idea_evaluation_cycles_lifecycle_shape CHECK (
    (status = 'awaiting_review'
      AND evaluated_revision IS NULL
      AND started_at IS NULL
      AND completed_at IS NULL)
    OR
    (status = 'in_progress'
      AND assigned_evaluator_id IS NOT NULL
      AND evaluated_revision IS NOT NULL
      AND started_at IS NOT NULL
      AND completed_at IS NULL)
    OR
    (status = 'completed'
      AND assigned_evaluator_id IS NOT NULL
      AND evaluated_revision IS NOT NULL
      AND started_at IS NOT NULL
      AND completed_at IS NOT NULL
      AND completed_at >= started_at)
  )
);

CREATE INDEX idea_evaluation_cycles_assignment_queue_idx
  ON public.idea_evaluation_cycles (status, assigned_at, cycle_id);

CREATE TABLE public.idea_evaluation_events (
  event_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  cycle_id uuid NOT NULL
    REFERENCES public.idea_evaluation_cycles(cycle_id) ON DELETE CASCADE,
  event_type text NOT NULL CHECK (event_type IN (
    'cycle_created', 'evaluator_assigned',
    'evaluation_started', 'evaluation_completed'
  )),
  actor_type text NOT NULL CHECK (actor_type IN (
    'participant', 'assignment_manager', 'human_evaluator', 'system'
  )),
  actor_user_id uuid,
  evaluator_user_id uuid,
  idea_revision integer CHECK (idea_revision IS NULL OR idea_revision > 0),
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT idea_evaluation_events_actor_shape CHECK (
    (actor_type = 'system' AND actor_user_id IS NULL)
    OR (actor_type <> 'system' AND actor_user_id IS NOT NULL)
  ),
  CONSTRAINT idea_evaluation_events_metadata_shape CHECK (
    (event_type = 'cycle_created'
      AND actor_type IN ('participant', 'system')
      AND evaluator_user_id IS NULL
      AND idea_revision IS NULL)
    OR
    (event_type = 'evaluator_assigned'
      AND actor_type = 'assignment_manager'
      AND evaluator_user_id IS NOT NULL
      AND idea_revision IS NULL)
    OR
    (event_type = 'evaluation_started'
      AND actor_type = 'human_evaluator'
      AND evaluator_user_id IS NULL
      AND idea_revision IS NOT NULL)
    OR
    (event_type = 'evaluation_completed'
      AND actor_type = 'human_evaluator'
      AND evaluator_user_id IS NULL
      AND idea_revision IS NULL)
  )
);

CREATE INDEX idea_evaluation_events_cycle_idx
  ON public.idea_evaluation_events (cycle_id, occurred_at, event_id);

ALTER TABLE public.idea_evaluation_cycles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_evaluation_cycles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.idea_evaluation_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_evaluation_events FORCE ROW LEVEL SECURITY;

CREATE POLICY idea_evaluation_cycles_executor_all
  ON public.idea_evaluation_cycles FOR ALL
  TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY idea_evaluation_events_executor_all
  ON public.idea_evaluation_events FOR ALL
  TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE
  public.idea_evaluation_cycles,
  public.idea_evaluation_events
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.idea_evaluation_cycles
  TO javaneh_identity_executor;
GRANT SELECT, INSERT ON TABLE
  public.idea_evaluation_events
  TO javaneh_identity_executor;

CREATE FUNCTION public.guard_idea_evaluation_cycle_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF NEW.cycle_id IS DISTINCT FROM OLD.cycle_id
     OR NEW.idea_id IS DISTINCT FROM OLD.idea_id
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'Evaluation cycle identity and creation time are immutable'
      USING ERRCODE = '42501';
  END IF;

  IF OLD.status = 'awaiting_review' THEN
    IF NEW.status NOT IN ('awaiting_review', 'in_progress') THEN
      RAISE EXCEPTION 'Invalid evaluation lifecycle transition'
        USING ERRCODE = '23514';
    END IF;
  ELSIF OLD.status = 'in_progress' THEN
    IF NEW.status NOT IN ('in_progress', 'completed') THEN
      RAISE EXCEPTION 'Invalid evaluation lifecycle transition'
        USING ERRCODE = '23514';
    END IF;
  ELSIF OLD.status = 'completed' AND NEW.status <> 'completed' THEN
    RAISE EXCEPTION 'Completed evaluation cycles are immutable'
      USING ERRCODE = '23514';
  END IF;

  IF NEW.assigned_evaluator_id IS DISTINCT FROM OLD.assigned_evaluator_id
     AND OLD.status <> 'awaiting_review' THEN
    RAISE EXCEPTION 'An evaluator cannot be reassigned after evaluation starts'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.evaluated_revision IS DISTINCT FROM OLD.evaluated_revision
     AND NOT (OLD.status = 'awaiting_review' AND NEW.status = 'in_progress') THEN
    RAISE EXCEPTION 'The evaluated dossier revision is immutable after start'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.started_at IS DISTINCT FROM OLD.started_at
     AND NOT (OLD.status = 'awaiting_review' AND NEW.status = 'in_progress') THEN
    RAISE EXCEPTION 'Evaluation start time is immutable'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.completed_at IS DISTINCT FROM OLD.completed_at
     AND NOT (OLD.status = 'in_progress' AND NEW.status = 'completed') THEN
    RAISE EXCEPTION 'Evaluation completion time is immutable'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.assigned_at IS DISTINCT FROM OLD.assigned_at
     AND NOT (OLD.status = 'awaiting_review' AND NEW.status = 'awaiting_review') THEN
    RAISE EXCEPTION 'Evaluator assignment is immutable after evaluation starts'
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_idea_evaluation_cycle_update()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER idea_evaluation_cycles_guard_update
  BEFORE UPDATE ON public.idea_evaluation_cycles
  FOR EACH ROW EXECUTE FUNCTION public.guard_idea_evaluation_cycle_update();

CREATE FUNCTION public.create_idea_evaluation_cycle_on_submission()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_cycle_id uuid;
BEGIN
  IF NEW.status <> 'submitted' OR OLD.status = 'submitted' THEN
    RETURN NEW;
  END IF;

  v_actor_id := javaneh_private.current_uid();
  IF NEW.submitted_at IS NULL
     OR NEW.current_step <> 7
     OR v_actor_id IS DISTINCT FROM NEW.owner_id
     OR EXISTS (
       SELECT 1
         FROM public.idea_stages AS stage
         WHERE stage.idea_id = NEW.id
           AND (
             (stage.stage_number BETWEEN 1 AND 6
               AND stage.status <> 'confirmed')
             OR (stage.stage_number = 7
               AND (stage.status <> 'locked' OR stage.data <> '{}'::jsonb))
           )
     )
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_stages AS stage
         WHERE stage.idea_id = NEW.id
     ) <> 7 THEN
    RAISE EXCEPTION 'Only a valid owner submission can create an evaluation cycle'
      USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.idea_evaluation_cycles (idea_id, created_at)
  VALUES (NEW.id, NEW.submitted_at)
  RETURNING cycle_id INTO v_cycle_id;

  INSERT INTO public.idea_evaluation_events (
    cycle_id, event_type, actor_type, actor_user_id, occurred_at
  )
  VALUES (
    v_cycle_id, 'cycle_created', 'participant', v_actor_id, NEW.submitted_at
  );
  RETURN NEW;
END
$function$;
ALTER FUNCTION public.create_idea_evaluation_cycle_on_submission()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.create_idea_evaluation_cycle_on_submission()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER ideas_create_evaluation_cycle_after_submission
  AFTER UPDATE OF status ON public.ideas
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM 'submitted' AND NEW.status = 'submitted')
  EXECUTE FUNCTION public.create_idea_evaluation_cycle_on_submission();

INSERT INTO public.idea_evaluation_cycles (idea_id, created_at)
SELECT idea.id, idea.submitted_at
  FROM public.ideas AS idea
 WHERE idea.status = 'submitted'
ON CONFLICT (idea_id) DO NOTHING;

INSERT INTO public.idea_evaluation_events (
  cycle_id, event_type, actor_type, actor_user_id, occurred_at
)
SELECT cycle.cycle_id, 'cycle_created', 'system', NULL, cycle.created_at
  FROM public.idea_evaluation_cycles AS cycle
  JOIN public.ideas AS idea ON idea.id = cycle.idea_id
 WHERE idea.status = 'submitted'
   AND NOT EXISTS (
     SELECT 1
       FROM public.idea_evaluation_events AS event
       WHERE event.cycle_id = cycle.cycle_id
         AND event.event_type = 'cycle_created'
   );

CREATE FUNCTION public.assign_idea_evaluator(
  p_idea_id uuid,
  p_evaluator_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
  v_now timestamptz;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_evaluator_user_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF p_evaluator_user_id = v_actor_id THEN
    RAISE EXCEPTION 'An assignment manager cannot assign themselves'
      USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:authorization:v1:' || v_actor_id::text, 0
    )
  );
  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_evaluation_permissions AS permission
      WHERE permission.user_id = v_actor_id
        AND permission.permission = 'assignment_manager'
  ) THEN
    RAISE EXCEPTION 'Evaluation assignment authorization required'
      USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM public.idea_evaluation_permissions AS permission
      WHERE permission.user_id = p_evaluator_user_id
        AND permission.permission = 'human_evaluator'
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'evaluator_unauthorized');
  END IF;

  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    JOIN public.ideas AS idea ON idea.id = cycle.idea_id
    WHERE cycle.idea_id = p_idea_id
      AND idea.status = 'submitted'
    FOR UPDATE OF cycle;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_cycle.status <> 'awaiting_review' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF v_cycle.assigned_evaluator_id = p_evaluator_user_id THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_assigned',
      'status', v_cycle.status
    );
  END IF;

  v_now := pg_catalog.clock_timestamp();
  UPDATE public.idea_evaluation_cycles AS cycle
    SET assigned_evaluator_id = p_evaluator_user_id,
        assigned_at = v_now
    WHERE cycle.cycle_id = v_cycle.cycle_id;
  INSERT INTO public.idea_evaluation_events (
    cycle_id, event_type, actor_type, actor_user_id, evaluator_user_id
  )
  VALUES (
    v_cycle.cycle_id, 'evaluator_assigned', 'assignment_manager',
    v_actor_id, p_evaluator_user_id
  );
  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'assigned',
    'status', v_cycle.status
  );
END
$function$;
ALTER FUNCTION public.assign_idea_evaluator(uuid, uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.assign_idea_evaluator(uuid, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.assign_idea_evaluator(uuid, uuid)
  TO authenticated;

CREATE FUNCTION public.start_idea_evaluation(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
  v_now timestamptz;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:authorization:v1:' || v_actor_id::text, 0
    )
  );
  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND OR v_idea.status <> 'submitted' OR v_idea.submitted_at IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;
  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.idea_id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;
  IF v_cycle.assigned_evaluator_id IS DISTINCT FROM v_actor_id
     OR NOT EXISTS (
       SELECT 1
         FROM public.idea_evaluation_permissions AS permission
         WHERE permission.user_id = v_actor_id
           AND permission.permission = 'human_evaluator'
     ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;
  v_now := pg_catalog.clock_timestamp();
  IF v_now < v_idea.submitted_at + INTERVAL '168 hours' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'editing_window_active');
  END IF;
  IF v_cycle.status = 'in_progress' THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_started',
      'status', v_cycle.status,
      'evaluated_revision', v_cycle.evaluated_revision
    );
  END IF;
  IF v_cycle.status <> 'awaiting_review' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  UPDATE public.idea_evaluation_cycles AS cycle
    SET status = 'in_progress',
        evaluated_revision = v_idea.revision,
        started_at = v_now
    WHERE cycle.cycle_id = v_cycle.cycle_id;
  INSERT INTO public.idea_evaluation_events (
    cycle_id, event_type, actor_type, actor_user_id, idea_revision, occurred_at
  )
  VALUES (
    v_cycle.cycle_id, 'evaluation_started', 'human_evaluator', v_actor_id,
    v_idea.revision, v_now
  );
  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'started',
    'status', 'in_progress',
    'evaluated_revision', v_idea.revision
  );
END
$function$;
ALTER FUNCTION public.start_idea_evaluation(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.start_idea_evaluation(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.start_idea_evaluation(uuid)
  TO authenticated;

CREATE FUNCTION public.complete_idea_evaluation(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
  v_now timestamptz;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:authorization:v1:' || v_actor_id::text, 0
    )
  );
  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND OR v_idea.status <> 'submitted' OR v_idea.submitted_at IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;
  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.idea_id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;
  IF v_cycle.assigned_evaluator_id IS DISTINCT FROM v_actor_id
     OR NOT EXISTS (
       SELECT 1
         FROM public.idea_evaluation_permissions AS permission
         WHERE permission.user_id = v_actor_id
           AND permission.permission = 'human_evaluator'
     ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found_or_not_assigned'
    );
  END IF;
  IF pg_catalog.clock_timestamp()
       < v_idea.submitted_at + INTERVAL '168 hours' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'editing_window_active');
  END IF;
  IF v_cycle.status = 'completed' THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_completed',
      'status', v_cycle.status
    );
  END IF;
  IF v_cycle.status <> 'in_progress'
     OR v_cycle.evaluated_revision IS DISTINCT FROM v_idea.revision THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  v_now := pg_catalog.clock_timestamp();
  UPDATE public.idea_evaluation_cycles AS cycle
    SET status = 'completed',
        completed_at = v_now
    WHERE cycle.cycle_id = v_cycle.cycle_id;
  INSERT INTO public.idea_evaluation_events (
    cycle_id, event_type, actor_type, actor_user_id, occurred_at
  )
  VALUES (
    v_cycle.cycle_id, 'evaluation_completed', 'human_evaluator',
    v_actor_id, v_now
  );
  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'completed',
    'status', 'completed'
  );
END
$function$;
ALTER FUNCTION public.complete_idea_evaluation(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.complete_idea_evaluation(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.complete_idea_evaluation(uuid)
  TO authenticated;

CREATE FUNCTION public.get_own_idea_evaluation_status(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_cycle public.idea_evaluation_cycles%ROWTYPE;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_idea.status <> 'submitted' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_submitted');
  END IF;

  SELECT cycle.* INTO v_cycle
    FROM public.idea_evaluation_cycles AS cycle
    WHERE cycle.idea_id = p_idea_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Submitted idea evaluation status is unavailable'
      USING ERRCODE = '55000';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'available',
    'status', v_cycle.status,
    'started_at', v_cycle.started_at,
    'completed_at', v_cycle.completed_at
  );
END
$function$;
ALTER FUNCTION public.get_own_idea_evaluation_status(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_own_idea_evaluation_status(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_own_idea_evaluation_status(uuid)
  TO authenticated;

COMMENT ON TABLE public.idea_evaluation_permissions IS
  'Narrow Stage 7 permissions provisioned by a privileged operator; separate from scoring roles.';
COMMENT ON TABLE public.idea_evaluation_cycles IS
  'One initial Stage 7 human evaluation lifecycle per submitted idea; not a scoring or selection record.';
COMMENT ON TABLE public.idea_evaluation_events IS
  'Append-only internal audit events for Stage 7 evaluation lifecycle operations.';
COMMENT ON FUNCTION public.get_own_idea_evaluation_status(uuid) IS
  'Owner-scoped status projection; excludes evaluator identity and internal audit data.';

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
