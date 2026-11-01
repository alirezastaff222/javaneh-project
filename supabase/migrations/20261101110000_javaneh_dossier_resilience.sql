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

ALTER TABLE public.ideas
  ADD COLUMN submitted_at timestamptz;

UPDATE public.ideas
  SET submitted_at = updated_at
  WHERE status = 'submitted';

ALTER TABLE public.ideas
  ADD CONSTRAINT ideas_submission_timestamp_consistent
  CHECK ((status = 'submitted') = (submitted_at IS NOT NULL));

CREATE TABLE public.idea_dossier_versions (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL
    REFERENCES public.ideas(id) ON DELETE CASCADE,
  revision integer NOT NULL CHECK (revision > 0),
  dossier jsonb NOT NULL
    CHECK (
      pg_catalog.jsonb_typeof(dossier) = 'object'
      AND pg_catalog.jsonb_typeof(dossier->'stages') = 'array'
    ),
  actor_id uuid NOT NULL
    REFERENCES auth.users(id) ON DELETE CASCADE,
  request_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT idea_dossier_versions_revision_key
    UNIQUE (idea_id, revision),
  CONSTRAINT idea_dossier_versions_request_key
    UNIQUE (idea_id, request_id)
);

CREATE TABLE public.idea_dossier_edit_requests (
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
  CONSTRAINT idea_dossier_edit_requests_owner_request_key
    UNIQUE (owner_id, request_id),
  CONSTRAINT idea_dossier_edit_requests_idea_owner_fk
    FOREIGN KEY (idea_id, owner_id)
    REFERENCES public.ideas(id, owner_id) ON DELETE CASCADE
);

ALTER TABLE public.idea_dossier_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_dossier_versions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.idea_dossier_edit_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_dossier_edit_requests FORCE ROW LEVEL SECURITY;

CREATE POLICY idea_dossier_versions_executor_all
  ON public.idea_dossier_versions FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY idea_dossier_edit_requests_executor_all
  ON public.idea_dossier_edit_requests FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE
  public.idea_dossier_versions,
  public.idea_dossier_edit_requests
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON TABLE
  public.idea_dossier_versions,
  public.idea_dossier_edit_requests
  TO javaneh_identity_executor;

CREATE FUNCTION public.reject_idea_dossier_version_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  RAISE EXCEPTION 'Completed-dossier snapshots are immutable'
    USING ERRCODE = '42501';
END
$function$;
REVOKE ALL ON FUNCTION public.reject_idea_dossier_version_update()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER idea_dossier_versions_immutable
  BEFORE UPDATE ON public.idea_dossier_versions
  FOR EACH ROW EXECUTE FUNCTION public.reject_idea_dossier_version_update();

