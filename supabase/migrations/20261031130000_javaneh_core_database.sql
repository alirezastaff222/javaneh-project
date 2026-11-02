BEGIN;

DO $$
DECLARE
  v_role text;
BEGIN
  FOREACH v_role IN ARRAY ARRAY[
    'javaneh_identity_bridge',
    'javaneh_identity_executor'
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM pg_catalog.pg_roles
      WHERE rolname = v_role
        AND NOT rolsuper
        AND NOT rolcreatedb
        AND NOT rolcreaterole
        AND NOT rolcanlogin
        AND NOT rolinherit
        AND NOT rolbypassrls
    ) THEN
      RAISE EXCEPTION
        'Required internal role % is missing or has unsafe attributes; run the documented supabase_admin prerequisite',
        v_role
        USING ERRCODE = '42501';
    END IF;
  END LOOP;

  IF NOT pg_catalog.pg_has_role('postgres', 'javaneh_identity_bridge', 'MEMBER')
     OR NOT pg_catalog.pg_has_role('postgres', 'javaneh_identity_executor', 'MEMBER') THEN
    RAISE EXCEPTION
      'postgres must have migration-only membership in both internal roles; run the documented supabase_admin prerequisite'
      USING ERRCODE = '42501';
  END IF;

  IF pg_catalog.pg_has_role('anon', 'javaneh_identity_bridge', 'MEMBER')
     OR pg_catalog.pg_has_role('authenticated', 'javaneh_identity_bridge', 'MEMBER')
     OR pg_catalog.pg_has_role('service_role', 'javaneh_identity_bridge', 'MEMBER')
     OR pg_catalog.pg_has_role('authenticator', 'javaneh_identity_bridge', 'MEMBER')
     OR pg_catalog.pg_has_role('anon', 'javaneh_identity_executor', 'MEMBER')
     OR pg_catalog.pg_has_role('authenticated', 'javaneh_identity_executor', 'MEMBER')
     OR pg_catalog.pg_has_role('service_role', 'javaneh_identity_executor', 'MEMBER')
     OR pg_catalog.pg_has_role('authenticator', 'javaneh_identity_executor', 'MEMBER') THEN
    RAISE EXCEPTION 'Client roles must not be members of internal roles'
      USING ERRCODE = '42501';
  END IF;

  IF NOT pg_catalog.has_schema_privilege(
       'postgres', 'auth', 'USAGE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'postgres', 'auth.uid()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION
      'postgres lacks the Auth privileges required by the narrow identity wrapper; run the documented prerequisite'
      USING ERRCODE = '42501';
  END IF;

  IF NOT pg_catalog.has_table_privilege('postgres', 'auth.users', 'TRIGGER') THEN
    RAISE EXCEPTION
      'postgres cannot install the auth.users trigger; run the documented supabase_admin prerequisite'
      USING ERRCODE = '42501';
  END IF;

  IF NOT pg_catalog.has_table_privilege('postgres', 'auth.users', 'REFERENCES') THEN
    RAISE EXCEPTION
      'postgres cannot create the auth.users foreign key; run the documented supabase_admin prerequisite'
      USING ERRCODE = '42501';
  END IF;

  IF NOT pg_catalog.has_schema_privilege('postgres', 'public', 'CREATE') THEN
    RAISE EXCEPTION
      'postgres cannot create the public objects required by this migration; run the documented supabase_admin prerequisite'
      USING ERRCODE = '42501';
  END IF;

  IF pg_catalog.to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION 'Required SHA-256 function extensions.digest(bytea,text) is unavailable'
      USING ERRCODE = '42883';
  END IF;

  IF NOT pg_catalog.has_schema_privilege(
       'javaneh_identity_executor', 'extensions', 'USAGE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'javaneh_identity_executor', 'extensions.digest(bytea,text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION
      'The executor lacks required SHA-256 privileges; run the documented supabase_admin prerequisite'
      USING ERRCODE = '42501';
  END IF;
END
$$;

CREATE SCHEMA javaneh_private AUTHORIZATION javaneh_identity_bridge;
REVOKE ALL ON SCHEMA javaneh_private FROM PUBLIC, anon, service_role;
GRANT USAGE ON SCHEMA javaneh_private
  TO authenticated, javaneh_identity_executor;
GRANT USAGE ON SCHEMA public TO authenticated, javaneh_identity_executor;
GRANT CREATE ON SCHEMA public TO javaneh_identity_executor;

SET ROLE javaneh_identity_bridge;

CREATE FUNCTION javaneh_private.auth_uid()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT auth.uid()
$function$;

CREATE FUNCTION javaneh_private.current_uid()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT javaneh_private.auth_uid()
$function$;

RESET ROLE;

ALTER FUNCTION javaneh_private.auth_uid() OWNER TO postgres;
ALTER FUNCTION javaneh_private.current_uid() OWNER TO javaneh_identity_bridge;
REVOKE ALL ON FUNCTION javaneh_private.auth_uid()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION javaneh_private.auth_uid()
  TO javaneh_identity_bridge;
SET ROLE javaneh_identity_bridge;
REVOKE ALL ON FUNCTION javaneh_private.current_uid()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION javaneh_private.current_uid()
  TO authenticated, javaneh_identity_executor;
RESET ROLE;

CREATE TABLE public.ideas (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  owner_id uuid NOT NULL
    REFERENCES auth.users(id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'in_progress', 'submitted')),
  revision integer NOT NULL DEFAULT 1 CHECK (revision > 0),
  creation_request_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT ideas_updated_at_not_before_created_at
    CHECK (updated_at >= created_at),
  CONSTRAINT ideas_owner_creation_request_key
    UNIQUE (owner_id, creation_request_id),
  CONSTRAINT ideas_id_owner_key
    UNIQUE (id, owner_id)
);

CREATE INDEX ideas_owner_created_at_idx
  ON public.ideas (owner_id, created_at DESC);

CREATE TABLE public.idea_stages (
  idea_id uuid NOT NULL
    REFERENCES public.ideas(id) ON DELETE CASCADE,
  stage_number smallint NOT NULL CHECK (stage_number BETWEEN 1 AND 7),
  data jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (pg_catalog.jsonb_typeof(data) = 'object'),
  status text NOT NULL
    CHECK (status IN (
      'not_started',
      'in_progress',
      'pending_confirmation',
      'confirmed',
      'needs_revision',
      'locked'
    )),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  confirmed_at timestamptz,
  PRIMARY KEY (idea_id, stage_number),
  CONSTRAINT idea_stages_confirmation_timestamp_consistent
    CHECK ((status = 'confirmed') = (confirmed_at IS NOT NULL)),
  CONSTRAINT idea_stage_seven_remains_locked
    CHECK (
      stage_number <> 7
      OR (status = 'locked' AND data = '{}'::jsonb AND confirmed_at IS NULL)
    ),
  CONSTRAINT idea_stages_updated_at_not_before_created_at
    CHECK (updated_at >= created_at)
);

CREATE TABLE public.idea_stage_confirmed_versions (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL,
  stage_number smallint NOT NULL CHECK (stage_number BETWEEN 1 AND 6),
  version_number integer NOT NULL CHECK (version_number > 0),
  data jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(data) = 'object'),
  confirmed_at timestamptz NOT NULL,
  superseded_at timestamptz NOT NULL,
  superseded_by uuid NOT NULL,
  CONSTRAINT idea_stage_confirmed_versions_stage_fk
    FOREIGN KEY (idea_id, stage_number)
    REFERENCES public.idea_stages(idea_id, stage_number) ON DELETE CASCADE,
  CONSTRAINT idea_stage_confirmed_versions_number_key
    UNIQUE (idea_id, stage_number, version_number),
  CONSTRAINT idea_stage_confirmed_versions_time_order
    CHECK (superseded_at >= confirmed_at)
);

CREATE TABLE public.idea_deletion_audit (
  deleted_idea_id uuid PRIMARY KEY,
  owner_id uuid NOT NULL,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  creation_request_id uuid NOT NULL,
  deleted_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  operation text NOT NULL CHECK (
    operation IN ('participant_delete', 'account_cascade')
  ),
  reason_code text NOT NULL CHECK (
    reason_code IN (
      'participant_requested_deletion',
      'account_deletion_cascade'
    )
  ),
  CONSTRAINT idea_deletion_audit_reason_matches_operation
    CHECK (
      (operation = 'participant_delete'
        AND reason_code = 'participant_requested_deletion')
      OR
      (operation = 'account_cascade'
        AND reason_code = 'account_deletion_cascade')
    ),
  CONSTRAINT idea_deletion_audit_owner_creation_request_key
    UNIQUE (owner_id, creation_request_id)
);

CREATE TABLE public.idea_save_requests (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  owner_id uuid NOT NULL,
  idea_id uuid NOT NULL,
  request_id uuid NOT NULL,
  expected_revision integer NOT NULL CHECK (expected_revision > 0),
  payload_fingerprint bytea NOT NULL
    CHECK (pg_catalog.octet_length(payload_fingerprint) = 32),
  result_revision integer NOT NULL CHECK (result_revision > 0),
  outcome text NOT NULL CHECK (outcome IN ('applied', 'no_op')),
  completed_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT idea_save_requests_owner_request_key
    UNIQUE (owner_id, request_id),
  CONSTRAINT idea_save_requests_idea_owner_fk
    FOREIGN KEY (idea_id, owner_id)
    REFERENCES public.ideas(id, owner_id) ON DELETE CASCADE
);

CREATE INDEX idea_save_requests_idea_owner_idx
  ON public.idea_save_requests (idea_id, owner_id);

ALTER TABLE public.ideas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ideas FORCE ROW LEVEL SECURITY;
ALTER TABLE public.idea_stages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_stages FORCE ROW LEVEL SECURITY;
ALTER TABLE public.idea_stage_confirmed_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_stage_confirmed_versions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.idea_deletion_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_deletion_audit FORCE ROW LEVEL SECURITY;
ALTER TABLE public.idea_save_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_save_requests FORCE ROW LEVEL SECURITY;

CREATE POLICY ideas_owner_read
  ON public.ideas FOR SELECT TO authenticated
  USING (owner_id = javaneh_private.current_uid());
CREATE POLICY ideas_executor_all
  ON public.ideas FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

CREATE POLICY idea_stages_owner_read
  ON public.idea_stages FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
    FROM public.ideas AS i
    WHERE i.id = idea_stages.idea_id
      AND i.owner_id = javaneh_private.current_uid()
  ));
