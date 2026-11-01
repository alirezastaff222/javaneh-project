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

ALTER TABLE public.scoring_milestone_catalog
  DROP CONSTRAINT scoring_milestone_catalog_validation_mode_check,
  ADD CONSTRAINT scoring_milestone_catalog_validation_mode_check
    CHECK (validation_mode IS NULL
      OR validation_mode IN ('qualitative', 'objective', 'hybrid'));

CREATE TABLE public.milestone_validation_requests (
  request_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL,
  participant_id uuid NOT NULL,
  configuration_version_id uuid NOT NULL,
  milestone_key text NOT NULL,
  catalog_version text NOT NULL,
  stage_number smallint NOT NULL CHECK (stage_number BETWEEN 1 AND 6),
  idea_revision integer NOT NULL CHECK (idea_revision > 0),
  validation_mode text NOT NULL
    CHECK (validation_mode IN ('qualitative', 'objective', 'hybrid')),
  status text NOT NULL DEFAULT 'pending_validation'
    CHECK (status IN (
      'pending_validation', 'validated', 'needs_revision', 'rejected'
    )),
  objective_passed boolean,
  objective_result jsonb CHECK (
    objective_result IS NULL OR pg_catalog.jsonb_typeof(objective_result) = 'object'
  ),
  submitted_by uuid NOT NULL,
  submitted_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT milestone_validation_requests_catalog_fk
    FOREIGN KEY (configuration_version_id, milestone_key)
    REFERENCES public.scoring_milestone_catalog(
      configuration_version_id, milestone_key
    ) ON DELETE RESTRICT,
  CONSTRAINT milestone_validation_requests_revision_key
    UNIQUE (idea_id, configuration_version_id, milestone_key, idea_revision),
  CONSTRAINT milestone_validation_requests_objective_shape
    CHECK (
      (validation_mode = 'qualitative'
        AND objective_passed IS NULL AND objective_result IS NULL)
      OR (validation_mode IN ('objective', 'hybrid')
        AND objective_passed IS NOT NULL AND objective_result IS NOT NULL)
    ),
  CONSTRAINT milestone_validation_requests_updated_at
    CHECK (updated_at >= submitted_at)
);

CREATE INDEX milestone_validation_requests_queue_idx
  ON public.milestone_validation_requests (
    status, configuration_version_id, submitted_at, request_id
  );
CREATE INDEX milestone_validation_requests_participant_idx
  ON public.milestone_validation_requests (
    participant_id, submitted_at DESC, request_id
  );

CREATE TABLE public.milestone_validation_events (
  event_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  request_id uuid NOT NULL
    REFERENCES public.milestone_validation_requests(request_id) ON DELETE RESTRICT,
  state_from text CHECK (state_from IS NULL OR state_from IN (
    'pending_validation', 'validated', 'needs_revision', 'rejected'
  )),
  state_to text NOT NULL CHECK (state_to IN (
    'pending_validation', 'validated', 'needs_revision', 'rejected'
  )),
  event_type text NOT NULL CHECK (event_type IN (
    'submitted', 'objective_evaluated', 'human_validated',
    'revision_requested', 'rejected'
  )),
  actor_type text NOT NULL CHECK (actor_type IN ('participant', 'validator', 'system')),
  actor_user_id uuid,
  reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(reason)) > 0),
  details jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (pg_catalog.jsonb_typeof(details) = 'object'),
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT milestone_validation_events_actor_shape CHECK (
    (actor_type = 'system' AND actor_user_id IS NULL)
    OR (actor_type IN ('participant', 'validator') AND actor_user_id IS NOT NULL)
  )
);

CREATE INDEX milestone_validation_events_request_idx
  ON public.milestone_validation_events (request_id, occurred_at, event_id);

ALTER TABLE public.milestone_validations
  DROP CONSTRAINT milestone_validations_once_per_idea,
  ADD COLUMN validation_request_id uuid
    REFERENCES public.milestone_validation_requests(request_id) ON DELETE RESTRICT,
  ADD COLUMN outcome text CHECK (
    outcome IS NULL OR outcome IN ('validated', 'needs_revision', 'rejected')
  );
