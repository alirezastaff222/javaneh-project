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

CREATE TABLE public.scoring_role_assignments (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role_name text NOT NULL CHECK (
    role_name IN ('platform_owner', 'scoring_administrator', 'validator')
  ),
  assigned_by uuid,
  assigned_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (user_id, role_name)
);

CREATE TABLE public.scoring_role_audit (
  event_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  event_type text NOT NULL CHECK (
    event_type IN ('granted', 'revoked', 'bootstrap_owner')
  ),
  role_name text NOT NULL CHECK (
    role_name IN ('platform_owner', 'scoring_administrator', 'validator')
  ),
  actor_user_id uuid,
  target_user_id uuid NOT NULL,
  reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(reason)) > 0),
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT scoring_role_audit_actor_shape CHECK (
    (event_type = 'bootstrap_owner'
      AND role_name = 'platform_owner' AND actor_user_id IS NULL)
    OR (event_type IN ('granted', 'revoked') AND actor_user_id IS NOT NULL)
  )
);

CREATE TABLE public.scoring_configuration_events (
  event_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  configuration_version_id uuid NOT NULL
    REFERENCES public.scoring_configuration_versions(id) ON DELETE RESTRICT,
  actor_user_id uuid NOT NULL,
  event_type text NOT NULL CHECK (
    event_type IN ('approved', 'activated', 'retired')
  ),
  reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(reason)) > 0),
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

CREATE TABLE public.milestone_validations (
  validation_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL,
  participant_id uuid NOT NULL,
  configuration_version_id uuid NOT NULL,
  milestone_key text NOT NULL,
  reviewed_revision integer NOT NULL CHECK (reviewed_revision > 0),
  decision text NOT NULL CHECK (decision IN ('approved', 'rejected')),
  reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(reason)) > 0),
  validator_id uuid NOT NULL,
  validated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT milestone_validations_catalog_fk
    FOREIGN KEY (configuration_version_id, milestone_key)
    REFERENCES public.scoring_milestone_catalog(
      configuration_version_id, milestone_key
    ) ON DELETE RESTRICT,
  CONSTRAINT milestone_validations_once_per_idea
    UNIQUE (idea_id, configuration_version_id, milestone_key)
);

CREATE INDEX milestone_validations_validator_history_idx
  ON public.milestone_validations (validator_id, validated_at DESC);

CREATE UNIQUE INDEX official_points_ledger_one_award_per_milestone
  ON public.official_points_ledger (
    idea_id, configuration_version_id, milestone_key
  )
  WHERE entry_kind = 'award';

CREATE UNIQUE INDEX official_points_ledger_one_compensation_per_award
  ON public.official_points_ledger (original_entry_id)
  WHERE entry_kind = 'compensation';

ALTER TABLE public.scoring_role_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_role_assignments FORCE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_role_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_role_audit FORCE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_configuration_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_configuration_events FORCE ROW LEVEL SECURITY;
ALTER TABLE public.milestone_validations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.milestone_validations FORCE ROW LEVEL SECURITY;

CREATE POLICY scoring_role_assignments_executor_all
  ON public.scoring_role_assignments FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY scoring_role_audit_executor_all
  ON public.scoring_role_audit FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY scoring_configuration_events_executor_all
  ON public.scoring_configuration_events FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY milestone_validations_executor_all
  ON public.milestone_validations FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE
  public.scoring_role_assignments,
  public.scoring_role_audit,
  public.scoring_configuration_events,
  public.milestone_validations
  FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, INSERT, DELETE ON TABLE public.scoring_role_assignments
  TO javaneh_identity_executor;
GRANT SELECT, INSERT ON TABLE
  public.scoring_role_audit,
  public.scoring_configuration_events,
  public.milestone_validations
  TO javaneh_identity_executor;