CREATE POLICY idea_stages_executor_all
  ON public.idea_stages FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

CREATE POLICY idea_stage_versions_executor_all
  ON public.idea_stage_confirmed_versions FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

CREATE POLICY idea_deletion_audit_executor_read
  ON public.idea_deletion_audit FOR SELECT TO javaneh_identity_executor
  USING (true);
CREATE POLICY idea_deletion_audit_executor_insert
  ON public.idea_deletion_audit FOR INSERT TO javaneh_identity_executor
  WITH CHECK (true);

CREATE POLICY idea_save_requests_executor_all
  ON public.idea_save_requests FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE
  public.ideas,
  public.idea_stages,
  public.idea_stage_confirmed_versions,
  public.idea_deletion_audit,
  public.idea_save_requests
  FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT ON TABLE
  public.ideas,
  public.idea_stages
  TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.ideas,
  public.idea_stages
  TO javaneh_identity_executor;
GRANT SELECT, INSERT, DELETE ON TABLE
  public.idea_stage_confirmed_versions,
  public.idea_save_requests
  TO javaneh_identity_executor;
GRANT SELECT, INSERT ON TABLE
  public.idea_deletion_audit
  TO javaneh_identity_executor;

CREATE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  NEW.updated_at := pg_catalog.clock_timestamp();
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.set_updated_at() FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER ideas_set_updated_at
  BEFORE UPDATE ON public.ideas
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER idea_stages_set_updated_at
  BEFORE UPDATE ON public.idea_stages
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE FUNCTION public.reject_confirmed_version_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  RAISE EXCEPTION 'Confirmed-stage snapshots are immutable'
    USING ERRCODE = '42501';