CREATE UNIQUE INDEX milestone_validations_one_human_decision_per_request
  ON public.milestone_validations (validation_request_id)
  WHERE validation_request_id IS NOT NULL;
CREATE INDEX milestone_validations_request_history_idx
  ON public.milestone_validations (validation_request_id, validated_at DESC)
  WHERE validation_request_id IS NOT NULL;

ALTER TABLE public.milestone_validation_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.milestone_validation_requests FORCE ROW LEVEL SECURITY;
ALTER TABLE public.milestone_validation_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.milestone_validation_events FORCE ROW LEVEL SECURITY;

CREATE POLICY milestone_validation_requests_executor_all
  ON public.milestone_validation_requests FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY milestone_validation_requests_owner_read
  ON public.milestone_validation_requests FOR SELECT TO authenticated
  USING (participant_id = javaneh_private.current_uid());
CREATE POLICY milestone_validation_events_executor_all
  ON public.milestone_validation_events FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY milestone_validation_events_owner_read
  ON public.milestone_validation_events FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
      FROM public.milestone_validation_requests AS request
      WHERE request.request_id = milestone_validation_events.request_id
        AND request.participant_id = javaneh_private.current_uid()
  ));

REVOKE ALL ON TABLE
  public.milestone_validation_requests,
  public.milestone_validation_events
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE
  public.milestone_validation_requests,
  public.milestone_validation_events
  TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE
  public.milestone_validation_requests
  TO javaneh_identity_executor;
GRANT SELECT, INSERT ON TABLE
  public.milestone_validation_events
  TO javaneh_identity_executor;
GRANT SELECT, INSERT ON TABLE public.milestone_validations
  TO javaneh_identity_executor;
GRANT SELECT ON TABLE public.ideas, public.idea_stages
  TO javaneh_identity_executor;

CREATE OR REPLACE FUNCTION public.guard_milestone_validation_level()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_mode text;
BEGIN
  SELECT milestone.validation_mode INTO v_mode
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = NEW.configuration_version_id
      AND milestone.milestone_key = NEW.milestone_key;
  IF v_mode IN ('qualitative', 'hybrid') THEN
    IF NEW.validation_request_id IS NOT NULL THEN
      IF NEW.evaluation_level IS NULL
         OR NEW.evaluation_level NOT BETWEEN 0 AND 4
         OR NEW.outcome IS NULL
         OR ((NEW.outcome = 'validated')
           IS DISTINCT FROM (NEW.decision = 'approved'))
         OR (NEW.outcome = 'validated' AND NEW.evaluation_level = 0) THEN
        RAISE EXCEPTION 'Human decision and validation outcome do not match'
          USING ERRCODE = '23514';
      END IF;
    ELSIF NEW.evaluation_level IS NULL
       OR (NEW.evaluation_level = 0 AND NEW.decision <> 'rejected')
       OR (NEW.evaluation_level > 0 AND NEW.decision <> 'approved') THEN
      RAISE EXCEPTION 'Qualitative milestone decisions require a matching evaluation level'
        USING ERRCODE = '23514';
    END IF;
  ELSIF NEW.evaluation_level IS NOT NULL THEN
    RAISE EXCEPTION 'Evaluation levels are only valid for qualitative milestones'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_milestone_validation_level()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.guard_milestone_validation_request()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF current_user <> 'javaneh_identity_executor' THEN
    RAISE EXCEPTION 'Validation requests are server-authoritative'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Validation request history is immutable'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.request_id IS DISTINCT FROM OLD.request_id
       OR NEW.idea_id IS DISTINCT FROM OLD.idea_id
       OR NEW.participant_id IS DISTINCT FROM OLD.participant_id
       OR NEW.configuration_version_id IS DISTINCT FROM OLD.configuration_version_id
       OR NEW.milestone_key IS DISTINCT FROM OLD.milestone_key
       OR NEW.catalog_version IS DISTINCT FROM OLD.catalog_version
       OR NEW.stage_number IS DISTINCT FROM OLD.stage_number
       OR NEW.idea_revision IS DISTINCT FROM OLD.idea_revision
       OR NEW.validation_mode IS DISTINCT FROM OLD.validation_mode
       OR NEW.objective_passed IS DISTINCT FROM OLD.objective_passed
       OR NEW.objective_result IS DISTINCT FROM OLD.objective_result
       OR NEW.submitted_by IS DISTINCT FROM OLD.submitted_by
       OR NEW.submitted_at IS DISTINCT FROM OLD.submitted_at
       OR NEW.updated_at < OLD.updated_at
       OR OLD.status <> 'pending_validation'
       OR NEW.status NOT IN ('validated', 'needs_revision', 'rejected') THEN
      RAISE EXCEPTION 'Invalid or immutable validation request transition'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.status <> 'pending_validation' THEN
    RAISE EXCEPTION 'Validation requests must begin pending'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_milestone_validation_request()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER milestone_validation_requests_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.milestone_validation_requests
  FOR EACH ROW EXECUTE FUNCTION public.guard_milestone_validation_request();

