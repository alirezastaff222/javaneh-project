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
  IF pg_catalog.has_schema_privilege(
       'javaneh_identity_executor', 'public', 'CREATE'
     ) THEN
    RAISE EXCEPTION
      'javaneh_identity_executor already has CREATE on public; refusing temporary privilege window'
      USING ERRCODE = '42501';
  END IF;
END
$prerequisite_check$;

CREATE TABLE public.participant_groups (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  name text NOT NULL CHECK (
    pg_catalog.length(pg_catalog.btrim(name)) BETWEEN 2 AND 120
  ),
  description text NOT NULL DEFAULT '' CHECK (
    pg_catalog.length(description) <= 4000
  ),
  owner_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  dissolved_at timestamptz,
  CONSTRAINT participant_groups_time_order
    CHECK (updated_at >= created_at)
);

CREATE TABLE public.participant_group_memberships (
  group_id uuid NOT NULL
    REFERENCES public.participant_groups(id) ON DELETE RESTRICT,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('owner', 'member')),
  status text NOT NULL CHECK (status IN ('accepted', 'left', 'removed')),
  joined_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (group_id, user_id),
  CONSTRAINT participant_group_memberships_owner_status
    CHECK (role <> 'owner' OR status = 'accepted')
);

CREATE UNIQUE INDEX participant_group_one_active_owner_idx
  ON public.participant_group_memberships (group_id)
  WHERE role = 'owner' AND status = 'accepted';
CREATE INDEX participant_group_memberships_user_idx
  ON public.participant_group_memberships (user_id, status, group_id);

CREATE TABLE public.participant_group_invitations (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  group_id uuid NOT NULL
    REFERENCES public.participant_groups(id) ON DELETE RESTRICT,
  email text NOT NULL CHECK (
    email = pg_catalog.lower(pg_catalog.btrim(email))
    AND email ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  ),
  invited_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'rejected', 'revoked', 'expired')),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  expires_at timestamptz NOT NULL
    DEFAULT (pg_catalog.clock_timestamp() + interval '7 days'),
  responded_at timestamptz,
  responded_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT participant_group_invitation_response_consistent
    CHECK (
      (status IN ('accepted', 'rejected', 'revoked', 'expired')
        AND responded_at IS NOT NULL)
      OR (status = 'pending' AND responded_at IS NULL)
    ),
  CONSTRAINT participant_group_invitation_expiry_after_create
    CHECK (expires_at > created_at)
);

CREATE UNIQUE INDEX participant_group_one_pending_invitation_idx
  ON public.participant_group_invitations (group_id, email)
  WHERE status = 'pending';
CREATE INDEX participant_group_invitations_email_idx
  ON public.participant_group_invitations (email, status, expires_at);

CREATE TABLE public.participant_group_events (
  event_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  group_id uuid NOT NULL
    REFERENCES public.participant_groups(id) ON DELETE RESTRICT,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type text NOT NULL CHECK (event_type IN (
    'group_created',
    'invitation_created',
    'invitation_accepted',
    'invitation_rejected',
    'invitation_revoked',
    'member_removed',
    'member_left',
    'ownership_transferred',
    'group_dissolved',
    'idea_created'
  )),
  subject_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  invitation_id uuid REFERENCES public.participant_group_invitations(id)
    ON DELETE SET NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (pg_catalog.jsonb_typeof(details) = 'object'),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);
CREATE INDEX participant_group_events_history_idx
  ON public.participant_group_events (group_id, created_at DESC, event_id);

ALTER TABLE public.ideas
  ADD COLUMN group_id uuid
    REFERENCES public.participant_groups(id) ON DELETE RESTRICT;
ALTER TABLE public.idea_deletion_audit
  ADD COLUMN group_id uuid
    REFERENCES public.participant_groups(id) ON DELETE RESTRICT;
ALTER TABLE public.idea_deletion_audit
  DROP CONSTRAINT idea_deletion_audit_owner_creation_request_key;
CREATE UNIQUE INDEX idea_deletion_audit_individual_creation_request_idx
  ON public.idea_deletion_audit (owner_id, creation_request_id)
  WHERE group_id IS NULL;
CREATE UNIQUE INDEX idea_deletion_audit_group_creation_request_idx
  ON public.idea_deletion_audit (group_id, creation_request_id)
  WHERE group_id IS NOT NULL;
CREATE INDEX ideas_group_created_at_idx
  ON public.ideas (group_id, created_at DESC)
  WHERE group_id IS NOT NULL;
CREATE UNIQUE INDEX ideas_group_creation_request_key
  ON public.ideas (group_id, creation_request_id)
  WHERE group_id IS NOT NULL;

ALTER TABLE public.official_points_ledger
  ADD COLUMN group_id uuid
    REFERENCES public.participant_groups(id) ON DELETE RESTRICT;
CREATE INDEX official_points_ledger_group_history_idx
  ON public.official_points_ledger (group_id, recorded_at DESC, entry_id)
  WHERE group_id IS NOT NULL;

ALTER TABLE public.participant_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.participant_groups FORCE ROW LEVEL SECURITY;
ALTER TABLE public.participant_group_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.participant_group_memberships FORCE ROW LEVEL SECURITY;
ALTER TABLE public.participant_group_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.participant_group_invitations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.participant_group_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.participant_group_events FORCE ROW LEVEL SECURITY;

CREATE POLICY participant_groups_executor_all
  ON public.participant_groups FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY participant_group_memberships_executor_all
  ON public.participant_group_memberships FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY participant_group_invitations_executor_all
  ON public.participant_group_invitations FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY participant_group_events_executor_all
  ON public.participant_group_events FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.participant_groups,
  public.participant_group_memberships,
  public.participant_group_invitations,
  public.participant_group_events
  TO javaneh_identity_executor;

REVOKE ALL ON TABLE
  public.participant_groups,
  public.participant_group_memberships,
  public.participant_group_invitations,
  public.participant_group_events
  FROM PUBLIC, anon, authenticated, service_role;

GRANT CREATE ON SCHEMA public TO javaneh_identity_executor;