END
$function$;
REVOKE ALL ON FUNCTION public.reject_confirmed_version_update()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER idea_stage_confirmed_versions_immutable
  BEFORE UPDATE ON public.idea_stage_confirmed_versions
  FOR EACH ROW EXECUTE FUNCTION public.reject_confirmed_version_update();

CREATE FUNCTION public.assert_idea_has_seven_stages()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_stage_count integer;
BEGIN
  SELECT pg_catalog.count(*)
    INTO v_stage_count
    FROM public.idea_stages AS s
    WHERE s.idea_id = NEW.id;

  IF v_stage_count <> 7 THEN
    RAISE EXCEPTION 'An idea must have exactly seven stage rows'
      USING ERRCODE = '23514';
  END IF;

  RETURN NULL;
END
$function$;
REVOKE ALL ON FUNCTION public.assert_idea_has_seven_stages()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE CONSTRAINT TRIGGER ideas_require_seven_stages
  AFTER INSERT ON public.ideas
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.assert_idea_has_seven_stages();

CREATE FUNCTION public.create_idea(p_request_id uuid)
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

  SELECT i.id INTO v_existing_id
    FROM public.ideas AS i
    WHERE i.owner_id = v_owner_id
      AND i.creation_request_id = p_request_id;
  IF v_existing_id IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_exists',
      'idea_id', v_existing_id
    );
  END IF;

  SELECT a.deleted_idea_id INTO v_existing_id
    FROM public.idea_deletion_audit AS a
    WHERE a.owner_id = v_owner_id
      AND a.creation_request_id = p_request_id;
  IF v_existing_id IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_deleted');
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas AS i
    WHERE i.owner_id = v_owner_id;
  IF v_count >= 3 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'quota_exceeded');
  END IF;

  INSERT INTO public.ideas (owner_id, creation_request_id)
    VALUES (v_owner_id, p_request_id)
    RETURNING id INTO v_idea_id;

  FOR v_stage IN 1..7 LOOP
    INSERT INTO public.idea_stages (idea_id, stage_number, data, status)
    VALUES (
      v_idea_id,
      v_stage,
      '{}'::jsonb,
      CASE WHEN v_stage = 1 THEN 'in_progress' ELSE 'locked' END
    );
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'created',
    'idea_id', v_idea_id,
    'revision', 1
  );