CREATE FUNCTION public.guard_milestone_validation_event()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF current_user <> 'javaneh_identity_executor' OR TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'Validation event history is append-only and server-authoritative'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_milestone_validation_event()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER milestone_validation_events_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.milestone_validation_events
  FOR EACH ROW EXECUTE FUNCTION public.guard_milestone_validation_event();

CREATE FUNCTION public.guard_milestone_validation_decision()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_mode text;
BEGIN
  IF TG_OP <> 'INSERT' OR current_user <> 'javaneh_identity_executor' THEN
    RAISE EXCEPTION 'Validation decisions are immutable and server-authoritative'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.validation_request_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT request.validation_mode INTO v_mode
    FROM public.milestone_validation_requests AS request
    WHERE request.request_id = NEW.validation_request_id
      AND request.idea_id = NEW.idea_id
      AND request.participant_id = NEW.participant_id
      AND request.configuration_version_id = NEW.configuration_version_id
      AND request.milestone_key = NEW.milestone_key
      AND request.idea_revision = NEW.reviewed_revision;
  IF NOT FOUND OR v_mode NOT IN ('qualitative', 'hybrid') THEN
    RAISE EXCEPTION 'Human decision does not match an eligible validation request'
      USING ERRCODE = '23514';
  END IF;
  IF NEW.validation_request_id IS NOT NULL THEN
    IF NEW.outcome IS NULL
       OR ((NEW.outcome = 'validated')
         IS DISTINCT FROM (NEW.decision = 'approved'))
       OR NEW.evaluation_level IS NULL
       OR NEW.evaluation_level NOT BETWEEN 0 AND 4
       OR (NEW.outcome = 'validated' AND NEW.evaluation_level = 0) THEN
      RAISE EXCEPTION 'Human decision and validation outcome do not match'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.outcome IS NULL
     OR (NEW.evaluation_level IS NULL
       OR NEW.evaluation_level NOT BETWEEN 0 AND 4)
     OR (NEW.evaluation_level = 0 AND NEW.decision <> 'rejected')
     OR (NEW.evaluation_level > 0 AND NEW.decision <> 'approved') THEN
    RAISE EXCEPTION 'Legacy qualitative decision requires a valid evaluation level'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_milestone_validation_decision()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER milestone_validations_request_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.milestone_validations
  FOR EACH ROW EXECUTE FUNCTION public.guard_milestone_validation_decision();

CREATE FUNCTION public.guard_milestone_validation_request_transition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_current_status text;
BEGIN
  SELECT request.status INTO v_current_status
    FROM public.milestone_validation_requests AS request
    WHERE request.request_id = NEW.request_id;
  IF NOT FOUND OR NEW.state_from IS DISTINCT FROM v_current_status
     OR NOT (
       (NEW.state_from = 'pending_validation'
         AND NEW.state_to = 'pending_validation'
         AND NEW.event_type = 'objective_evaluated')
       OR (NEW.state_from = 'pending_validation'
         AND NEW.state_to IN ('validated', 'needs_revision', 'rejected')
         AND NEW.event_type IN (
           'objective_evaluated', 'human_validated',
           'revision_requested', 'rejected'
         ))
     ) THEN
    RAISE EXCEPTION 'Invalid validation lifecycle transition'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_milestone_validation_request_transition()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER milestone_validation_events_transition_guard
  BEFORE INSERT ON public.milestone_validation_events
  FOR EACH ROW
  WHEN (NEW.state_from IS NOT NULL)
  EXECUTE FUNCTION public.guard_milestone_validation_request_transition();