CREATE OR REPLACE FUNCTION public.create_idea(p_request_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_idea_id uuid;
  v_existing_id uuid;
  v_count integer;
  v_stage smallint;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_request_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('javaneh:quota:v1:' || v_owner_id::text, 0)
  );
  SELECT idea.id INTO v_existing_id
    FROM public.ideas AS idea
    WHERE idea.owner_id = v_owner_id
      AND idea.group_id IS NULL
      AND idea.creation_request_id = p_request_id;
  IF v_existing_id IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_exists', 'idea_id', v_existing_id
    );
  END IF;
  SELECT audit.deleted_idea_id INTO v_existing_id
    FROM public.idea_deletion_audit AS audit
    WHERE audit.owner_id = v_owner_id
      AND audit.group_id IS NULL
      AND audit.creation_request_id = p_request_id;
  IF v_existing_id IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_deleted');
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas AS idea
    WHERE idea.owner_id = v_owner_id AND idea.group_id IS NULL;
  IF v_count >= 3 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'quota_exceeded');
  END IF;

  INSERT INTO public.ideas (owner_id, creation_request_id)
    VALUES (v_owner_id, p_request_id)
    RETURNING id INTO v_idea_id;
  FOR v_stage IN 1..7 LOOP
    INSERT INTO public.idea_stages (idea_id, stage_number, data, status)
      VALUES (
        v_idea_id, v_stage, '{}'::jsonb,
        CASE WHEN v_stage = 1 THEN 'in_progress' ELSE 'locked' END
      );
  END LOOP;
  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'created', 'idea_id', v_idea_id, 'revision', 1
  );
END
$function$;
ALTER FUNCTION public.create_idea(uuid)
  OWNER TO javaneh_identity_executor;

CREATE FUNCTION public.set_idea_deletion_group_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_group_id uuid;
BEGIN
  SELECT idea.group_id INTO v_group_id
    FROM public.ideas AS idea
    WHERE idea.id = NEW.deleted_idea_id;
  IF FOUND THEN
    IF NEW.group_id IS NOT NULL
       AND NEW.group_id IS DISTINCT FROM v_group_id THEN
      RAISE EXCEPTION 'Deletion audit group does not match the idea'
        USING ERRCODE = '23514';
    END IF;
    NEW.group_id := v_group_id;
  END IF;
  RETURN NEW;
END
$function$;
ALTER FUNCTION public.set_idea_deletion_group_id()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.set_idea_deletion_group_id()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER idea_deletion_audit_group_attribution
  BEFORE INSERT ON public.idea_deletion_audit
  FOR EACH ROW EXECUTE FUNCTION public.set_idea_deletion_group_id();

SET ROLE javaneh_identity_bridge;
CREATE OR REPLACE FUNCTION javaneh_private.current_uid()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT COALESCE(
    NULLIF(
      pg_catalog.current_setting('javaneh.group_owner_context', true), ''
    )::uuid,
    javaneh_private.auth_uid()
  )
$function$;
REVOKE ALL ON FUNCTION javaneh_private.current_uid()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION javaneh_private.current_uid()
  TO authenticated, javaneh_identity_executor;
RESET ROLE;

SET ROLE javaneh_identity_bridge;
CREATE FUNCTION javaneh_private.auth_email()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT pg_catalog.lower(
    pg_catalog.btrim(COALESCE(auth.jwt()->>'email', ''))
  )
$function$;
RESET ROLE;
ALTER FUNCTION javaneh_private.auth_email() OWNER TO postgres;
REVOKE ALL ON FUNCTION javaneh_private.auth_email()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION javaneh_private.auth_email()
  TO javaneh_identity_executor;

ALTER FUNCTION public.save_idea_content(uuid, uuid, integer, jsonb)
  RENAME TO save_idea_content_internal;
ALTER FUNCTION public.request_idea_stage_confirmation(uuid, smallint)
  RENAME TO request_idea_stage_confirmation_internal;
ALTER FUNCTION public.confirm_idea_stage(uuid, smallint, integer)
  RENAME TO confirm_idea_stage_internal;
ALTER FUNCTION public.delete_own_idea(uuid)
  RENAME TO delete_own_idea_internal;
ALTER FUNCTION public.set_idea_current_step(uuid, smallint)
  RENAME TO set_idea_current_step_internal;
ALTER FUNCTION public.submit_idea(uuid, uuid, integer)
  RENAME TO submit_idea_internal;
ALTER FUNCTION public.edit_submitted_idea(uuid, uuid, integer, jsonb)
  RENAME TO edit_submitted_idea_internal;
ALTER FUNCTION public.get_own_submitted_idea_dossier_history(uuid)
  RENAME TO get_own_submitted_idea_dossier_history_internal;
ALTER FUNCTION public.get_participant_idea_scorecard(uuid)
  RENAME TO get_participant_idea_scorecard_internal;
ALTER FUNCTION public.get_participant_milestone_evaluations(uuid)
  RENAME TO get_participant_milestone_evaluations_internal;
ALTER FUNCTION public.submit_milestone_for_validation(uuid, uuid, text, integer)
  RENAME TO submit_milestone_for_validation_internal;
ALTER FUNCTION public.get_own_idea_evaluation_status(uuid)
  RENAME TO get_own_idea_evaluation_status_internal;
ALTER FUNCTION public.get_own_idea_published_feedback(uuid)
  RENAME TO get_own_idea_published_feedback_internal;
ALTER FUNCTION public.get_participant_published_jury_score(uuid)
  RENAME TO get_participant_published_jury_score_internal;
ALTER FUNCTION public.get_participant_published_result(uuid)
  RENAME TO get_participant_published_result_internal;
ALTER FUNCTION public.get_own_idea_classification_status(uuid)
  RENAME TO get_own_idea_classification_status_internal;