END
$function$;
ALTER FUNCTION public.create_idea(uuid) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.create_idea(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_idea(uuid) TO authenticated;

CREATE FUNCTION public.save_idea_content(
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
  v_owner_id uuid;
  v_fingerprint bytea;
  v_envelope jsonb;
  v_ledger public.idea_save_requests%ROWTYPE;
  v_idea public.ideas%ROWTYPE;
  v_item jsonb;
  v_stage_number smallint;
  v_stage_numbers smallint[] := ARRAY[]::smallint[];
  v_stage_status text;
  v_old_data jsonb;
  v_now timestamptz;
  v_changed boolean := false;
  v_row_count integer;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_request_id IS NULL
     OR p_expected_revision IS NULL OR p_expected_revision < 1
     OR p_stage_updates IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;
  IF pg_catalog.jsonb_typeof(p_stage_updates) <> 'array' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:save-request:v1:' || v_owner_id::text || ':' || p_request_id::text,
      0
    )
  );

  v_envelope := pg_catalog.jsonb_build_object(
    'canonicalization_version', 1,
    'owner_id', v_owner_id,
    'idea_id', p_idea_id,
    'request_id', p_request_id,
    'expected_revision', p_expected_revision,
    'stage_updates', p_stage_updates
  );
  v_fingerprint := extensions.digest(
    pg_catalog.convert_to(v_envelope::text, 'UTF8'),
    'sha256'
  );

  SELECT r.* INTO v_ledger
    FROM public.idea_save_requests AS r
    WHERE r.owner_id = v_owner_id
      AND r.request_id = p_request_id;
  IF FOUND THEN
    IF v_ledger.payload_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'idempotency_key_reuse');
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'replayed',
      'original_outcome', v_ledger.outcome,
      'result_revision', v_ledger.result_revision
    );
  END IF;

  SELECT i.* INTO v_idea
    FROM public.ideas AS i
    WHERE i.id = p_idea_id
      AND i.owner_id = v_owner_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;

  SELECT r.* INTO v_ledger
    FROM public.idea_save_requests AS r
    WHERE r.owner_id = v_owner_id
      AND r.request_id = p_request_id;
  IF FOUND THEN
    IF v_ledger.payload_fingerprint IS DISTINCT FROM v_fingerprint THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'idempotency_key_reuse');
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'replayed',
      'original_outcome', v_ledger.outcome,
      'result_revision', v_ledger.result_revision
    );
  END IF;

  IF v_idea.status = 'submitted' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF v_idea.revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_revision',
      'current_revision', v_idea.revision
    );
  END IF;

  FOR v_item IN
    SELECT e.value
      FROM pg_catalog.jsonb_array_elements(p_stage_updates) AS e(value)
  LOOP
    IF pg_catalog.jsonb_typeof(v_item) IS DISTINCT FROM 'object' THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
    END IF;
    IF (
      SELECT pg_catalog.count(*)
      FROM pg_catalog.jsonb_object_keys(v_item)
    ) <> 2 OR NOT (v_item ?& ARRAY['stage_number', 'data']) THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
    END IF;
    IF pg_catalog.jsonb_typeof(v_item->'stage_number') IS DISTINCT FROM 'number'
       OR pg_catalog.jsonb_typeof(v_item->'data') IS DISTINCT FROM 'object'
       OR (v_item->>'stage_number') !~ '^[1-7]$' THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
    END IF;

    v_stage_number := (v_item->>'stage_number')::smallint;
    IF v_stage_number = 7 THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
    END IF;
    IF v_stage_number = ANY(v_stage_numbers) THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
    END IF;
    v_stage_numbers := pg_catalog.array_append(v_stage_numbers, v_stage_number);
  END LOOP;

  PERFORM s.stage_number
    FROM public.idea_stages AS s
    WHERE s.idea_id = p_idea_id
      AND s.stage_number = ANY(v_stage_numbers)
    ORDER BY s.stage_number
    FOR UPDATE;

  FOREACH v_stage_number IN ARRAY v_stage_numbers LOOP
    SELECT s.status INTO v_stage_status
      FROM public.idea_stages AS s
      WHERE s.idea_id = p_idea_id
        AND s.stage_number = v_stage_number;
    IF NOT FOUND OR v_stage_status IN ('locked', 'needs_revision') THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
    END IF;
  END LOOP;

  v_now := pg_catalog.clock_timestamp();
  FOR v_item IN
    SELECT e.value
      FROM pg_catalog.jsonb_array_elements(p_stage_updates) AS e(value)
      ORDER BY (e.value->>'stage_number')::smallint
  LOOP
    v_stage_number := (v_item->>'stage_number')::smallint;
    SELECT s.status, s.data INTO v_stage_status, v_old_data
      FROM public.idea_stages AS s
      WHERE s.idea_id = p_idea_id
        AND s.stage_number = v_stage_number;

    IF v_old_data IS DISTINCT FROM v_item->'data' THEN
      v_changed := true;
      IF v_stage_status = 'confirmed' THEN
        INSERT INTO public.idea_stage_confirmed_versions (
          idea_id,
          stage_number,
          version_number,
          data,
          confirmed_at,
          superseded_at,
          superseded_by
        )
        SELECT
          s.idea_id,
          s.stage_number,
          COALESCE((
            SELECT pg_catalog.max(v.version_number)
              FROM public.idea_stage_confirmed_versions AS v
              WHERE v.idea_id = s.idea_id
                AND v.stage_number = s.stage_number
          ), 0) + 1,
          s.data,
          s.confirmed_at,
          v_now,
          v_owner_id
        FROM public.idea_stages AS s
        WHERE s.idea_id = p_idea_id
          AND s.stage_number = v_stage_number;
      END IF;

      UPDATE public.idea_stages AS s
        SET data = v_item->'data',
            status = CASE
              WHEN v_stage_status IN (
                'confirmed', 'not_started', 'pending_confirmation'
              ) THEN 'in_progress'
              ELSE s.status
            END,
            confirmed_at = CASE
              WHEN v_stage_status = 'confirmed' THEN NULL
              ELSE s.confirmed_at
            END,
            updated_at = v_now
        WHERE s.idea_id = p_idea_id
          AND s.stage_number = v_stage_number;
    END IF;
  END LOOP;

  IF v_changed THEN
    UPDATE public.ideas AS i
      SET revision = i.revision + 1,
          status = CASE WHEN i.status = 'draft' THEN 'in_progress' ELSE i.status END,
          updated_at = v_now
      WHERE i.id = p_idea_id
        AND i.owner_id = v_owner_id
      RETURNING i.revision INTO v_idea.revision;
    v_ledger.outcome := 'applied';
  ELSE
    v_ledger.outcome := 'no_op';
  END IF;

  v_ledger.id := pg_catalog.gen_random_uuid();
  v_ledger.owner_id := v_owner_id;
  v_ledger.idea_id := p_idea_id;
  v_ledger.request_id := p_request_id;
  v_ledger.expected_revision := p_expected_revision;
  v_ledger.payload_fingerprint := v_fingerprint;
  v_ledger.result_revision := v_idea.revision;
  v_ledger.completed_at := v_now;

  INSERT INTO public.idea_save_requests (
    id,
    owner_id,
    idea_id,
    request_id,
    expected_revision,
    payload_fingerprint,
    result_revision,
    outcome,
    completed_at
  )
  VALUES (
    v_ledger.id,
    v_ledger.owner_id,
    v_ledger.idea_id,
    v_ledger.request_id,
    v_ledger.expected_revision,
    v_ledger.payload_fingerprint,
    v_ledger.result_revision,
    v_ledger.outcome,
    v_ledger.completed_at
  );

  RETURN pg_catalog.jsonb_build_object(
    'outcome', v_ledger.outcome,
    'result_revision', v_ledger.result_revision
  );