CREATE FUNCTION public.milestone_validation_is_operational(
  p_configuration_version_id uuid,
  p_milestone_key text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM public.scoring_configuration_versions AS version
      JOIN public.scoring_milestone_catalog AS milestone
        ON milestone.configuration_version_id = version.id
      JOIN public.competitions AS competition
        ON competition.scoring_configuration_version_id = version.id
      WHERE version.id = p_configuration_version_id
        AND version.status = 'active'
        AND version.approved_by IS NOT NULL
        AND version.approved_at IS NOT NULL
        AND version.activated_at IS NOT NULL
        AND competition.status = 'active'
        AND milestone.milestone_key = p_milestone_key
        AND milestone.stage_number BETWEEN 1 AND 6
        AND milestone.is_active
        AND milestone.catalog_status = 'active'
        AND milestone.descriptor_status = 'approved'
        AND milestone.validation_mode IN ('qualitative', 'objective', 'hybrid')
        AND milestone.validation_policy IS NOT NULL
        AND milestone.evidence_guidance IS NOT NULL
        AND pg_catalog.length(pg_catalog.btrim(milestone.evidence_guidance)) > 0
        AND milestone.evaluator_instructions IS NOT NULL
        AND pg_catalog.length(pg_catalog.btrim(milestone.evaluator_instructions)) > 0
        AND (
          milestone.validation_mode = 'objective'
          OR (
            milestone.level_0_description IS NOT NULL
            AND milestone.level_1_description IS NOT NULL
            AND milestone.level_2_description IS NOT NULL
            AND milestone.level_3_description IS NOT NULL
            AND milestone.level_4_description IS NOT NULL
            AND (SELECT pg_catalog.count(*)
                   FROM public.scoring_evaluation_levels AS level
                   WHERE level.configuration_version_id = version.id) = 5
          )
        )
        AND (
          milestone.validation_mode = 'qualitative'
          OR pg_catalog.jsonb_typeof(
            milestone.validation_policy->'objective_checks'
          ) = 'array'
        )
  )
