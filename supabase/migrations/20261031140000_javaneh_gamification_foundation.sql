BEGIN;

DO $$
BEGIN
  IF NOT pg_catalog.pg_has_role('postgres', 'javaneh_identity_executor', 'MEMBER')
     OR pg_catalog.pg_has_role('anon', 'javaneh_identity_executor', 'MEMBER')
     OR pg_catalog.pg_has_role('authenticated', 'javaneh_identity_executor', 'MEMBER')
     OR pg_catalog.pg_has_role('service_role', 'javaneh_identity_executor', 'MEMBER')
     OR pg_catalog.pg_has_role('authenticator', 'javaneh_identity_executor', 'MEMBER') THEN
    RAISE EXCEPTION 'The existing identity executor prerequisite is missing or unsafe'
      USING ERRCODE = '42501';
  END IF;
END
$$;

CREATE TABLE public.scoring_configurations (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  competition_id uuid,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

CREATE TABLE public.scoring_configuration_versions (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  configuration_id uuid NOT NULL
    REFERENCES public.scoring_configurations(id) ON DELETE RESTRICT,
  version_number integer NOT NULL CHECK (version_number > 0),
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'approved', 'active', 'retired')),
  approved_by uuid,
  approved_at timestamptz,
  activated_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT scoring_configuration_versions_number_key
    UNIQUE (configuration_id, version_number),
  CONSTRAINT scoring_configuration_versions_state_metadata
    CHECK (
      (status = 'draft'
        AND approved_by IS NULL AND approved_at IS NULL AND activated_at IS NULL)
      OR (status = 'approved'
        AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND activated_at IS NULL)
      OR (status IN ('active', 'retired')
        AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND activated_at IS NOT NULL)
    )
);

CREATE TABLE public.scoring_milestone_catalog (
  configuration_version_id uuid NOT NULL
    REFERENCES public.scoring_configuration_versions(id) ON DELETE RESTRICT,
  milestone_key text NOT NULL CHECK (
    milestone_key ~ '^[a-z0-9][a-z0-9._-]{0,127}$'
  ),
  stage_number smallint CHECK (stage_number BETWEEN 1 AND 7),
  definition text,
  point_value integer CHECK (point_value IS NULL OR point_value > 0),
  is_active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (configuration_version_id, milestone_key),
  CONSTRAINT scoring_milestone_catalog_active_is_configured
    CHECK (
      NOT is_active
      OR (
        definition IS NOT NULL
        AND pg_catalog.length(pg_catalog.btrim(definition)) > 0
        AND point_value IS NOT NULL
      )
    )
);

CREATE TABLE public.official_points_ledger (
  entry_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idempotency_key uuid NOT NULL UNIQUE,
  user_id uuid NOT NULL,
  idea_id uuid NOT NULL,
  configuration_version_id uuid NOT NULL,
  milestone_key text NOT NULL,
  stage_number smallint CHECK (stage_number BETWEEN 1 AND 7),
  entry_kind text NOT NULL CHECK (entry_kind IN ('award', 'compensation')),
  points integer NOT NULL CHECK (points <> 0),
  original_entry_id uuid
    REFERENCES public.official_points_ledger(entry_id) ON DELETE RESTRICT,
  source text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(source)) > 0),
  source_reference uuid,
  reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(reason)) > 0),
  recorded_by uuid NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT official_points_ledger_catalog_fk
    FOREIGN KEY (configuration_version_id, milestone_key)
    REFERENCES public.scoring_milestone_catalog(
      configuration_version_id, milestone_key
    ) ON DELETE RESTRICT,
  CONSTRAINT official_points_ledger_entry_shape
    CHECK (
      (entry_kind = 'award' AND points > 0 AND original_entry_id IS NULL)
      OR (entry_kind = 'compensation' AND original_entry_id IS NOT NULL)
    )
);

CREATE INDEX official_points_ledger_user_history_idx
  ON public.official_points_ledger (user_id, recorded_at DESC, entry_id);
CREATE INDEX official_points_ledger_idea_idx
  ON public.official_points_ledger (idea_id, recorded_at DESC);

ALTER TABLE public.scoring_configurations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_configurations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_configuration_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_configuration_versions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_milestone_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_milestone_catalog FORCE ROW LEVEL SECURITY;
ALTER TABLE public.official_points_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.official_points_ledger FORCE ROW LEVEL SECURITY;