REVOKE ALL ON FUNCTION
  public.save_idea_content_internal(uuid, uuid, integer, jsonb),
  public.request_idea_stage_confirmation_internal(uuid, smallint),
  public.confirm_idea_stage_internal(uuid, smallint, integer),
  public.delete_own_idea_internal(uuid),
  public.set_idea_current_step_internal(uuid, smallint),
  public.submit_idea_internal(uuid, uuid, integer),
  public.edit_submitted_idea_internal(uuid, uuid, integer, jsonb),
  public.get_own_submitted_idea_dossier_history_internal(uuid),
  public.get_participant_idea_scorecard_internal(uuid),
  public.get_participant_milestone_evaluations_internal(uuid),
  public.submit_milestone_for_validation_internal(uuid, uuid, text, integer),
  public.get_own_idea_evaluation_status_internal(uuid),
  public.get_own_idea_published_feedback_internal(uuid),
  public.get_participant_published_jury_score_internal(uuid),
  public.get_participant_published_result_internal(uuid),
  public.get_own_idea_classification_status_internal(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION
  public.save_idea_content_internal(uuid, uuid, integer, jsonb),
  public.request_idea_stage_confirmation_internal(uuid, smallint),
  public.confirm_idea_stage_internal(uuid, smallint, integer),
  public.delete_own_idea_internal(uuid),
  public.set_idea_current_step_internal(uuid, smallint),
  public.submit_idea_internal(uuid, uuid, integer),
  public.edit_submitted_idea_internal(uuid, uuid, integer, jsonb),
  public.get_own_submitted_idea_dossier_history_internal(uuid),
  public.get_participant_idea_scorecard_internal(uuid),
  public.get_participant_milestone_evaluations_internal(uuid),
  public.submit_milestone_for_validation_internal(uuid, uuid, text, integer),
  public.get_own_idea_evaluation_status_internal(uuid),
  public.get_own_idea_published_feedback_internal(uuid),
  public.get_participant_published_jury_score_internal(uuid),
  public.get_participant_published_result_internal(uuid),
  public.get_own_idea_classification_status_internal(uuid)
  TO javaneh_identity_executor;

CREATE FUNCTION public.is_individual_idea(p_idea_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.ideas
      WHERE id = p_idea_id AND group_id IS NULL
  )
$function$;
ALTER FUNCTION public.is_individual_idea(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.is_individual_idea(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_individual_idea(uuid)
  TO javaneh_identity_executor;

CREATE FUNCTION public.save_idea_content(
  p_idea_id uuid,
  p_request_id uuid,
  p_expected_revision integer,
  p_stage_updates jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  RETURN public.save_idea_content_internal(
    p_idea_id, p_request_id, p_expected_revision, p_stage_updates
  );
END
$function$;

CREATE FUNCTION public.request_idea_stage_confirmation(
  p_idea_id uuid,
  p_stage_number smallint
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  RETURN public.request_idea_stage_confirmation_internal(
    p_idea_id, p_stage_number
  );
END
$function$;

CREATE FUNCTION public.confirm_idea_stage(
  p_idea_id uuid,
  p_stage_number smallint,
  p_expected_revision integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  RETURN public.confirm_idea_stage_internal(
    p_idea_id, p_stage_number, p_expected_revision
  );
END
$function$;

CREATE FUNCTION public.delete_own_idea(p_idea_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_already_deleted');
  END IF;
  RETURN public.delete_own_idea_internal(p_idea_id);
END
$function$;

CREATE FUNCTION public.set_idea_current_step(
  p_idea_id uuid,
  p_current_step smallint
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  RETURN public.set_idea_current_step_internal(p_idea_id, p_current_step);
END
$function$;

CREATE FUNCTION public.submit_idea(
  p_idea_id uuid,
  p_request_id uuid,
  p_expected_revision integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  RETURN public.submit_idea_internal(
    p_idea_id, p_request_id, p_expected_revision
  );
END
$function$;

CREATE FUNCTION public.edit_submitted_idea(
  p_idea_id uuid,
  p_request_id uuid,
  p_expected_revision integer,
  p_stage_updates jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  RETURN public.edit_submitted_idea_internal(
    p_idea_id, p_request_id, p_expected_revision, p_stage_updates
  );
END
$function$;

CREATE FUNCTION public.get_own_submitted_idea_dossier_history(
  p_idea_id uuid
)
RETURNS TABLE (revision integer, dossier jsonb, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RAISE EXCEPTION 'Dossier history is unavailable'
      USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT * FROM public.get_own_submitted_idea_dossier_history_internal(p_idea_id);
END
$function$;

CREATE FUNCTION public.get_participant_idea_scorecard(p_idea_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'not_found'
    );
  END IF;
  RETURN public.get_participant_idea_scorecard_internal(p_idea_id);
END
$function$;

CREATE FUNCTION public.get_participant_milestone_evaluations(p_idea_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'not_found'
    );
  END IF;
  RETURN public.get_participant_milestone_evaluations_internal(p_idea_id);
END
$function$;

CREATE FUNCTION public.submit_milestone_for_validation(
  p_idea_id uuid,
  p_configuration_version_id uuid,
  p_milestone_key text,
  p_expected_revision integer
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  RETURN public.submit_milestone_for_validation_internal(
    p_idea_id, p_configuration_version_id, p_milestone_key,
    p_expected_revision
  );
END
$function$;

CREATE FUNCTION public.get_own_idea_evaluation_status(p_idea_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  RETURN public.get_own_idea_evaluation_status_internal(p_idea_id);
END
$function$;

CREATE FUNCTION public.get_own_idea_published_feedback(p_idea_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  RETURN public.get_own_idea_published_feedback_internal(p_idea_id);
END
$function$;

CREATE FUNCTION public.get_participant_published_jury_score(p_idea_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('state', 'unpublished');
  END IF;
  RETURN public.get_participant_published_jury_score_internal(p_idea_id);
END
$function$;

CREATE FUNCTION public.get_participant_published_result(p_idea_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object('state', 'unpublished');
  END IF;
  RETURN public.get_participant_published_result_internal(p_idea_id);
END
$function$;

CREATE FUNCTION public.get_own_idea_classification_status(p_idea_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
BEGIN
  IF NOT public.is_individual_idea(p_idea_id) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'not_found',
      'current_classification_id', NULL,
      'source_stage_1_revision_id', NULL,
      'source_stage_2_revision_id', NULL,
      'wait_ms', NULL
    );
  END IF;
  RETURN public.get_own_idea_classification_status_internal(p_idea_id);
END
$function$;

DO $participant_rpc_grants$
BEGIN
  ALTER FUNCTION public.save_idea_content(uuid, uuid, integer, jsonb)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.request_idea_stage_confirmation(uuid, smallint)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.confirm_idea_stage(uuid, smallint, integer)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.delete_own_idea(uuid)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.set_idea_current_step(uuid, smallint)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.submit_idea(uuid, uuid, integer)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.edit_submitted_idea(uuid, uuid, integer, jsonb)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.get_own_submitted_idea_dossier_history(uuid)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.get_participant_idea_scorecard(uuid)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.get_participant_milestone_evaluations(uuid)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.submit_milestone_for_validation(uuid, uuid, text, integer)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.get_own_idea_evaluation_status(uuid)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.get_own_idea_published_feedback(uuid)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.get_participant_published_jury_score(uuid)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.get_participant_published_result(uuid)
    OWNER TO javaneh_identity_executor;
  ALTER FUNCTION public.get_own_idea_classification_status(uuid)
    OWNER TO javaneh_identity_executor;
END
$participant_rpc_grants$;

REVOKE ALL ON FUNCTION
  public.save_idea_content(uuid, uuid, integer, jsonb),
  public.request_idea_stage_confirmation(uuid, smallint),
  public.confirm_idea_stage(uuid, smallint, integer),
  public.delete_own_idea(uuid),
  public.set_idea_current_step(uuid, smallint),
  public.submit_idea(uuid, uuid, integer),
  public.edit_submitted_idea(uuid, uuid, integer, jsonb),
  public.get_own_submitted_idea_dossier_history(uuid),
  public.get_participant_idea_scorecard(uuid),
  public.get_participant_milestone_evaluations(uuid),
  public.submit_milestone_for_validation(uuid, uuid, text, integer),
  public.get_own_idea_evaluation_status(uuid),
  public.get_own_idea_published_feedback(uuid),
  public.get_participant_published_jury_score(uuid),
  public.get_participant_published_result(uuid),
  public.get_own_idea_classification_status(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION
  public.save_idea_content(uuid, uuid, integer, jsonb),
  public.request_idea_stage_confirmation(uuid, smallint),
  public.confirm_idea_stage(uuid, smallint, integer),
  public.delete_own_idea(uuid),
  public.set_idea_current_step(uuid, smallint),
  public.submit_idea(uuid, uuid, integer),
  public.edit_submitted_idea(uuid, uuid, integer, jsonb),
  public.get_own_submitted_idea_dossier_history(uuid),
  public.get_participant_idea_scorecard(uuid),
  public.get_participant_milestone_evaluations(uuid),
  public.submit_milestone_for_validation(uuid, uuid, text, integer),
  public.get_own_idea_evaluation_status(uuid),
  public.get_own_idea_published_feedback(uuid),
  public.get_participant_published_jury_score(uuid),
  public.get_participant_published_result(uuid),
  public.get_own_idea_classification_status(uuid)
  TO authenticated;

CREATE FUNCTION public.is_accepted_group_member(
  p_group_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM public.participant_group_memberships AS membership
      WHERE membership.group_id = p_group_id
        AND membership.user_id = p_user_id
        AND membership.status = 'accepted'
  )
$function$;
ALTER FUNCTION public.is_accepted_group_member(uuid, uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.is_accepted_group_member(uuid, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.is_accepted_group_member(uuid, uuid)
  TO authenticated, javaneh_identity_executor;

CREATE FUNCTION public.can_access_idea(
  p_idea_id uuid,
  p_user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM public.ideas AS idea
      WHERE idea.id = p_idea_id
        AND (
          (
            idea.group_id IS NULL
            AND idea.owner_id = p_user_id
          )
          OR (
            idea.group_id IS NOT NULL
            AND public.is_accepted_group_member(idea.group_id, p_user_id)
          )
        )
  )
$function$;
ALTER FUNCTION public.can_access_idea(uuid, uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.can_access_idea(uuid, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.can_access_idea(uuid, uuid)
  TO authenticated, javaneh_identity_executor;

CREATE OR REPLACE FUNCTION public.create_participant_group(
  p_name text,
  p_description text DEFAULT ''
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_group_id uuid;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR pg_catalog.length(pg_catalog.btrim(p_name)) NOT BETWEEN 2 AND 120
     OR p_description IS NULL OR pg_catalog.length(p_description) > 4000 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  INSERT INTO public.participant_groups (name, description, owner_id)
    VALUES (pg_catalog.btrim(p_name), p_description, v_actor)
    RETURNING id INTO v_group_id;
  INSERT INTO public.participant_group_memberships (
    group_id, user_id, role, status
  ) VALUES (v_group_id, v_actor, 'owner', 'accepted');
  INSERT INTO public.participant_group_events (group_id, actor_id, event_type)
    VALUES (v_group_id, v_actor, 'group_created');
  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'created', 'group_id', v_group_id
  );
END
$function$;
ALTER FUNCTION public.create_participant_group(text, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.create_participant_group(text, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_participant_group(text, text)
  TO authenticated;

CREATE FUNCTION public.get_my_participant_groups()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'groups',
    COALESCE((
      SELECT pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', group_row.id,
          'name', group_row.name,
          'description', group_row.description,
          'owner_id', group_row.owner_id,
          'role', membership.role,
          'dissolved_at', group_row.dissolved_at,
          'created_at', group_row.created_at,
          'members', (
            SELECT COALESCE(pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'user_id', member.user_id,
                'role', member.role,
                'joined_at', member.joined_at
              ) ORDER BY member.role, member.joined_at
            ), '[]'::jsonb)
            FROM public.participant_group_memberships AS member
            WHERE member.group_id = group_row.id
              AND member.status = 'accepted'
          ),
          'pending_invitations', CASE WHEN membership.role = 'owner' THEN (
            SELECT COALESCE(pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'id', invitation.id,
                'email', invitation.email,
                'expires_at', invitation.expires_at
              ) ORDER BY invitation.created_at
            ), '[]'::jsonb)
            FROM public.participant_group_invitations AS invitation
            WHERE invitation.group_id = group_row.id
              AND invitation.status = 'pending'
              AND invitation.expires_at > pg_catalog.clock_timestamp()
          ) ELSE '[]'::jsonb END
        ) ORDER BY group_row.created_at
      )
      FROM public.participant_groups AS group_row
      JOIN public.participant_group_memberships AS membership
        ON membership.group_id = group_row.id
       AND membership.user_id = v_actor
       AND membership.status = 'accepted'
    ), '[]'::jsonb)
  );
END
$function$;
ALTER FUNCTION public.get_my_participant_groups()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_my_participant_groups()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_participant_groups() TO authenticated;

CREATE FUNCTION public.get_my_group_invitations()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_email text := javaneh_private.auth_email();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.participant_group_invitations
    SET status = 'expired', responded_at = pg_catalog.clock_timestamp()
    WHERE email = v_email AND status = 'pending'
      AND expires_at <= pg_catalog.clock_timestamp();

  RETURN pg_catalog.jsonb_build_object(
    'invitations',
    COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', invitation.id,
        'group_id', invitation.group_id,
        'group_name', group_row.name,
        'invited_by', invitation.invited_by,
        'created_at', invitation.created_at,
        'expires_at', invitation.expires_at
      ) ORDER BY invitation.created_at DESC)
      FROM public.participant_group_invitations AS invitation
      JOIN public.participant_groups AS group_row
        ON group_row.id = invitation.group_id
      WHERE invitation.email = v_email
        AND invitation.status = 'pending'
        AND invitation.expires_at > pg_catalog.clock_timestamp()
    ), '[]'::jsonb)
  );
END
$function$;
ALTER FUNCTION public.get_my_group_invitations()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_my_group_invitations()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_group_invitations() TO authenticated;

CREATE FUNCTION public.create_group_invitation(
  p_group_id uuid,
  p_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_email text := pg_catalog.lower(pg_catalog.btrim(COALESCE(p_email, '')));
  v_group public.participant_groups%ROWTYPE;
  v_invitation public.participant_group_invitations%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_group_id IS NULL OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  SELECT * INTO v_group FROM public.participant_groups
    WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND OR v_group.owner_id <> v_actor OR v_group.dissolved_at IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_authorized');
  END IF;

  UPDATE public.participant_group_invitations
    SET status = 'expired', responded_at = pg_catalog.clock_timestamp()
    WHERE group_id = p_group_id AND email = v_email
      AND status = 'pending' AND expires_at <= pg_catalog.clock_timestamp();

  SELECT * INTO v_invitation
    FROM public.participant_group_invitations
    WHERE group_id = p_group_id AND email = v_email AND status = 'pending';
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_invited',
      'invitation_id', v_invitation.id,
      'expires_at', v_invitation.expires_at
    );
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.participant_group_memberships AS membership
      WHERE membership.group_id = p_group_id
        AND membership.status = 'accepted'
        AND membership.user_id = v_actor
        AND v_email = javaneh_private.auth_email()
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_member');
  END IF;

  INSERT INTO public.participant_group_invitations (
    group_id, email, invited_by
  ) VALUES (p_group_id, v_email, v_actor)
  RETURNING * INTO v_invitation;
  INSERT INTO public.participant_group_events (
    group_id, actor_id, event_type, invitation_id, details
  ) VALUES (
    p_group_id, v_actor, 'invitation_created', v_invitation.id,
    pg_catalog.jsonb_build_object('email', v_email)
  );
  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'invited',
    'invitation_id', v_invitation.id,
    'email', v_email,
    'expires_at', v_invitation.expires_at
  );
END
$function$;
ALTER FUNCTION public.create_group_invitation(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.create_group_invitation(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_group_invitation(uuid, text)
  TO authenticated;

CREATE FUNCTION public.respond_to_group_invitation(
  p_invitation_id uuid,
  p_accept boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_email text := javaneh_private.auth_email();
  v_invitation public.participant_group_invitations%ROWTYPE;
  v_group public.participant_groups%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_invitation_id IS NULL OR p_accept IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  SELECT * INTO v_invitation
    FROM public.participant_group_invitations
    WHERE id = p_invitation_id AND email = v_email
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_invitation.status <> 'pending' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', v_invitation.status);
  END IF;
  IF v_invitation.expires_at <= pg_catalog.clock_timestamp() THEN
    UPDATE public.participant_group_invitations
      SET status = 'expired', responded_at = pg_catalog.clock_timestamp()
      WHERE id = p_invitation_id;
    RETURN pg_catalog.jsonb_build_object('outcome', 'expired');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.participant_group_memberships AS membership
      WHERE membership.group_id = v_invitation.group_id
        AND membership.user_id = v_actor
        AND membership.status = 'accepted'
  ) THEN
    UPDATE public.participant_group_invitations
      SET status = 'accepted', responded_at = pg_catalog.clock_timestamp(),
          responded_by = v_actor
      WHERE id = p_invitation_id;
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_member', 'group_id', v_invitation.group_id
    );
  END IF;
  SELECT * INTO v_group FROM public.participant_groups
    WHERE id = v_invitation.group_id FOR UPDATE;
  IF NOT FOUND OR v_group.dissolved_at IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'group_unavailable');
  END IF;
  IF p_accept THEN
    INSERT INTO public.participant_group_memberships (
      group_id, user_id, role, status
    ) VALUES (
      v_invitation.group_id, v_actor, 'member', 'accepted'
    )
    ON CONFLICT (group_id, user_id) DO UPDATE
      SET role = 'member', status = 'accepted',
          joined_at = pg_catalog.clock_timestamp(),
          updated_at = pg_catalog.clock_timestamp();
    UPDATE public.participant_group_invitations
      SET status = 'accepted', responded_at = pg_catalog.clock_timestamp(),
          responded_by = v_actor
      WHERE id = p_invitation_id;
    INSERT INTO public.participant_group_events (
      group_id, actor_id, event_type, subject_user_id, invitation_id
    ) VALUES (
      v_group.id, v_actor, 'invitation_accepted', v_actor, p_invitation_id
    );
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'accepted', 'group_id', v_group.id
    );
  END IF;
  UPDATE public.participant_group_invitations
    SET status = 'rejected', responded_at = pg_catalog.clock_timestamp(),
        responded_by = v_actor
    WHERE id = p_invitation_id;
  INSERT INTO public.participant_group_events (
    group_id, actor_id, event_type, subject_user_id, invitation_id
  ) VALUES (
    v_group.id, v_actor, 'invitation_rejected', v_actor, p_invitation_id
  );
  RETURN pg_catalog.jsonb_build_object('outcome', 'rejected');
END
$function$;
ALTER FUNCTION public.respond_to_group_invitation(uuid, boolean)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.respond_to_group_invitation(uuid, boolean)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.respond_to_group_invitation(uuid, boolean)
  TO authenticated;

CREATE FUNCTION public.manage_participant_group(
  p_group_id uuid,
  p_action text,
  p_member_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_group public.participant_groups%ROWTYPE;
  v_membership public.participant_group_memberships%ROWTYPE;
  v_target public.participant_group_memberships%ROWTYPE;
  v_event text;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_group_id IS NULL OR p_action NOT IN (
    'remove_member', 'leave', 'transfer_ownership', 'dissolve'
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  SELECT * INTO v_group FROM public.participant_groups
    WHERE id = p_group_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  SELECT * INTO v_membership
    FROM public.participant_group_memberships
    WHERE group_id = p_group_id AND user_id = v_actor
      AND status = 'accepted'
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_authorized');
  END IF;

  IF p_action = 'leave' THEN
    IF v_membership.role = 'owner' THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'transfer_required');
    END IF;
    UPDATE public.participant_group_memberships
      SET status = 'left', updated_at = pg_catalog.clock_timestamp()
      WHERE group_id = p_group_id AND user_id = v_actor;
    v_event := 'member_left';
  ELSIF p_action = 'remove_member' THEN
    IF v_membership.role <> 'owner' OR p_member_id IS NULL
       OR p_member_id = v_actor THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_authorized');
    END IF;
    UPDATE public.participant_group_memberships
      SET status = 'removed', updated_at = pg_catalog.clock_timestamp()
      WHERE group_id = p_group_id AND user_id = p_member_id
        AND role = 'member' AND status = 'accepted';
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
    END IF;
    v_event := 'member_removed';
  ELSIF p_action = 'transfer_ownership' THEN
    IF v_membership.role <> 'owner' OR p_member_id IS NULL
       OR p_member_id = v_actor THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_authorized');
    END IF;
    SELECT * INTO v_target
      FROM public.participant_group_memberships
      WHERE group_id = p_group_id AND user_id = p_member_id
        AND status = 'accepted' AND role = 'member'
      FOR UPDATE;
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'target_not_member');
    END IF;
    UPDATE public.participant_group_memberships
      SET role = 'member', updated_at = pg_catalog.clock_timestamp()
      WHERE group_id = p_group_id AND user_id = v_actor;
    UPDATE public.participant_group_memberships
      SET role = 'owner', updated_at = pg_catalog.clock_timestamp()
      WHERE group_id = p_group_id AND user_id = p_member_id;
    UPDATE public.participant_groups
      SET owner_id = p_member_id, updated_at = pg_catalog.clock_timestamp()
      WHERE id = p_group_id;
    v_event := 'ownership_transferred';
  ELSIF p_action = 'dissolve' THEN
    IF v_membership.role <> 'owner' THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_authorized');
    END IF;
    UPDATE public.participant_groups
      SET dissolved_at = COALESCE(dissolved_at, pg_catalog.clock_timestamp()),
          updated_at = pg_catalog.clock_timestamp()
      WHERE id = p_group_id;
    v_event := 'group_dissolved';
  END IF;

  INSERT INTO public.participant_group_events (
    group_id, actor_id, event_type, subject_user_id
  ) VALUES (
    p_group_id, v_actor, v_event,
    CASE WHEN p_action = 'leave' THEN v_actor ELSE p_member_id END
  );
  RETURN pg_catalog.jsonb_build_object('outcome', 'updated');
END
$function$;
ALTER FUNCTION public.manage_participant_group(uuid, text, uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.manage_participant_group(uuid, text, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.manage_participant_group(uuid, text, uuid)
  TO authenticated;

CREATE FUNCTION public.revoke_group_invitation(p_invitation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_invitation public.participant_group_invitations%ROWTYPE;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  SELECT invitation.* INTO v_invitation
    FROM public.participant_group_invitations AS invitation
    JOIN public.participant_groups AS group_row
      ON group_row.id = invitation.group_id
    WHERE invitation.id = p_invitation_id
      AND group_row.owner_id = v_actor
      AND invitation.status = 'pending'
    FOR UPDATE OF invitation;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_authorized');
  END IF;
  UPDATE public.participant_group_invitations
    SET status = 'revoked', responded_at = pg_catalog.clock_timestamp()
    WHERE id = p_invitation_id;
  INSERT INTO public.participant_group_events (
    group_id, actor_id, event_type, invitation_id
  ) VALUES (
    v_invitation.group_id, v_actor, 'invitation_revoked', p_invitation_id
  );
  RETURN pg_catalog.jsonb_build_object('outcome', 'revoked');
END
$function$;
ALTER FUNCTION public.revoke_group_invitation(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.revoke_group_invitation(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.revoke_group_invitation(uuid)
  TO authenticated;

CREATE FUNCTION public.create_group_idea(
  p_group_id uuid,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_group public.participant_groups%ROWTYPE;
  v_existing uuid;
  v_idea_id uuid;
  v_count integer;
  v_stage smallint;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_group_id IS NULL OR p_request_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;
  SELECT * INTO v_group FROM public.participant_groups
    WHERE id = p_group_id FOR SHARE;
  IF NOT FOUND OR v_group.dissolved_at IS NOT NULL
     OR NOT public.is_accepted_group_member(p_group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_authorized');
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('javaneh:group-quota:v1:' || p_group_id::text, 0)
  );

  SELECT id INTO v_existing FROM public.ideas
    WHERE group_id = p_group_id AND creation_request_id = p_request_id;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_exists', 'idea_id', v_existing
    );
  END IF;
  SELECT deleted_idea_id INTO v_existing
    FROM public.idea_deletion_audit
    WHERE group_id = p_group_id
      AND creation_request_id = p_request_id;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_deleted');
  END IF;
  SELECT count(*)::integer INTO v_count
    FROM public.ideas WHERE group_id = p_group_id;
  IF v_count >= 3 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'quota_exceeded');
  END IF;
  INSERT INTO public.ideas (owner_id, group_id, creation_request_id)
    VALUES (v_group.owner_id, p_group_id, p_request_id)
    RETURNING id INTO v_idea_id;
  FOR v_stage IN 1..7 LOOP
    INSERT INTO public.idea_stages (idea_id, stage_number, data, status)
      VALUES (
        v_idea_id, v_stage, '{}'::jsonb,
        CASE WHEN v_stage = 1 THEN 'in_progress' ELSE 'locked' END
      );
  END LOOP;
  INSERT INTO public.participant_group_events (
    group_id, actor_id, event_type, details
  ) VALUES (
    p_group_id, v_actor, 'idea_created',
    pg_catalog.jsonb_build_object('idea_id', v_idea_id)
  );
  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'created', 'idea_id', v_idea_id, 'revision', 1
  );
END
$function$;
ALTER FUNCTION public.create_group_idea(uuid, uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.create_group_idea(uuid, uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_group_idea(uuid, uuid)
  TO authenticated;

CREATE FUNCTION public.save_group_idea_content(
  p_idea_id uuid,
  p_request_id uuid,
  p_expected_revision integer,
  p_stage_updates jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_groups
    WHERE id = v_idea.group_id AND dissolved_at IS NULL FOR SHARE;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_group_memberships
    WHERE group_id = v_idea.group_id AND user_id = v_actor
      AND status = 'accepted' FOR SHARE;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.save_idea_content_internal(
    p_idea_id, p_request_id, p_expected_revision, p_stage_updates
  );
END
$function$;
ALTER FUNCTION public.save_group_idea_content(uuid, uuid, integer, jsonb)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.save_group_idea_content(uuid, uuid, integer, jsonb)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.save_group_idea_content(uuid, uuid, integer, jsonb)
  TO authenticated;

CREATE FUNCTION public.confirm_group_idea_stage(
  p_idea_id uuid,
  p_stage_number smallint,
  p_expected_revision integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_groups
    WHERE id = v_idea.group_id AND dissolved_at IS NULL FOR SHARE;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_group_memberships
    WHERE group_id = v_idea.group_id AND user_id = v_actor
      AND status = 'accepted' FOR SHARE;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.confirm_idea_stage_internal(
    p_idea_id, p_stage_number, p_expected_revision
  );
END
$function$;
ALTER FUNCTION public.confirm_group_idea_stage(uuid, smallint, integer)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.confirm_group_idea_stage(uuid, smallint, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_group_idea_stage(uuid, smallint, integer)
  TO authenticated;

CREATE FUNCTION public.request_group_idea_stage_confirmation(
  p_idea_id uuid,
  p_stage_number smallint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_groups
    WHERE id = v_idea.group_id AND dissolved_at IS NULL FOR SHARE;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_group_memberships
    WHERE group_id = v_idea.group_id AND user_id = v_actor
      AND status = 'accepted' FOR SHARE;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.request_idea_stage_confirmation_internal(
    p_idea_id, p_stage_number
  );
END
$function$;
ALTER FUNCTION public.request_group_idea_stage_confirmation(uuid, smallint)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.request_group_idea_stage_confirmation(uuid, smallint)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.request_group_idea_stage_confirmation(uuid, smallint)
  TO authenticated;

CREATE FUNCTION public.set_group_idea_current_step(
  p_idea_id uuid,
  p_current_step smallint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_groups
    WHERE id = v_idea.group_id AND dissolved_at IS NULL FOR SHARE;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_group_memberships
    WHERE group_id = v_idea.group_id AND user_id = v_actor
      AND status = 'accepted' FOR SHARE;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.set_idea_current_step_internal(p_idea_id, p_current_step);
END
$function$;
ALTER FUNCTION public.set_group_idea_current_step(uuid, smallint)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.set_group_idea_current_step(uuid, smallint)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_group_idea_current_step(uuid, smallint)
  TO authenticated;

CREATE FUNCTION public.submit_group_idea(
  p_idea_id uuid,
  p_request_id uuid,
  p_expected_revision integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
  v_group public.participant_groups%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  SELECT * INTO v_group FROM public.participant_groups
    WHERE id = v_idea.group_id AND dissolved_at IS NULL FOR SHARE;
  IF NOT FOUND OR v_group.owner_id <> v_actor
     OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_authorized');
  END IF;
  PERFORM 1 FROM public.participant_group_memberships
    WHERE group_id = v_idea.group_id AND user_id = v_actor
      AND status = 'accepted' FOR SHARE;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.submit_idea_internal(
    p_idea_id, p_request_id, p_expected_revision
  );
END
$function$;
ALTER FUNCTION public.submit_group_idea(uuid, uuid, integer)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.submit_group_idea(uuid, uuid, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.submit_group_idea(uuid, uuid, integer)
  TO authenticated;

CREATE FUNCTION public.delete_group_idea(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
  v_group public.participant_groups%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  SELECT * INTO v_group FROM public.participant_groups
    WHERE id = v_idea.group_id AND dissolved_at IS NULL FOR SHARE;
  IF NOT FOUND OR v_group.owner_id <> v_actor
     OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_authorized');
  END IF;
  PERFORM 1 FROM public.participant_group_memberships
    WHERE group_id = v_idea.group_id AND user_id = v_actor
      AND status = 'accepted' FOR SHARE;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.delete_own_idea_internal(p_idea_id);
END
$function$;
ALTER FUNCTION public.delete_group_idea(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.delete_group_idea(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.delete_group_idea(uuid)
  TO authenticated;

CREATE FUNCTION public.get_group_idea_scorecard(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
  v_group public.participant_groups%ROWTYPE;
  v_scorecard jsonb;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object(
      'state', 'unavailable', 'reason', 'not_found'
    );
  END IF;
  SELECT * INTO v_group FROM public.participant_groups
    WHERE id = v_idea.group_id;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  v_scorecard := public.get_participant_idea_scorecard_internal(p_idea_id);
  RETURN v_scorecard || pg_catalog.jsonb_build_object(
    'group_id', v_group.id,
    'group_name', v_group.name,
    'attribution', 'group'
  );
END
$function$;
ALTER FUNCTION public.get_group_idea_scorecard(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_group_idea_scorecard(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_group_idea_scorecard(uuid)
  TO authenticated;

CREATE FUNCTION public.get_group_idea_classification_status(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'not_found',
      'current_classification_id', NULL,
      'source_stage_1_revision_id', NULL,
      'source_stage_2_revision_id', NULL,
      'wait_ms', NULL
    );
  END IF;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.get_own_idea_classification_status_internal(p_idea_id);
END
$function$;
ALTER FUNCTION public.get_group_idea_classification_status(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_group_idea_classification_status(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_group_idea_classification_status(uuid)
  TO authenticated;

CREATE FUNCTION public.group_idea_milestone_evaluations(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.get_participant_milestone_evaluations_internal(p_idea_id);
END
$function$;
ALTER FUNCTION public.group_idea_milestone_evaluations(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.group_idea_milestone_evaluations(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.group_idea_milestone_evaluations(uuid)
  TO authenticated;

CREATE FUNCTION public.submit_group_milestone_for_validation(
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
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_groups
    WHERE id = v_idea.group_id AND dissolved_at IS NULL FOR SHARE;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_group_memberships
    WHERE group_id = v_idea.group_id AND user_id = v_actor
      AND status = 'accepted' FOR SHARE;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.submit_milestone_for_validation_internal(
    p_idea_id, p_configuration_version_id, p_milestone_key,
    p_expected_revision
  );
END
$function$;
ALTER FUNCTION public.submit_group_milestone_for_validation(uuid, uuid, text, integer)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.submit_group_milestone_for_validation(uuid, uuid, text, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.submit_group_milestone_for_validation(uuid, uuid, text, integer)
  TO authenticated;

CREATE FUNCTION public.edit_group_submitted_idea(
  p_idea_id uuid,
  p_request_id uuid,
  p_expected_revision integer,
  p_stage_updates jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_groups
    WHERE id = v_idea.group_id AND dissolved_at IS NULL FOR SHARE;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  PERFORM 1 FROM public.participant_group_memberships
    WHERE group_id = v_idea.group_id AND user_id = v_actor
      AND status = 'accepted' FOR SHARE;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.edit_submitted_idea_internal(
    p_idea_id, p_request_id, p_expected_revision, p_stage_updates
  );
END
$function$;
ALTER FUNCTION public.edit_group_submitted_idea(uuid, uuid, integer, jsonb)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.edit_group_submitted_idea(uuid, uuid, integer, jsonb)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.edit_group_submitted_idea(uuid, uuid, integer, jsonb)
  TO authenticated;

CREATE FUNCTION public.get_group_evaluation_status(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.get_own_idea_evaluation_status_internal(p_idea_id);
END
$function$;
ALTER FUNCTION public.get_group_evaluation_status(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_group_evaluation_status(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_group_evaluation_status(uuid)
  TO authenticated;

CREATE FUNCTION public.get_group_published_feedback(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.get_own_idea_published_feedback_internal(p_idea_id);
END
$function$;
ALTER FUNCTION public.get_group_published_feedback(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_group_published_feedback(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_group_published_feedback(uuid)
  TO authenticated;

CREATE FUNCTION public.get_group_dossier_history(p_idea_id uuid)
RETURNS TABLE (
  revision integer,
  dossier jsonb,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RAISE EXCEPTION 'Dossier history is unavailable'
      USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN QUERY
    SELECT history.revision, history.dossier, history.created_at
      FROM public.get_own_submitted_idea_dossier_history_internal(p_idea_id) AS history;
END
$function$;
ALTER FUNCTION public.get_group_dossier_history(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_group_dossier_history(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_group_dossier_history(uuid)
  TO authenticated;

CREATE FUNCTION public.get_group_published_jury_score(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('state', 'unpublished');
  END IF;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.get_participant_published_jury_score_internal(p_idea_id);
END
$function$;
ALTER FUNCTION public.get_group_published_jury_score(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_group_published_jury_score(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_group_published_jury_score(uuid)
  TO authenticated;

CREATE FUNCTION public.get_group_published_result(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.auth_uid();
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas
    WHERE id = p_idea_id AND group_id IS NOT NULL;
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF NOT FOUND OR NOT public.is_accepted_group_member(v_idea.group_id, v_actor) THEN
    RETURN pg_catalog.jsonb_build_object('state', 'unpublished');
  END IF;
  PERFORM pg_catalog.set_config(
    'javaneh.group_owner_context', v_idea.owner_id::text, true
  );
  RETURN public.get_participant_published_result_internal(p_idea_id);
END
$function$;
ALTER FUNCTION public.get_group_published_result(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_group_published_result(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_group_published_result(uuid)
  TO authenticated;

CREATE FUNCTION public.set_points_group_attribution()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_idea public.ideas%ROWTYPE;
BEGIN
  SELECT * INTO v_idea FROM public.ideas WHERE id = NEW.idea_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Points entry idea does not exist'
      USING ERRCODE = '23503';
  END IF;
  IF NEW.user_id IS DISTINCT FROM v_idea.owner_id THEN
    RAISE EXCEPTION 'Points entry participant does not match the idea owner'
      USING ERRCODE = '23514';
  END IF;
  NEW.group_id := v_idea.group_id;
  RETURN NEW;
END
$function$;
ALTER FUNCTION public.set_points_group_attribution()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.set_points_group_attribution()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER official_points_group_attribution
  BEFORE INSERT ON public.official_points_ledger
  FOR EACH ROW EXECUTE FUNCTION public.set_points_group_attribution();

CREATE OR REPLACE FUNCTION public.prevent_ownerless_group_deletion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.participant_groups AS group_row
      WHERE group_row.owner_id = OLD.id
  ) OR EXISTS (
    SELECT 1 FROM public.ideas AS idea
      WHERE idea.owner_id = OLD.id AND idea.group_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION
      'Transfer group ownership first; this account is still referenced by a group-owned idea or group'
      USING ERRCODE = '23503';
  END IF;
  RETURN OLD;
END
$function$;
ALTER FUNCTION public.prevent_ownerless_group_deletion()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.prevent_ownerless_group_deletion()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER auth_users_prevent_ownerless_groups
  BEFORE DELETE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.prevent_ownerless_group_deletion();

DROP POLICY ideas_owner_read ON public.ideas;
CREATE POLICY ideas_owner_or_group_member_read
  ON public.ideas FOR SELECT TO authenticated
  USING (public.can_access_idea(id, javaneh_private.auth_uid()));
DROP POLICY idea_stages_owner_read ON public.idea_stages;
CREATE POLICY idea_stages_owner_or_group_member_read
  ON public.idea_stages FOR SELECT TO authenticated
  USING (public.can_access_idea(idea_id, javaneh_private.auth_uid()));
DROP POLICY idea_classification_state_owner_read
  ON public.idea_classification_state;
CREATE POLICY idea_classification_state_owner_or_group_read
  ON public.idea_classification_state FOR SELECT TO authenticated
  USING (
    public.can_access_idea(
      idea_classification_state.idea_id, javaneh_private.auth_uid()
    )
  );
DROP POLICY idea_classification_current_owner_read
  ON public.idea_classification_results;
CREATE POLICY idea_classification_current_owner_or_group_read
  ON public.idea_classification_results FOR SELECT TO authenticated
  USING (
    public.get_own_idea_classification_status(
      idea_classification_results.idea_id
    )->>'current_classification_id' =
      idea_classification_results.classification_id::text
    OR public.get_group_idea_classification_status(
      idea_classification_results.idea_id
    )->>'current_classification_id' =
      idea_classification_results.classification_id::text
  );
CREATE POLICY official_points_ledger_owner_or_group_read
  ON public.official_points_ledger FOR SELECT TO authenticated
  USING (
    (group_id IS NULL AND user_id = javaneh_private.auth_uid())
    OR (
      group_id IS NOT NULL
      AND public.is_accepted_group_member(
        group_id, javaneh_private.auth_uid()
      )
    )
  );

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMENT ON TABLE public.participant_groups IS
  'Shared participant identities; the owner is the only member who may submit or delete group ideas.';
COMMENT ON TABLE public.participant_group_invitations IS
  'Email-bound invitations expire after seven days and can only be accepted by the signed-in matching email.';
COMMENT ON COLUMN public.ideas.group_id IS
  'Null for individual ideas; otherwise identifies the shared group owner and quota.';
COMMENT ON COLUMN public.official_points_ledger.group_id IS
  'Set by a trusted trigger from the associated idea; group points are not member points.';

COMMIT;