$function$;
ALTER FUNCTION public.milestone_validation_is_operational(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.milestone_validation_is_operational(uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.evaluate_milestone_objective_policy(
  p_idea_id uuid,
  p_configuration_version_id uuid,
  p_milestone_key text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_milestone public.scoring_milestone_catalog%ROWTYPE;
  v_check jsonb;
  v_index bigint;
  v_stage_number smallint;
  v_path text[];
  v_actual jsonb;
  v_passed boolean;
  v_all_passed boolean := true;
  v_results jsonb := '[]'::jsonb;
BEGIN
  SELECT milestone.* INTO v_milestone
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = p_configuration_version_id
      AND milestone.milestone_key = p_milestone_key;
  IF NOT FOUND OR v_milestone.validation_mode NOT IN ('objective', 'hybrid')
     OR pg_catalog.jsonb_typeof(
       v_milestone.validation_policy->'objective_checks'
     ) IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(
       v_milestone.validation_policy->'objective_checks'
     ) = 0 THEN
    RETURN '{"configured":false,"passed":false,"checks":[]}'::jsonb;
  END IF;

  FOR v_check, v_index IN
    SELECT item.value, item.ordinality
      FROM pg_catalog.jsonb_array_elements(
        v_milestone.validation_policy->'objective_checks'
      ) WITH ORDINALITY AS item(value, ordinality)
  LOOP
    IF pg_catalog.jsonb_typeof(v_check) IS DISTINCT FROM 'object'
       OR pg_catalog.jsonb_typeof(v_check->'stage_number') IS DISTINCT FROM 'number'
       OR (v_check->>'stage_number') !~ '^[1-6]$'
       OR pg_catalog.jsonb_typeof(v_check->'path') IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_array_length(v_check->'path') = 0
       OR pg_catalog.jsonb_typeof(v_check->'operator') IS DISTINCT FROM 'string'
       OR v_check->>'operator' NOT IN ('present', 'equals')
       OR (v_check->>'operator' = 'equals' AND NOT (v_check ? 'value'))
       OR EXISTS (
         SELECT 1
           FROM pg_catalog.jsonb_array_elements(v_check->'path') AS path_item(value)
           WHERE pg_catalog.jsonb_typeof(path_item.value) <> 'string'
       ) THEN
      RETURN '{"configured":false,"passed":false,"checks":[]}'::jsonb;
    END IF;

    v_stage_number := (v_check->>'stage_number')::smallint;
    SELECT pg_catalog.array_agg(path_item.value #>> '{}')
      INTO v_path
      FROM pg_catalog.jsonb_array_elements(v_check->'path') AS path_item(value);
    SELECT pg_catalog.jsonb_extract_path(stage.data, VARIADIC v_path)
      INTO v_actual
      FROM public.idea_stages AS stage
      WHERE stage.idea_id = p_idea_id
        AND stage.stage_number = v_stage_number;

    IF v_check->>'operator' = 'equals' THEN
      v_passed := v_actual IS NOT DISTINCT FROM v_check->'value';
    ELSE
      v_passed := v_actual IS NOT NULL AND v_actual <> 'null'::jsonb
        AND CASE pg_catalog.jsonb_typeof(v_actual)
          WHEN 'string' THEN pg_catalog.length(pg_catalog.btrim(v_actual #>> '{}')) > 0
          WHEN 'array' THEN pg_catalog.jsonb_array_length(v_actual) > 0
          WHEN 'object' THEN EXISTS (
            SELECT 1 FROM pg_catalog.jsonb_each(v_actual)
          )
          ELSE true
        END;
    END IF;

    v_all_passed := v_all_passed AND v_passed;
    v_results := v_results || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'check', v_index,
        'stage_number', v_stage_number,
        'passed', v_passed
      )
    );
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'configured', true,
    'passed', v_all_passed,
    'checks', v_results
  );
END
$function$;
ALTER FUNCTION public.evaluate_milestone_objective_policy(uuid, uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.evaluate_milestone_objective_policy(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.submit_milestone_for_validation(
  p_idea_id uuid,
  p_configuration_version_id uuid,
  p_milestone_key text,
  p_expected_revision integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_milestone public.scoring_milestone_catalog%ROWTYPE;
  v_stage public.idea_stages%ROWTYPE;
  v_request public.milestone_validation_requests%ROWTYPE;
  v_request_id uuid;
  v_objective jsonb;
  v_status text := 'pending_validation';
  v_event_type text;
  v_event_reason text;
  v_attempt_count integer;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_configuration_version_id IS NULL
     OR p_milestone_key IS NULL OR p_expected_revision IS NULL
     OR p_expected_revision < 1 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:authorization:v1:' || v_actor_id::text, 0
    )
  );
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:milestone-submission:v1:' || p_idea_id::text || ':'
        || p_configuration_version_id::text || ':' || p_milestone_key || ':'
        || p_expected_revision::text,
      0
    )
  );

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_actor_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  IF v_idea.revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_revision', 'current_revision', v_idea.revision
    );
  END IF;

  SELECT milestone.* INTO v_milestone
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = p_configuration_version_id
      AND milestone.milestone_key = p_milestone_key;
  IF NOT FOUND OR NOT public.milestone_validation_is_operational(
    p_configuration_version_id, p_milestone_key
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
  END IF;

  SELECT request.* INTO v_request
    FROM public.milestone_validation_requests AS request
    WHERE request.idea_id = p_idea_id
      AND request.configuration_version_id = p_configuration_version_id
      AND request.milestone_key = p_milestone_key
      AND request.idea_revision = p_expected_revision;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'replayed',
      'request_id', v_request.request_id,
      'status', v_request.status
    );
  END IF;

  SELECT stage.* INTO v_stage
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = v_milestone.stage_number
    FOR SHARE;
  IF NOT FOUND OR v_stage.status = 'locked'
     OR v_stage.status = 'not_started'
     OR v_stage.data = '{}'::jsonb THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'submission_missing');
  END IF;

  IF v_milestone.validation_mode IN ('objective', 'hybrid') THEN
    v_objective := public.evaluate_milestone_objective_policy(
      p_idea_id, p_configuration_version_id, p_milestone_key
    );
    IF v_objective->>'configured' <> 'true' THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'configuration_incomplete');
    END IF;
    IF v_milestone.validation_mode = 'objective' THEN
      v_status := CASE WHEN (v_objective->>'passed')::boolean
        THEN 'validated' ELSE 'needs_revision' END;
    ELSIF NOT (v_objective->>'passed')::boolean THEN
      v_status := 'needs_revision';
    END IF;
  END IF;

  INSERT INTO public.milestone_validation_requests (
    idea_id, participant_id, configuration_version_id, milestone_key,
    catalog_version, stage_number, idea_revision, validation_mode, status,
    objective_passed, objective_result, submitted_by
  )
  VALUES (
    p_idea_id, v_actor_id, p_configuration_version_id, p_milestone_key,
    v_milestone.catalog_version, v_milestone.stage_number,
    p_expected_revision, v_milestone.validation_mode, 'pending_validation',
    CASE WHEN v_objective IS NULL THEN NULL
      ELSE (v_objective->>'passed')::boolean END,
    v_objective, v_actor_id
  )
  RETURNING request_id INTO v_request_id;

  INSERT INTO public.milestone_validation_events (
    request_id, state_from, state_to, event_type, actor_type,
    actor_user_id, reason
  )
  VALUES (
    v_request_id, NULL, 'pending_validation', 'submitted',
    'participant', v_actor_id, 'Participant submitted the current idea revision.'
  );

  IF v_objective IS NOT NULL THEN
    v_event_type := 'objective_evaluated';
    v_event_reason := CASE
      WHEN (v_objective->>'passed')::boolean
        THEN 'Configured objective checks were evaluated by the server.'
      ELSE 'One or more configured objective checks require revision.'
    END;
    INSERT INTO public.milestone_validation_events (
      request_id, state_from, state_to, event_type, actor_type,
      actor_user_id, reason, details
    )
    VALUES (
      v_request_id, 'pending_validation', v_status, v_event_type,
      'system', NULL, v_event_reason, v_objective
    );
    IF v_status <> 'pending_validation' THEN
      UPDATE public.milestone_validation_requests AS request
        SET status = v_status, updated_at = pg_catalog.clock_timestamp()
        WHERE request.request_id = v_request_id;
    END IF;
  END IF;

  SELECT pg_catalog.count(*) INTO v_attempt_count
    FROM public.milestone_validation_requests AS request
    WHERE request.idea_id = p_idea_id
      AND request.configuration_version_id = p_configuration_version_id
      AND request.milestone_key = p_milestone_key;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', CASE WHEN v_status = 'pending_validation'
      THEN 'pending_validation' ELSE v_status END,
    'request_id', v_request_id,
    'status', v_status,
    'attempt', v_attempt_count,
    'objective_result', v_objective
  );