CREATE FUNCTION public.manage_scoring_role(
  p_target_user_id uuid,
  p_role_name text,
  p_action text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_required_role text;
  v_changed integer;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_target_user_id IS NULL
     OR p_role_name IS NULL
     OR p_action IS NULL
     OR p_action NOT IN ('grant', 'revoke')
     OR p_reason IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_reason)) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF p_role_name = 'platform_owner' THEN
    RAISE EXCEPTION 'Platform Owner assignment is only available through the privileged bootstrap process'
      USING ERRCODE = '42501';
  END IF;
  IF p_role_name NOT IN ('scoring_administrator', 'validator') THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF p_target_user_id = v_actor_id THEN
    RAISE EXCEPTION 'Users cannot assign or revoke privileged roles for themselves'
      USING ERRCODE = '42501';
  END IF;

  IF v_actor_id < p_target_user_id THEN
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'javaneh:authorization:v1:' || v_actor_id::text, 0
      )
    );
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'javaneh:authorization:v1:' || p_target_user_id::text, 0
      )
    );
  ELSE
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'javaneh:authorization:v1:' || p_target_user_id::text, 0
      )
    );
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'javaneh:authorization:v1:' || v_actor_id::text, 0
      )
    );
  END IF;

  v_required_role := CASE p_role_name
    WHEN 'scoring_administrator' THEN 'platform_owner'
    ELSE 'scoring_administrator'
  END;
  IF NOT EXISTS (
    SELECT 1
      FROM public.scoring_role_assignments AS r
      WHERE r.user_id = v_actor_id
        AND r.role_name = v_required_role
  ) THEN
    RAISE EXCEPTION 'The current user is not authorized to manage this role'
      USING ERRCODE = '42501';
  END IF;

  IF p_action = 'grant' THEN
    INSERT INTO public.scoring_role_assignments (
      user_id, role_name, assigned_by
    )
    VALUES (p_target_user_id, p_role_name, v_actor_id)
    ON CONFLICT (user_id, role_name) DO NOTHING;
    GET DIAGNOSTICS v_changed = ROW_COUNT;
    IF v_changed = 0 THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'already_assigned');
    END IF;
    INSERT INTO public.scoring_role_audit (
      event_type, role_name, actor_user_id, target_user_id, reason
    )
    VALUES ('granted', p_role_name, v_actor_id, p_target_user_id, p_reason);
    RETURN pg_catalog.jsonb_build_object('outcome', 'granted');
  END IF;

  DELETE FROM public.scoring_role_assignments AS r
    WHERE r.user_id = p_target_user_id
      AND r.role_name = p_role_name;
  GET DIAGNOSTICS v_changed = ROW_COUNT;
  IF v_changed = 0 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_assigned');
  END IF;
  INSERT INTO public.scoring_role_audit (
    event_type, role_name, actor_user_id, target_user_id, reason
  )
  VALUES ('revoked', p_role_name, v_actor_id, p_target_user_id, p_reason);
  RETURN pg_catalog.jsonb_build_object('outcome', 'revoked');