CREATE POLICY scoring_configurations_executor_all
  ON public.scoring_configurations FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY scoring_configuration_versions_executor_all
  ON public.scoring_configuration_versions FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY scoring_milestone_catalog_executor_all
  ON public.scoring_milestone_catalog FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY official_points_ledger_executor_all
  ON public.official_points_ledger FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY official_points_ledger_owner_read
  ON public.official_points_ledger FOR SELECT TO authenticated
  USING (user_id = javaneh_private.current_uid());

REVOKE ALL ON TABLE
  public.scoring_configurations,
  public.scoring_configuration_versions,
  public.scoring_milestone_catalog,
  public.official_points_ledger
  FROM PUBLIC, anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.scoring_configurations,
  public.scoring_configuration_versions,
  public.scoring_milestone_catalog
  TO javaneh_identity_executor;
GRANT SELECT, INSERT ON TABLE public.official_points_ledger
  TO javaneh_identity_executor;
GRANT SELECT ON TABLE public.official_points_ledger TO authenticated;

CREATE FUNCTION public.guard_scoring_configuration_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'Approved scoring configuration versions are immutable'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.configuration_id IS DISTINCT FROM OLD.configuration_id
     OR NEW.version_number IS DISTINCT FROM OLD.version_number
     OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'Scoring configuration version identity is immutable'
      USING ERRCODE = '42501';
  END IF;

  IF OLD.status = 'draft' AND NEW.status = 'approved' THEN
    IF NEW.approved_by IS NULL OR NEW.approved_at IS NULL
       OR NEW.activated_at IS NOT NULL THEN
      RAISE EXCEPTION 'Approval actor and timestamp are required'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'approved' AND NEW.status = 'active' THEN
    IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
       OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
       OR NEW.activated_at IS NULL THEN
      RAISE EXCEPTION 'Activation must preserve approval and record its timestamp'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.status = 'active' AND NEW.status = 'retired' THEN
    IF NEW.approved_by IS DISTINCT FROM OLD.approved_by
       OR NEW.approved_at IS DISTINCT FROM OLD.approved_at
       OR NEW.activated_at IS DISTINCT FROM OLD.activated_at THEN
      RAISE EXCEPTION 'Retirement cannot modify approved scoring rules'
        USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'Invalid or immutable scoring configuration transition'
    USING ERRCODE = '42501';
END
$function$;
REVOKE ALL ON FUNCTION public.guard_scoring_configuration_update()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER scoring_configuration_versions_guard
  BEFORE UPDATE OR DELETE ON public.scoring_configuration_versions
  FOR EACH ROW EXECUTE FUNCTION public.guard_scoring_configuration_update();

CREATE FUNCTION public.guard_scoring_configuration_identity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  RAISE EXCEPTION 'Scoring configuration identity is immutable'
    USING ERRCODE = '42501';
END
$function$;
REVOKE ALL ON FUNCTION public.guard_scoring_configuration_identity()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER scoring_configurations_immutable
  BEFORE UPDATE OR DELETE ON public.scoring_configurations
  FOR EACH ROW EXECUTE FUNCTION public.guard_scoring_configuration_identity();

CREATE FUNCTION public.guard_scoring_milestone_catalog()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_version_status text;
  v_version_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_version_id := OLD.configuration_version_id;
  ELSE
    v_version_id := NEW.configuration_version_id;
  END IF;

  SELECT v.status INTO v_version_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = v_version_id;

  IF v_version_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'Milestone catalog can only change in a draft version'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'UPDATE'
     AND (NEW.configuration_version_id IS DISTINCT FROM OLD.configuration_version_id
       OR NEW.milestone_key IS DISTINCT FROM OLD.milestone_key
       OR NEW.created_at IS DISTINCT FROM OLD.created_at) THEN
    RAISE EXCEPTION 'Milestone identifiers are stable within a configuration version'
      USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_scoring_milestone_catalog()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER scoring_milestone_catalog_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.scoring_milestone_catalog
  FOR EACH ROW EXECUTE FUNCTION public.guard_scoring_milestone_catalog();