END
$function$;
ALTER FUNCTION public.submit_milestone_for_validation(uuid, uuid, text, integer)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.submit_milestone_for_validation(uuid, uuid, text, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.submit_milestone_for_validation(uuid, uuid, text, integer)
  TO authenticated;

CREATE FUNCTION public.get_milestone_validation_queue()
RETURNS TABLE (
  request_id uuid,
  idea_id uuid,
  participant_id uuid,
  configuration_version_id uuid,
  milestone_key text,
  catalog_version text,
  stage_number smallint,
  idea_revision integer,
  validation_mode text,
  status text,
  objective_passed boolean,
  evidence jsonb,
  submitted_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:authorization:v1:' || v_actor_id::text, 0
    )
  );
  IF NOT EXISTS (
    SELECT 1
      FROM public.scoring_role_assignments AS role_assignment
      WHERE role_assignment.user_id = v_actor_id
        AND role_assignment.role_name = 'validator'
  ) THEN
    RAISE EXCEPTION 'Validator authorization required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT request.request_id, request.idea_id, request.participant_id,
    request.configuration_version_id, request.milestone_key,
    request.catalog_version, request.stage_number, request.idea_revision,
    request.validation_mode, request.status, request.objective_passed,
    stage.data, request.submitted_at
  FROM public.milestone_validation_requests AS request
  JOIN public.ideas AS idea ON idea.id = request.idea_id
  JOIN public.idea_stages AS stage
    ON stage.idea_id = request.idea_id
   AND stage.stage_number = request.stage_number
  WHERE request.status = 'pending_validation'
    AND request.validation_mode IN ('qualitative', 'hybrid')
    AND idea.revision = request.idea_revision
    AND idea.owner_id <> v_actor_id
    AND public.milestone_validation_is_operational(
      request.configuration_version_id, request.milestone_key
    )
  ORDER BY request.submitted_at, request.request_id;