END
$function$;
ALTER FUNCTION public.manage_scoring_role(uuid, text, text, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.manage_scoring_role(uuid, text, text, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.manage_scoring_role(uuid, text, text, text)
  TO authenticated;

CREATE FUNCTION public.approve_scoring_configuration_version(
  p_version_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_status text;
  v_now timestamptz;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_version_id IS NULL OR p_reason IS NULL
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
      FROM public.scoring_role_assignments AS r
      WHERE r.user_id = v_actor_id
        AND r.role_name = 'scoring_administrator'
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator authorization required'
      USING ERRCODE = '42501';
  END IF;

  SELECT v.status INTO v_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = p_version_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_status <> 'draft' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  v_now := pg_catalog.clock_timestamp();
  UPDATE public.scoring_configuration_versions AS v
    SET status = 'approved', approved_by = v_actor_id, approved_at = v_now
    WHERE v.id = p_version_id;
  INSERT INTO public.scoring_configuration_events (
    configuration_version_id, actor_user_id, event_type, reason
  )
  VALUES (p_version_id, v_actor_id, 'approved', p_reason);
  RETURN pg_catalog.jsonb_build_object('outcome', 'approved');
END
$function$;
ALTER FUNCTION public.approve_scoring_configuration_version(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.approve_scoring_configuration_version(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.approve_scoring_configuration_version(uuid, text)
  TO authenticated;

CREATE FUNCTION public.activate_scoring_configuration_version(
  p_version_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_status text;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_version_id IS NULL OR p_reason IS NULL
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
      FROM public.scoring_role_assignments AS r
      WHERE r.user_id = v_actor_id
        AND r.role_name = 'scoring_administrator'
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator authorization required'
      USING ERRCODE = '42501';
  END IF;

  SELECT v.status INTO v_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = p_version_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_status <> 'approved' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  UPDATE public.scoring_configuration_versions AS v
    SET status = 'active', activated_at = pg_catalog.clock_timestamp()
    WHERE v.id = p_version_id;
  INSERT INTO public.scoring_configuration_events (
    configuration_version_id, actor_user_id, event_type, reason
  )
  VALUES (p_version_id, v_actor_id, 'activated', p_reason);
  RETURN pg_catalog.jsonb_build_object('outcome', 'activated');
END
$function$;
ALTER FUNCTION public.activate_scoring_configuration_version(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.activate_scoring_configuration_version(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.activate_scoring_configuration_version(uuid, text)
  TO authenticated;

CREATE FUNCTION public.retire_scoring_configuration_version(
  p_version_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_status text;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_version_id IS NULL OR p_reason IS NULL
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
      FROM public.scoring_role_assignments AS r
      WHERE r.user_id = v_actor_id
        AND r.role_name = 'scoring_administrator'
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator authorization required'
      USING ERRCODE = '42501';
  END IF;

  SELECT v.status INTO v_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = p_version_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_status <> 'active' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  UPDATE public.scoring_configuration_versions AS v
    SET status = 'retired'
    WHERE v.id = p_version_id;
  INSERT INTO public.scoring_configuration_events (
    configuration_version_id, actor_user_id, event_type, reason
  )
  VALUES (p_version_id, v_actor_id, 'retired', p_reason);
  RETURN pg_catalog.jsonb_build_object('outcome', 'retired');
END
$function$;
ALTER FUNCTION public.retire_scoring_configuration_version(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.retire_scoring_configuration_version(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.retire_scoring_configuration_version(uuid, text)
  TO authenticated;

CREATE FUNCTION public.get_milestone_review_queue()
RETURNS TABLE (
  idea_id uuid,
  idea_revision integer,
  idea_status text,
  configuration_version_id uuid,
  milestone_key text,
  stage_number smallint,
  milestone_definition text,
  evidence jsonb
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
      FROM public.scoring_role_assignments AS r
      WHERE r.user_id = v_actor_id
        AND r.role_name = 'validator'
  ) THEN
    RAISE EXCEPTION 'Validator authorization required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    i.id,
    i.revision,
    i.status,
    v.id,
    m.milestone_key,
    m.stage_number,
    m.definition,
    CASE
      WHEN m.stage_number IS NULL THEN COALESCE(all_stages.evidence, '[]'::jsonb)
      ELSE stage.data
    END
  FROM public.ideas AS i
  CROSS JOIN public.scoring_configuration_versions AS v
  JOIN public.scoring_milestone_catalog AS m
    ON m.configuration_version_id = v.id
  LEFT JOIN public.idea_stages AS stage
    ON stage.idea_id = i.id AND stage.stage_number = m.stage_number
  LEFT JOIN LATERAL (
    SELECT pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'stage_number', s.stage_number,
        'status', s.status,
        'data', s.data
      ) ORDER BY s.stage_number
    ) AS evidence
    FROM public.idea_stages AS s
    WHERE s.idea_id = i.id
  ) AS all_stages ON true
  WHERE v.status = 'active'
    AND m.is_active
    AND i.owner_id <> v_actor_id
    AND NOT EXISTS (
      SELECT 1
        FROM public.milestone_validations AS validation
        WHERE validation.idea_id = i.id
          AND validation.configuration_version_id = v.id
          AND validation.milestone_key = m.milestone_key
    )
  ORDER BY i.created_at, v.created_at, m.milestone_key, i.id;
END
$function$;
ALTER FUNCTION public.get_milestone_review_queue()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_milestone_review_queue()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_milestone_review_queue()
  TO authenticated;

CREATE FUNCTION public.validate_milestone(
  p_idea_id uuid,
  p_configuration_version_id uuid,
  p_milestone_key text,
  p_expected_revision integer,
  p_decision text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_owner_id uuid;
  v_revision integer;
  v_version_status text;
  v_validation_id uuid;
  v_existing_decision text;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL
     OR p_configuration_version_id IS NULL
     OR p_milestone_key IS NULL
     OR pg_catalog.length(p_milestone_key) > 128
     OR p_milestone_key !~ '^[a-z0-9][a-z0-9._-]{0,127}$'
     OR p_expected_revision IS NULL
     OR p_expected_revision < 1
     OR p_decision IS NULL
     OR p_decision NOT IN ('approved', 'rejected')
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
      FROM public.scoring_role_assignments AS r
      WHERE r.user_id = v_actor_id AND r.role_name = 'validator'
  ) THEN
    RAISE EXCEPTION 'Validator authorization required' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:milestone-review:v1:' || p_idea_id::text || ':'
        || p_configuration_version_id::text || ':' || p_milestone_key,
      0
    )
  );

  SELECT i.owner_id, i.revision INTO v_owner_id, v_revision
    FROM public.ideas AS i
    WHERE i.id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_owner_id = v_actor_id THEN
    RAISE EXCEPTION 'A Validator cannot validate their own idea'
      USING ERRCODE = '42501';
  END IF;
  IF v_revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_evidence',
      'current_revision', v_revision
    );
  END IF;

  SELECT v.status INTO v_version_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = p_configuration_version_id
    FOR SHARE;
  IF v_version_status IS DISTINCT FROM 'active'
     OR NOT EXISTS (
       SELECT 1
         FROM public.scoring_milestone_catalog AS m
         WHERE m.configuration_version_id = p_configuration_version_id
           AND m.milestone_key = p_milestone_key
           AND m.is_active
     ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
  END IF;

  SELECT validation.decision INTO v_existing_decision
    FROM public.milestone_validations AS validation
    WHERE validation.idea_id = p_idea_id
      AND validation.configuration_version_id = p_configuration_version_id
      AND validation.milestone_key = p_milestone_key;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_decided',
      'decision', v_existing_decision
    );
  END IF;

  INSERT INTO public.milestone_validations (
    idea_id,
    participant_id,
    configuration_version_id,
    milestone_key,
    reviewed_revision,
    decision,
    reason,
    validator_id
  )
  VALUES (
    p_idea_id,
    v_owner_id,
    p_configuration_version_id,
    p_milestone_key,
    v_revision,
    p_decision,
    p_reason,
    v_actor_id
  )
  RETURNING validation_id INTO v_validation_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', p_decision,
    'validation_id', v_validation_id,
    'reviewed_revision', v_revision
  );
END
$function$;
ALTER FUNCTION public.validate_milestone(uuid, uuid, text, integer, text, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.validate_milestone(uuid, uuid, text, integer, text, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.validate_milestone(uuid, uuid, text, integer, text, text)
  TO authenticated;

CREATE FUNCTION public.award_validated_milestone(p_validation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_validation public.milestone_validations%ROWTYPE;
  v_owner_id uuid;
  v_version_status text;
  v_milestone public.scoring_milestone_catalog%ROWTYPE;
  v_entry_id uuid;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_validation_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:authorization:v1:' || v_actor_id::text, 0
    )
  );
  IF NOT EXISTS (
    SELECT 1
      FROM public.scoring_role_assignments AS r
      WHERE r.user_id = v_actor_id AND r.role_name = 'validator'
  ) THEN
    RAISE EXCEPTION 'Validator authorization required' USING ERRCODE = '42501';
  END IF;

  SELECT validation.* INTO v_validation
    FROM public.milestone_validations AS validation
    WHERE validation.validation_id = p_validation_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:milestone-review:v1:' || v_validation.idea_id::text || ':'
        || v_validation.configuration_version_id::text || ':'
        || v_validation.milestone_key,
      0
    )
  );
  IF v_validation.validator_id <> v_actor_id THEN
    RAISE EXCEPTION 'Only the approving Validator may issue this milestone award'
      USING ERRCODE = '42501';
  END IF;
  IF v_validation.decision <> 'approved' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_approved');
  END IF;

  SELECT i.owner_id INTO v_owner_id
    FROM public.ideas AS i
    WHERE i.id = v_validation.idea_id
    FOR KEY SHARE;
  IF NOT FOUND OR v_owner_id <> v_validation.participant_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'ownership_changed');
  END IF;

  SELECT v.status INTO v_version_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = v_validation.configuration_version_id
    FOR SHARE;
  SELECT m.* INTO v_milestone
    FROM public.scoring_milestone_catalog AS m
    WHERE m.configuration_version_id = v_validation.configuration_version_id
      AND m.milestone_key = v_validation.milestone_key;
  IF v_version_status IS DISTINCT FROM 'active'
     OR NOT FOUND
     OR NOT v_milestone.is_active THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
  END IF;

  SELECT l.entry_id INTO v_entry_id
    FROM public.official_points_ledger AS l
    WHERE l.entry_kind = 'award'
      AND l.idea_id = v_validation.idea_id
      AND l.configuration_version_id = v_validation.configuration_version_id
      AND l.milestone_key = v_validation.milestone_key;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_awarded',
      'entry_id', v_entry_id
    );
  END IF;

  INSERT INTO public.official_points_ledger (
    idempotency_key,
    user_id,
    idea_id,
    configuration_version_id,
    milestone_key,
    stage_number,
    entry_kind,
    points,
    source,
    source_reference,
    reason,
    recorded_by
  )
  VALUES (
    pg_catalog.gen_random_uuid(),
    v_validation.participant_id,
    v_validation.idea_id,
    v_validation.configuration_version_id,
    v_validation.milestone_key,
    v_milestone.stage_number,
    'award',
    v_milestone.point_value,
    'milestone_validation',
    v_validation.validation_id,
    v_validation.reason,
    v_actor_id
  )
  RETURNING entry_id INTO v_entry_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'awarded',
    'entry_id', v_entry_id,
    'points', v_milestone.point_value
  );
END
$function$;
ALTER FUNCTION public.award_validated_milestone(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.award_validated_milestone(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.award_validated_milestone(uuid)
  TO authenticated;

CREATE FUNCTION public.correct_score_award(
  p_original_entry_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_original public.official_points_ledger%ROWTYPE;
  v_entry_id uuid;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_original_entry_id IS NULL OR p_reason IS NULL
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
      FROM public.scoring_role_assignments AS r
      WHERE r.user_id = v_actor_id
        AND r.role_name = 'scoring_administrator'
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator authorization required'
      USING ERRCODE = '42501';
  END IF;

  SELECT l.* INTO v_original
    FROM public.official_points_ledger AS l
    WHERE l.entry_id = p_original_entry_id
      AND l.entry_kind = 'award';
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_an_award');
  END IF;
  IF v_original.user_id = v_actor_id
     OR v_original.recorded_by = v_actor_id THEN
    RAISE EXCEPTION 'A Scoring Administrator cannot correct their own award or recorded award'
      USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:score-correction:v1:' || v_original.entry_id::text, 0
    )
  );

  SELECT l.entry_id INTO v_entry_id
    FROM public.official_points_ledger AS l
    WHERE l.entry_kind = 'compensation'
      AND l.original_entry_id = p_original_entry_id;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_corrected',
      'entry_id', v_entry_id
    );
  END IF;

  INSERT INTO public.official_points_ledger (
    idempotency_key,
    user_id,
    idea_id,
    configuration_version_id,
    milestone_key,
    stage_number,
    entry_kind,
    points,
    original_entry_id,
    source,
    source_reference,
    reason,
    recorded_by
  )
  VALUES (
    pg_catalog.gen_random_uuid(),
    v_original.user_id,
    v_original.idea_id,
    v_original.configuration_version_id,
    v_original.milestone_key,
    v_original.stage_number,
    'compensation',
    -v_original.points,
    v_original.entry_id,
    'administrative_correction',
    v_original.entry_id,
    p_reason,
    v_actor_id
  )
  RETURNING entry_id INTO v_entry_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'corrected',
    'entry_id', v_entry_id,
    'points', -v_original.points
  );
END
$function$;
ALTER FUNCTION public.correct_score_award(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.correct_score_award(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.correct_score_award(uuid, text)
  TO authenticated;

COMMENT ON TABLE public.scoring_role_assignments IS
  'Current scoring authority assignments. Platform Owner rows are created only by the privileged database bootstrap.';
COMMENT ON TABLE public.scoring_role_audit IS
  'Append-only role grant, revocation, and privileged bootstrap audit.';
COMMENT ON TABLE public.scoring_configuration_events IS
  'Append-only actor and reason history for scoring configuration lifecycle RPCs.';
COMMENT ON TABLE public.milestone_validations IS
  'Immutable human milestone decisions tied to an idea revision; no automatic decision or scoring is performed.';

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