CREATE FUNCTION public.guard_official_points_ledger()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_version_status text;
  v_milestone public.scoring_milestone_catalog%ROWTYPE;
  v_original public.official_points_ledger%ROWTYPE;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'Official points ledger entries are append-only'
      USING ERRCODE = '42501';
  END IF;

  SELECT v.status INTO v_version_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = NEW.configuration_version_id;
  SELECT m.* INTO v_milestone
    FROM public.scoring_milestone_catalog AS m
    WHERE m.configuration_version_id = NEW.configuration_version_id
      AND m.milestone_key = NEW.milestone_key;

  IF NEW.entry_kind = 'award' THEN
    IF v_version_status IS DISTINCT FROM 'active'
       OR NOT FOUND
       OR NOT v_milestone.is_active
       OR NEW.points IS DISTINCT FROM v_milestone.point_value
       OR NEW.stage_number IS DISTINCT FROM v_milestone.stage_number THEN
      RAISE EXCEPTION 'Award does not match an active approved milestone'
        USING ERRCODE = '42501';
    END IF;
  ELSE
    IF NEW.original_entry_id IS NULL THEN
      RAISE EXCEPTION 'Compensation must reference an original award'
        USING ERRCODE = '23514';
    END IF;

    SELECT l.* INTO v_original
      FROM public.official_points_ledger AS l
      WHERE l.entry_id = NEW.original_entry_id;
    IF NOT FOUND
       OR v_original.entry_kind <> 'award'
       OR v_original.user_id IS DISTINCT FROM NEW.user_id
       OR v_original.idea_id IS DISTINCT FROM NEW.idea_id
       OR v_original.configuration_version_id IS DISTINCT FROM NEW.configuration_version_id
       OR v_original.milestone_key IS DISTINCT FROM NEW.milestone_key
       OR v_original.stage_number IS DISTINCT FROM NEW.stage_number THEN
      RAISE EXCEPTION 'Compensation must match its original award'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_official_points_ledger()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER official_points_ledger_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.official_points_ledger
  FOR EACH ROW EXECUTE FUNCTION public.guard_official_points_ledger();

CREATE VIEW public.user_point_totals WITH (security_invoker = true) AS
SELECT
  l.user_id,
  COALESCE(
    pg_catalog.sum(l.points) FILTER (WHERE l.entry_kind = 'award'), 0
  )::bigint AS awarded_points,
  COALESCE(
    pg_catalog.sum(l.points) FILTER (WHERE l.entry_kind = 'compensation'), 0
  )::bigint AS compensating_points,
  pg_catalog.sum(l.points)::bigint AS net_points
FROM public.official_points_ledger AS l
GROUP BY l.user_id;

CREATE VIEW public.user_points_by_stage WITH (security_invoker = true) AS
SELECT
  l.user_id,
  l.idea_id,
  l.configuration_version_id,
  l.stage_number,
  pg_catalog.sum(l.points)::bigint AS net_points
FROM public.official_points_ledger AS l
GROUP BY l.user_id, l.idea_id, l.configuration_version_id, l.stage_number;

CREATE VIEW public.user_points_by_milestone WITH (security_invoker = true) AS
SELECT
  l.user_id,
  l.idea_id,
  l.configuration_version_id,
  l.milestone_key,
  pg_catalog.sum(l.points)::bigint AS net_points
FROM public.official_points_ledger AS l
GROUP BY l.user_id, l.idea_id, l.configuration_version_id, l.milestone_key;

REVOKE ALL ON TABLE
  public.user_point_totals,
  public.user_points_by_stage,
  public.user_points_by_milestone
  FROM PUBLIC, anon, service_role;
GRANT SELECT ON TABLE
  public.user_point_totals,
  public.user_points_by_stage,
  public.user_points_by_milestone
  TO authenticated;

COMMENT ON TABLE public.scoring_configurations IS
  'Scoring configuration identities; competition_id is an opaque future link because no competition model exists.';
COMMENT ON TABLE public.scoring_configuration_versions IS
  'Versioned scoring configuration; versions default to draft and require an explicit approval transition before activation.';
COMMENT ON TABLE public.scoring_milestone_catalog IS
  'Versioned milestone catalog. No product milestones or point values are seeded.';
COMMENT ON TABLE public.official_points_ledger IS
  'Append-only official score history. User and idea IDs intentionally have no cascading foreign keys.';

COMMIT;