END
$function$;
ALTER FUNCTION public.get_milestone_validation_queue()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_milestone_validation_queue()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_milestone_validation_queue()
  TO authenticated;

CREATE FUNCTION public.validate_milestone_request(
  p_request_id uuid,
  p_outcome text,
  p_evaluation_level smallint,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_request public.milestone_validation_requests%ROWTYPE;
  v_owner_id uuid;
  v_revision integer;
  v_validation_id uuid;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_request_id IS NULL
     OR p_outcome NOT IN ('validated', 'needs_revision', 'rejected')
     OR p_evaluation_level IS NULL
     OR p_evaluation_level NOT BETWEEN 0 AND 4
     OR (p_outcome = 'validated' AND p_evaluation_level = 0)
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
      FROM public.scoring_role_assignments AS role_assignment
      WHERE role_assignment.user_id = v_actor_id
        AND role_assignment.role_name = 'validator'
  ) THEN
    RAISE EXCEPTION 'Validator authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT request.* INTO v_request
    FROM public.milestone_validation_requests AS request
    WHERE request.request_id = p_request_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:milestone-submission:v1:' || v_request.idea_id::text || ':'
        || v_request.configuration_version_id::text || ':'
        || v_request.milestone_key || ':' || v_request.idea_revision::text,
      0
    )
  );

  SELECT idea.owner_id, idea.revision INTO v_owner_id, v_revision
    FROM public.ideas AS idea
    WHERE idea.id = v_request.idea_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_owner_id = v_actor_id THEN
    RAISE EXCEPTION 'A Validator cannot validate their own idea'
      USING ERRCODE = '42501';
  END IF;
  IF v_revision <> v_request.idea_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_evidence', 'current_revision', v_revision
    );
  END IF;
  SELECT request.* INTO v_request
    FROM public.milestone_validation_requests AS request
    WHERE request.request_id = p_request_id
    FOR UPDATE;
  IF v_request.status <> 'pending_validation'
     OR v_request.validation_mode NOT IN ('qualitative', 'hybrid') THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF NOT public.milestone_validation_is_operational(
    v_request.configuration_version_id, v_request.milestone_key
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
  END IF;
  IF v_request.validation_mode = 'hybrid'
     AND v_request.objective_passed IS DISTINCT FROM true THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'objective_validation_required');
  END IF;

  INSERT INTO public.milestone_validations (
    idea_id, participant_id, configuration_version_id, milestone_key,
    reviewed_revision, decision, reason, validator_id, evaluation_level,
    validation_request_id, outcome
  )
  VALUES (
    v_request.idea_id, v_request.participant_id,
    v_request.configuration_version_id, v_request.milestone_key,
    v_request.idea_revision,
    CASE WHEN p_outcome = 'validated' THEN 'approved' ELSE 'rejected' END,
    p_reason, v_actor_id, p_evaluation_level, v_request.request_id, p_outcome
  )
  RETURNING validation_id INTO v_validation_id;

  INSERT INTO public.milestone_validation_events (
    request_id, state_from, state_to, event_type, actor_type,
    actor_user_id, reason, details
  )
  VALUES (
    p_request_id, 'pending_validation', p_outcome,
    CASE p_outcome
      WHEN 'validated' THEN 'human_validated'
      WHEN 'needs_revision' THEN 'revision_requested'
      ELSE 'rejected'
    END,
    'validator', v_actor_id, p_reason,
    pg_catalog.jsonb_build_object(
      'validation_id', v_validation_id,
      'evaluation_level', p_evaluation_level
    )
  );
  UPDATE public.milestone_validation_requests AS request
    SET status = p_outcome, updated_at = pg_catalog.clock_timestamp()
    WHERE request.request_id = p_request_id;
  RETURN pg_catalog.jsonb_build_object(
    'outcome', p_outcome,
    'request_id', p_request_id,
    'validation_id', v_validation_id
  );