END
$function$;
ALTER FUNCTION public.save_idea_content(uuid, uuid, integer, jsonb)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.save_idea_content(uuid, uuid, integer, jsonb)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.save_idea_content(uuid, uuid, integer, jsonb)
  TO authenticated;

CREATE FUNCTION public.request_idea_stage_confirmation(
  p_idea_id uuid,
  p_stage_number smallint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_stage public.idea_stages%ROWTYPE;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_stage_number IS NULL
     OR p_stage_number < 1 OR p_stage_number > 6 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  SELECT i.* INTO v_idea
    FROM public.ideas AS i
    WHERE i.id = p_idea_id
      AND i.owner_id = v_owner_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;

  SELECT s.* INTO v_stage
    FROM public.idea_stages AS s
    WHERE s.idea_id = p_idea_id
      AND s.stage_number = p_stage_number
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  IF v_stage.status = 'pending_confirmation' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_requested');
  END IF;
  IF v_stage.status <> 'in_progress' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  UPDATE public.idea_stages
    SET status = 'pending_confirmation'
    WHERE idea_id = p_idea_id
      AND stage_number = p_stage_number;
  RETURN pg_catalog.jsonb_build_object('outcome', 'requested');
END
$function$;
ALTER FUNCTION public.request_idea_stage_confirmation(uuid, smallint)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.request_idea_stage_confirmation(uuid, smallint)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.request_idea_stage_confirmation(uuid, smallint)
  TO authenticated;

CREATE FUNCTION public.confirm_idea_stage(
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
  v_owner_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_stage public.idea_stages%ROWTYPE;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_stage_number IS NULL
     OR p_stage_number < 1 OR p_stage_number > 6
     OR p_expected_revision IS NULL OR p_expected_revision < 1 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  SELECT i.* INTO v_idea
    FROM public.ideas AS i
    WHERE i.id = p_idea_id
      AND i.owner_id = v_owner_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  IF v_idea.revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_revision',
      'current_revision', v_idea.revision
    );
  END IF;

  SELECT s.* INTO v_stage
    FROM public.idea_stages AS s
    WHERE s.idea_id = p_idea_id
      AND s.stage_number = p_stage_number
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF v_stage.status = 'confirmed' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_confirmed');
  END IF;
  IF v_stage.status <> 'pending_confirmation' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  UPDATE public.idea_stages
    SET status = 'confirmed',
        confirmed_at = pg_catalog.clock_timestamp()
    WHERE idea_id = p_idea_id
      AND stage_number = p_stage_number;

  IF p_stage_number < 6 THEN
    UPDATE public.idea_stages
      SET status = 'in_progress'
      WHERE idea_id = p_idea_id
        AND stage_number = p_stage_number + 1
        AND status = 'locked';
  END IF;

  RETURN pg_catalog.jsonb_build_object('outcome', 'confirmed');
END
$function$;
ALTER FUNCTION public.confirm_idea_stage(uuid, smallint, integer)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.confirm_idea_stage(uuid, smallint, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_idea_stage(uuid, smallint, integer)
  TO authenticated;

CREATE FUNCTION public.guard_idea_deletion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_path text;
  v_context_idea uuid;
  v_context_owner uuid;
  v_actor uuid;
  v_witness public.idea_deletion_audit%ROWTYPE;
BEGIN
  v_path := pg_catalog.current_setting('javaneh.delete_path', true);
  v_context_owner := NULLIF(
    pg_catalog.current_setting('javaneh.delete_owner_id', true), ''
  )::uuid;

  IF v_path = 'participant_delete' THEN
    v_context_idea := NULLIF(
      pg_catalog.current_setting('javaneh.delete_idea_id', true), ''
    )::uuid;
    v_actor := javaneh_private.current_uid();
    IF v_context_idea IS DISTINCT FROM OLD.id
       OR v_context_owner IS DISTINCT FROM OLD.owner_id
       OR v_actor IS DISTINCT FROM OLD.owner_id
       OR OLD.status NOT IN ('draft', 'in_progress') THEN
      RAISE EXCEPTION 'Unauthorized idea deletion'
        USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.idea_deletion_audit (
      deleted_idea_id,
      owner_id,
      actor_id,
      creation_request_id,
      operation,
      reason_code
    )
    VALUES (
      OLD.id,
      OLD.owner_id,
      v_actor,
      OLD.creation_request_id,
      'participant_delete',
      'participant_requested_deletion'
    );
    RETURN OLD;
  END IF;

  IF v_path = 'account_cascade'
     AND v_context_owner IS NOT DISTINCT FROM OLD.owner_id THEN
    SELECT a.* INTO v_witness
      FROM public.idea_deletion_audit AS a
      WHERE a.deleted_idea_id = OLD.id;
    IF NOT FOUND
       OR v_witness.owner_id IS DISTINCT FROM OLD.owner_id
       OR v_witness.creation_request_id IS DISTINCT FROM OLD.creation_request_id
       OR v_witness.operation <> 'account_cascade'
       OR v_witness.reason_code <> 'account_deletion_cascade'
       OR v_witness.actor_id IS NOT NULL THEN
      RAISE EXCEPTION 'Missing or mismatched account-deletion audit witness'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  RAISE EXCEPTION 'Unmarked idea deletion is not authorized'
    USING ERRCODE = '42501';
END
$function$;
ALTER FUNCTION public.guard_idea_deletion() OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.guard_idea_deletion()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER ideas_require_authorized_deletion
  BEFORE DELETE ON public.ideas
  FOR EACH ROW EXECUTE FUNCTION public.guard_idea_deletion();

CREATE FUNCTION public.delete_own_idea(p_idea_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_status text;
  v_rows integer;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_already_deleted');
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('javaneh:quota:v1:' || v_owner_id::text, 0)
  );

  SELECT i.status INTO v_status
    FROM public.ideas AS i
    WHERE i.id = p_idea_id
      AND i.owner_id = v_owner_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_already_deleted');
  END IF;
  IF v_status NOT IN ('draft', 'in_progress') THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  PERFORM pg_catalog.set_config('javaneh.delete_path', 'participant_delete', true);
  PERFORM pg_catalog.set_config('javaneh.delete_idea_id', p_idea_id::text, true);
  PERFORM pg_catalog.set_config('javaneh.delete_owner_id', v_owner_id::text, true);

  DELETE FROM public.ideas AS i
    WHERE i.id = p_idea_id
      AND i.owner_id = v_owner_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_already_deleted');
  END IF;

  PERFORM pg_catalog.set_config('javaneh.delete_path', '', true);
  PERFORM pg_catalog.set_config('javaneh.delete_idea_id', '', true);
  PERFORM pg_catalog.set_config('javaneh.delete_owner_id', '', true);

  RETURN pg_catalog.jsonb_build_object('outcome', 'deleted');
END
$function$;
ALTER FUNCTION public.delete_own_idea(uuid) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.delete_own_idea(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.delete_own_idea(uuid) TO authenticated;

CREATE FUNCTION public.audit_account_idea_deletions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_idea record;
BEGIN
  FOR v_idea IN
    SELECT i.id, i.owner_id, i.creation_request_id
      FROM public.ideas AS i
      WHERE i.owner_id = OLD.id
      ORDER BY i.id
  LOOP
    INSERT INTO public.idea_deletion_audit (
      deleted_idea_id,
      owner_id,
      actor_id,
      creation_request_id,
      operation,
      reason_code
    )
    VALUES (
      v_idea.id,
      OLD.id,
      NULL,
      v_idea.creation_request_id,
      'account_cascade',
      'account_deletion_cascade'
    );
  END LOOP;

  PERFORM pg_catalog.set_config('javaneh.delete_path', 'account_cascade', true);
  PERFORM pg_catalog.set_config('javaneh.delete_owner_id', OLD.id::text, true);
  PERFORM pg_catalog.set_config('javaneh.delete_idea_id', '', true);
  RETURN OLD;
END
$function$;
ALTER FUNCTION public.audit_account_idea_deletions()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.audit_account_idea_deletions()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER auth_users_audit_idea_deletions
  BEFORE DELETE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.audit_account_idea_deletions();

COMMENT ON TABLE public.idea_deletion_audit IS
  'Content-free permanent deletion evidence; do not add substantive idea data.';
COMMENT ON COLUMN public.idea_stage_confirmed_versions.superseded_by IS
  'Authenticated editor UUID retained without an auth.users foreign key.';

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