CREATE OR REPLACE FUNCTION public.submit_idea(
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
  v_owner_id uuid;
  v_idea public.ideas%ROWTYPE;
  v_existing_idea_id uuid;
  v_stage_count integer;
  v_submitted_at timestamptz;
BEGIN
  v_owner_id := javaneh_private.current_uid();
  IF v_owner_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_idea_id IS NULL OR p_request_id IS NULL
     OR p_expected_revision IS NULL OR p_expected_revision < 1 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'This operation requires READ COMMITTED isolation'
      USING ERRCODE = '25001';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:idea-submission:v1:' || v_owner_id::text || ':'
        || p_request_id::text,
      0
    )
  );

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;
  IF v_idea.status = 'submitted' THEN
    IF v_idea.submission_request_id = p_request_id
       AND v_idea.submission_expected_revision = p_expected_revision THEN
      RETURN pg_catalog.jsonb_build_object(
        'outcome', 'replayed',
        'idea_id', v_idea.id,
        'revision', v_idea.revision,
        'current_step', v_idea.current_step,
        'submitted_at', v_idea.submitted_at
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_submitted',
      'idea_id', v_idea.id,
      'current_step', v_idea.current_step,
      'submitted_at', v_idea.submitted_at
    );
  END IF;

  SELECT idea.id INTO v_existing_idea_id
    FROM public.ideas AS idea
    WHERE idea.owner_id = v_owner_id
      AND idea.submission_request_id = p_request_id
      AND idea.id <> p_idea_id;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'idempotency_key_reuse');
  END IF;

  IF v_idea.status NOT IN ('draft', 'in_progress') THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF v_idea.revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_revision',
      'current_revision', v_idea.revision
    );
  END IF;

  SELECT pg_catalog.count(*) INTO v_stage_count
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id;
  IF v_stage_count <> 7 OR EXISTS (
    SELECT 1
      FROM public.idea_stages AS stage
      WHERE stage.idea_id = p_idea_id
        AND (
          (stage.stage_number BETWEEN 1 AND 6
            AND stage.status <> 'confirmed')
          OR (stage.stage_number = 7
            AND (stage.status <> 'locked' OR stage.data <> '{}'::jsonb))
        )
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'incomplete');
  END IF;

  v_submitted_at := pg_catalog.clock_timestamp();
  UPDATE public.ideas AS idea
    SET status = 'submitted',
        current_step = 7,
        submission_request_id = p_request_id,
        submission_expected_revision = p_expected_revision,
        submitted_at = v_submitted_at
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'submitted',
    'idea_id', p_idea_id,
    'revision', v_idea.revision,
    'current_step', 7,
    'submitted_at', v_submitted_at
  );
END
$function$;
ALTER FUNCTION public.submit_idea(uuid, uuid, integer)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.submit_idea(uuid, uuid, integer)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.submit_idea(uuid, uuid, integer)
  TO authenticated;