END
$function$;
ALTER FUNCTION public.validate_milestone_request(uuid, text, smallint, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.validate_milestone_request(uuid, text, smallint, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.validate_milestone_request(uuid, text, smallint, text)
  TO authenticated;

CREATE FUNCTION public.get_milestone_scoring_eligibility(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_request public.milestone_validation_requests%ROWTYPE;
  v_owner_id uuid;
  v_human_validated boolean;
  v_eligible boolean := false;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  SELECT request.* INTO v_request
    FROM public.milestone_validation_requests AS request
    WHERE request.request_id = p_request_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'not_found', 'eligible', false
    );
  END IF;
  SELECT idea.owner_id INTO v_owner_id
    FROM public.ideas AS idea
    WHERE idea.id = v_request.idea_id;
  IF v_owner_id IS DISTINCT FROM v_actor_id
     AND NOT EXISTS (
       SELECT 1
         FROM public.scoring_role_assignments AS role_assignment
         WHERE role_assignment.user_id = v_actor_id
           AND role_assignment.role_name IN ('validator', 'scoring_administrator')
     ) THEN
    RAISE EXCEPTION 'Validation eligibility access denied'
      USING ERRCODE = '42501';
  END IF;
  SELECT EXISTS (
    SELECT 1
      FROM public.milestone_validations AS validation
      WHERE validation.validation_request_id = v_request.request_id
        AND validation.decision = 'approved'
        AND validation.outcome = 'validated'
  ) INTO v_human_validated;

  v_eligible :=
    v_request.status = 'validated'
    AND EXISTS (
      SELECT 1
        FROM public.ideas AS idea
        WHERE idea.id = v_request.idea_id
          AND idea.owner_id = v_request.participant_id
          AND idea.revision = v_request.idea_revision
    )
    AND public.milestone_validation_is_operational(
      v_request.configuration_version_id, v_request.milestone_key
    )
    AND (
      (v_request.validation_mode = 'objective'
        AND v_request.objective_passed IS TRUE)
      OR (v_request.validation_mode = 'qualitative' AND v_human_validated)
      OR (v_request.validation_mode = 'hybrid'
        AND v_request.objective_passed IS TRUE AND v_human_validated)
    );

  RETURN pg_catalog.jsonb_build_object(
    'outcome', CASE WHEN v_eligible THEN 'eligible' ELSE 'not_eligible' END,
    'eligible', v_eligible,
    'request_id', v_request.request_id,
    'idea_revision', v_request.idea_revision,
    'status', v_request.status
  );
END
$function$;
ALTER FUNCTION public.get_milestone_scoring_eligibility(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_milestone_scoring_eligibility(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_milestone_scoring_eligibility(uuid)
  TO authenticated;

CREATE FUNCTION public.block_award_for_validation_request()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF NEW.entry_kind = 'award'
     AND NEW.source = 'milestone_validation'
     AND EXISTS (
       SELECT 1
         FROM public.milestone_validations AS validation
         WHERE validation.validation_id = NEW.source_reference
           AND validation.validation_request_id IS NOT NULL
     ) THEN
    RAISE EXCEPTION 'M9R4 validation eligibility cannot issue official points'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.block_award_for_validation_request()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER official_points_ledger_m9r4_award_guard
  BEFORE INSERT ON public.official_points_ledger
  FOR EACH ROW EXECUTE FUNCTION public.block_award_for_validation_request();

COMMENT ON TABLE public.milestone_validation_requests IS
  'Append-only-per-revision participant submissions with a guarded current status; no content is copied from idea stages.';
COMMENT ON TABLE public.milestone_validation_events IS
  'Append-only validation transition history with participant, Validator, or trusted system attribution.';
COMMENT ON COLUMN public.milestone_validation_requests.idea_revision IS
  'Evidence reference to the existing idea revision and configured stage; draft content is not duplicated or retained here.';
COMMENT ON FUNCTION public.get_milestone_scoring_eligibility(uuid) IS
  'Reports whether a validated request meets policy gates; this operation never writes an official score ledger entry.';

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