CREATE FUNCTION public.edit_submitted_idea(
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
  v_ledger public.idea_dossier_edit_requests%ROWTYPE;
  v_idea public.ideas%ROWTYPE;
  v_item jsonb;
  v_stage_number smallint;
  v_stage_numbers smallint[] := ARRAY[]::smallint[];
  v_current_data jsonb;
  v_now timestamptz;
  v_snapshot jsonb;
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
      'javaneh:dossier-edit:v1:' || v_owner_id::text || ':'
        || p_request_id::text,
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

  SELECT request.* INTO v_ledger
    FROM public.idea_dossier_edit_requests AS request
    WHERE request.owner_id = v_owner_id
      AND request.request_id = p_request_id;
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

  SELECT idea.* INTO v_idea
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
      AND idea.owner_id = v_owner_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
  END IF;

  SELECT request.* INTO v_ledger
    FROM public.idea_dossier_edit_requests AS request
    WHERE request.owner_id = v_owner_id
      AND request.request_id = p_request_id;
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

  v_now := pg_catalog.clock_timestamp();
  IF v_idea.status <> 'submitted' OR v_idea.submitted_at IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  IF v_now >= v_idea.submitted_at + INTERVAL '168 hours' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'editing_window_expired');
  END IF;
  IF v_idea.revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_revision',
      'current_revision', v_idea.revision
    );
  END IF;

  FOR v_item IN
    SELECT entry.value
      FROM pg_catalog.jsonb_array_elements(p_stage_updates) AS entry(value)
  LOOP
    IF pg_catalog.jsonb_typeof(v_item) IS DISTINCT FROM 'object'
       OR (
         SELECT pg_catalog.count(*)
           FROM pg_catalog.jsonb_object_keys(v_item)
       ) <> 2
       OR NOT (v_item ?& ARRAY['stage_number', 'data'])
       OR pg_catalog.jsonb_typeof(v_item->'stage_number') IS DISTINCT FROM 'number'
       OR pg_catalog.jsonb_typeof(v_item->'data') IS DISTINCT FROM 'object'
       OR (
         (v_item->'data') ? 'content'
         AND pg_catalog.jsonb_typeof(v_item->'data'->'content')
           IS DISTINCT FROM 'string'
       )
       OR (v_item->>'stage_number') !~ '^[1-6]$' THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
    END IF;
    v_stage_number := (v_item->>'stage_number')::smallint;
    IF v_stage_number = ANY(v_stage_numbers) THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
    END IF;
    v_stage_numbers := pg_catalog.array_append(v_stage_numbers, v_stage_number);
  END LOOP;

  PERFORM stage.stage_number
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = ANY(v_stage_numbers)
    ORDER BY stage.stage_number
    FOR UPDATE;

  SELECT pg_catalog.count(*) INTO v_row_count
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = ANY(v_stage_numbers)
      AND stage.status = 'confirmed';
  IF v_row_count <> pg_catalog.cardinality(v_stage_numbers)
     OR (
       SELECT pg_catalog.count(*)
         FROM public.idea_stages AS stage
         WHERE stage.idea_id = p_idea_id
           AND stage.stage_number BETWEEN 1 AND 6
           AND stage.status = 'confirmed'
     ) <> 6 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  FOREACH v_stage_number IN ARRAY v_stage_numbers LOOP
    SELECT stage.data INTO v_current_data
      FROM public.idea_stages AS stage
      WHERE stage.idea_id = p_idea_id
        AND stage.stage_number = v_stage_number;
    SELECT entry.value->'data' INTO v_item
      FROM pg_catalog.jsonb_array_elements(p_stage_updates) AS entry(value)
      WHERE (entry.value->>'stage_number')::smallint = v_stage_number;
    IF v_current_data IS DISTINCT FROM v_item THEN
      v_changed := true;
    END IF;
  END LOOP;

  IF v_changed THEN
    SELECT pg_catalog.jsonb_build_object(
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
    )
      INTO v_snapshot
      FROM public.idea_stages AS stage
      WHERE stage.idea_id = p_idea_id
        AND stage.stage_number BETWEEN 1 AND 6;

    INSERT INTO public.idea_dossier_versions (
      idea_id, revision, dossier, actor_id, request_id, created_at
    )
    VALUES (
      p_idea_id, v_idea.revision, v_snapshot, v_owner_id, p_request_id, v_now
    );

    FOR v_item IN
      SELECT entry.value
        FROM pg_catalog.jsonb_array_elements(p_stage_updates) AS entry(value)
        ORDER BY (entry.value->>'stage_number')::smallint
    LOOP
      UPDATE public.idea_stages AS stage
        SET data = v_item->'data'
        WHERE stage.idea_id = p_idea_id
          AND stage.stage_number = (v_item->>'stage_number')::smallint
          AND stage.data IS DISTINCT FROM v_item->'data';
    END LOOP;

    UPDATE public.ideas AS idea
      SET revision = idea.revision + 1,
          updated_at = v_now
      WHERE idea.id = p_idea_id
        AND idea.owner_id = v_owner_id
      RETURNING idea.revision INTO v_idea.revision;
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

  INSERT INTO public.idea_dossier_edit_requests (
    id, owner_id, idea_id, request_id, expected_revision,
    payload_fingerprint, result_revision, outcome, completed_at
  )
  VALUES (
    v_ledger.id, v_ledger.owner_id, v_ledger.idea_id, v_ledger.request_id,
    v_ledger.expected_revision, v_ledger.payload_fingerprint,
    v_ledger.result_revision, v_ledger.outcome, v_ledger.completed_at
  );

  RETURN pg_catalog.jsonb_build_object(
    'outcome', v_ledger.outcome,
    'result_revision', v_ledger.result_revision
  );
END
$function$;
ALTER FUNCTION public.edit_submitted_idea(uuid, uuid, integer, jsonb)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.edit_submitted_idea(uuid, uuid, integer, jsonb)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.edit_submitted_idea(uuid, uuid, integer, jsonb)
  TO authenticated;

COMMENT ON TABLE public.idea_dossier_versions IS
  'Immutable pre-edit dossier snapshots, separate from confirmed-stage snapshots; cascades on permanent idea deletion.';
COMMENT ON TABLE public.idea_dossier_edit_requests IS
  'Idempotency ledger for submitted-dossier edits; contains no dossier content.';
COMMENT ON COLUMN public.ideas.submitted_at IS
  'Database-controlled start of the fixed 168-hour participant dossier-editing window.';

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
