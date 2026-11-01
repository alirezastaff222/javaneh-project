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

ALTER TABLE public.scoring_configurations
  ADD COLUMN configuration_key text;
CREATE UNIQUE INDEX scoring_configurations_key_idx
  ON public.scoring_configurations (configuration_key)
  WHERE configuration_key IS NOT NULL;

ALTER TABLE public.scoring_configuration_versions
  ADD COLUMN development_max_points integer,
  ADD COLUMN human_jury_max_points integer,
  ADD COLUMN overall_max_points integer,
  ADD COLUMN rounding_policy text,
  ADD CONSTRAINT scoring_configuration_versions_policy_totals
    CHECK (
      (
        development_max_points IS NULL
        AND human_jury_max_points IS NULL
        AND overall_max_points IS NULL
        AND rounding_policy IS NULL
      )
      OR (
        development_max_points IS NOT NULL
        AND human_jury_max_points IS NOT NULL
        AND overall_max_points IS NOT NULL
        AND rounding_policy IS NOT NULL
        AND development_max_points > 0
        AND human_jury_max_points > 0
        AND overall_max_points > 0
        AND overall_max_points =
          development_max_points + human_jury_max_points
        AND pg_catalog.length(pg_catalog.btrim(rounding_policy)) > 0
      )
    );

CREATE TABLE public.scoring_stage_catalog (
  configuration_version_id uuid NOT NULL
    REFERENCES public.scoring_configuration_versions(id) ON DELETE RESTRICT,
  stage_number smallint NOT NULL CHECK (stage_number BETWEEN 1 AND 7),
  display_name text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(display_name)) > 0),
  stage_kind text NOT NULL CHECK (stage_kind IN ('development', 'human_jury')),
  maximum_points integer NOT NULL CHECK (maximum_points > 0),
  sort_order smallint NOT NULL CHECK (sort_order BETWEEN 1 AND 7),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (configuration_version_id, stage_number),
  UNIQUE (configuration_version_id, sort_order),
  CONSTRAINT scoring_stage_catalog_kind
    CHECK (
      (stage_number BETWEEN 1 AND 6 AND stage_kind = 'development')
      OR (stage_number = 7 AND stage_kind = 'human_jury')
    )
);

CREATE TABLE public.scoring_evaluation_levels (
  configuration_version_id uuid NOT NULL
    REFERENCES public.scoring_configuration_versions(id) ON DELETE RESTRICT,
  evaluation_level smallint NOT NULL CHECK (evaluation_level BETWEEN 0 AND 4),
  display_label text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(display_label)) > 0),
  multiplier numeric(3, 2) NOT NULL CHECK (multiplier BETWEEN 0 AND 1),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (configuration_version_id, evaluation_level),
  UNIQUE (configuration_version_id, multiplier)
);

CREATE TABLE public.competitions (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  competition_key text NOT NULL UNIQUE CHECK (
    competition_key ~ '^[a-z0-9][a-z0-9._-]{0,127}$'
  ),
  name text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(name)) > 0),
  description text NOT NULL CHECK (
    pg_catalog.length(pg_catalog.btrim(description)) > 0
  ),
  status text NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'active', 'retired')),
  scoring_configuration_version_id uuid NOT NULL UNIQUE
    REFERENCES public.scoring_configuration_versions(id) ON DELETE RESTRICT,
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  modified_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT competitions_updated_at_not_before_created_at
    CHECK (updated_at >= created_at)
);

CREATE TABLE public.competition_events (
  event_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  competition_id uuid NOT NULL
    REFERENCES public.competitions(id) ON DELETE RESTRICT,
  actor_user_id uuid NOT NULL,
  event_type text NOT NULL CHECK (event_type IN ('activated', 'retired')),
  reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(reason)) > 0),
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

ALTER TABLE public.scoring_milestone_catalog
  DROP CONSTRAINT scoring_milestone_catalog_milestone_key_check,
  ADD CONSTRAINT scoring_milestone_catalog_milestone_key_check
    CHECK (
      milestone_key ~ '^[a-z0-9][a-z0-9._-]{0,127}$'
      OR milestone_key ~ '^S[1-6]-M[1-5]$'
    ),
  ADD COLUMN catalog_version text,
  ADD COLUMN display_name text,
  ADD COLUMN participant_description text,
  ADD COLUMN evaluator_description text,
  ADD COLUMN validation_mode text CHECK (
    validation_mode IS NULL OR validation_mode IN ('qualitative', 'objective')
  ),
  ADD COLUMN validation_policy jsonb CHECK (
    validation_policy IS NULL OR pg_catalog.jsonb_typeof(validation_policy) = 'object'
  ),
  ADD COLUMN catalog_status text CHECK (
    catalog_status IS NULL
    OR catalog_status IN ('draft', 'approved', 'active', 'retired')
  ),
  ADD COLUMN sort_order smallint CHECK (sort_order IS NULL OR sort_order > 0),
  ADD COLUMN descriptor_status text CHECK (
    descriptor_status IS NULL OR descriptor_status IN ('pending', 'approved')
  ),
  ADD COLUMN level_0_description text,
  ADD COLUMN level_1_description text,
  ADD COLUMN level_2_description text,
  ADD COLUMN level_3_description text,
  ADD COLUMN level_4_description text,
  ADD COLUMN evidence_guidance text,
  ADD COLUMN evaluator_instructions text,
  ADD COLUMN created_by uuid,
  ADD COLUMN modified_by uuid,
  ADD COLUMN modified_at timestamptz,
  ADD CONSTRAINT scoring_milestone_catalog_policy_shape
    CHECK (
      catalog_version IS NULL
      OR (
        display_name IS NOT NULL
        AND participant_description IS NOT NULL
        AND evaluator_description IS NOT NULL
        AND validation_mode IS NOT NULL
        AND validation_policy IS NOT NULL
        AND catalog_status IS NOT NULL
        AND sort_order IS NOT NULL
        AND descriptor_status IS NOT NULL
        AND ((catalog_status = 'active') = is_active)
        AND point_value IS NOT NULL
      )
    ),
  ADD CONSTRAINT scoring_milestone_catalog_development_stage
    CHECK (
      catalog_version IS NULL
      OR stage_number BETWEEN 1 AND 6
    );

ALTER TABLE public.milestone_validations
  ADD COLUMN evaluation_level smallint CHECK (
    evaluation_level IS NULL OR evaluation_level BETWEEN 0 AND 4
  );

ALTER TABLE public.scoring_stage_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_stage_catalog FORCE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_evaluation_levels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.scoring_evaluation_levels FORCE ROW LEVEL SECURITY;
ALTER TABLE public.competitions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competitions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.competition_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competition_events FORCE ROW LEVEL SECURITY;

CREATE POLICY scoring_stage_catalog_executor_all
  ON public.scoring_stage_catalog FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY scoring_evaluation_levels_executor_all
  ON public.scoring_evaluation_levels FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY competitions_executor_all
  ON public.competitions FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY competition_events_executor_all
  ON public.competition_events FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE
  public.scoring_stage_catalog,
  public.scoring_evaluation_levels,
  public.competitions,
  public.competition_events
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.scoring_stage_catalog,
  public.scoring_evaluation_levels,
  public.competitions
  TO javaneh_identity_executor;
GRANT SELECT, INSERT ON TABLE
  public.competition_events
  TO javaneh_identity_executor;

CREATE FUNCTION public.guard_scoring_policy_definition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_version_id uuid;
  v_version_status text;
BEGIN
  v_version_id := CASE WHEN TG_OP = 'DELETE'
    THEN OLD.configuration_version_id ELSE NEW.configuration_version_id END;
  SELECT v.status INTO v_version_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = v_version_id;
  IF v_version_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'Scoring policy definitions are immutable outside a draft version'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'UPDATE'
     AND (
       NEW.configuration_version_id IS DISTINCT FROM OLD.configuration_version_id
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR (TG_TABLE_NAME = 'scoring_stage_catalog'
           AND (pg_catalog.to_jsonb(NEW)->>'stage_number')
             IS DISTINCT FROM (pg_catalog.to_jsonb(OLD)->>'stage_number'))
       OR (TG_TABLE_NAME = 'scoring_evaluation_levels'
           AND (pg_catalog.to_jsonb(NEW)->>'evaluation_level')
             IS DISTINCT FROM (pg_catalog.to_jsonb(OLD)->>'evaluation_level'))
     ) THEN
    RAISE EXCEPTION 'Scoring policy definition identifiers are immutable'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_scoring_policy_definition()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER scoring_stage_catalog_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.scoring_stage_catalog
  FOR EACH ROW EXECUTE FUNCTION public.guard_scoring_policy_definition();
CREATE TRIGGER scoring_evaluation_levels_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.scoring_evaluation_levels
  FOR EACH ROW EXECUTE FUNCTION public.guard_scoring_policy_definition();

CREATE FUNCTION public.guard_scoring_version_policy_totals()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF OLD.status <> 'draft'
     AND (
       NEW.development_max_points IS DISTINCT FROM OLD.development_max_points
       OR NEW.human_jury_max_points IS DISTINCT FROM OLD.human_jury_max_points
       OR NEW.overall_max_points IS DISTINCT FROM OLD.overall_max_points
       OR NEW.rounding_policy IS DISTINCT FROM OLD.rounding_policy
     ) THEN
    RAISE EXCEPTION 'Approved scoring totals and rounding policy are immutable'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_scoring_version_policy_totals()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER scoring_configuration_version_policy_guard
  BEFORE UPDATE ON public.scoring_configuration_versions
  FOR EACH ROW EXECUTE FUNCTION public.guard_scoring_version_policy_totals();

CREATE OR REPLACE FUNCTION public.guard_scoring_milestone_catalog()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_version_status text;
BEGIN
  SELECT v.status INTO v_version_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = CASE WHEN TG_OP = 'DELETE'
      THEN OLD.configuration_version_id ELSE NEW.configuration_version_id END;

  IF TG_OP = 'DELETE' THEN
    IF v_version_status <> 'draft' THEN
      RAISE EXCEPTION 'Milestone catalog can only change in a draft version'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.configuration_version_id IS DISTINCT FROM OLD.configuration_version_id
       OR NEW.milestone_key IS DISTINCT FROM OLD.milestone_key
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by THEN
      RAISE EXCEPTION 'Milestone identifiers are stable within a configuration version'
        USING ERRCODE = '42501';
    END IF;

    IF v_version_status = 'draft' THEN
      RETURN NEW;
    END IF;

    IF current_user = 'javaneh_identity_executor'
       AND v_version_status = 'approved'
       AND OLD.catalog_version IS NOT NULL
       AND OLD.catalog_status = 'approved'
       AND NEW.catalog_status = 'active'
       AND NEW.is_active
       AND (to_jsonb(NEW) - ARRAY[
         'catalog_status', 'is_active', 'modified_at', 'modified_by'
       ]) = (to_jsonb(OLD) - ARRAY[
         'catalog_status', 'is_active', 'modified_at', 'modified_by'
       ]) THEN
      RETURN NEW;
    END IF;

    IF current_user = 'javaneh_identity_executor'
       AND v_version_status = 'retired'
       AND OLD.catalog_version IS NOT NULL
       AND OLD.catalog_status = 'active'
       AND NEW.catalog_status = 'retired'
       AND NOT NEW.is_active
       AND (to_jsonb(NEW) - ARRAY[
         'catalog_status', 'is_active', 'modified_at', 'modified_by'
       ]) = (to_jsonb(OLD) - ARRAY[
         'catalog_status', 'is_active', 'modified_at', 'modified_by'
       ]) THEN
      RETURN NEW;
    END IF;

    RAISE EXCEPTION 'Approved milestone definitions are immutable'
      USING ERRCODE = '42501';
  END IF;

  IF v_version_status <> 'draft' THEN
    RAISE EXCEPTION 'Milestone catalog can only change in a draft version'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_scoring_milestone_catalog()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.retire_scoring_milestone_catalog()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
  IF OLD.status = 'active' AND NEW.status = 'retired' THEN
    UPDATE public.scoring_milestone_catalog AS m
      SET catalog_status = 'retired',
          is_active = false,
          modified_at = pg_catalog.clock_timestamp(),
          modified_by = javaneh_private.current_uid()
      WHERE m.configuration_version_id = NEW.id
        AND m.catalog_version IS NOT NULL
        AND m.catalog_status = 'active';
  END IF;
  RETURN NEW;
END
$function$;
ALTER FUNCTION public.retire_scoring_milestone_catalog()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.retire_scoring_milestone_catalog()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER scoring_configuration_version_retire_catalog
  AFTER UPDATE OF status ON public.scoring_configuration_versions
  FOR EACH ROW EXECUTE FUNCTION public.retire_scoring_milestone_catalog();

CREATE FUNCTION public.prevent_retiring_active_competition()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
BEGIN
  IF OLD.status = 'active' AND NEW.status = 'retired'
     AND EXISTS (
       SELECT 1
         FROM public.competitions AS competition
         WHERE competition.scoring_configuration_version_id = OLD.id
           AND competition.status = 'active'
     ) THEN
    RAISE EXCEPTION 'Retire the competition before retiring its scoring configuration'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.prevent_retiring_active_competition()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER scoring_configuration_version_competition_guard
  BEFORE UPDATE OF status ON public.scoring_configuration_versions
  FOR EACH ROW EXECUTE FUNCTION public.prevent_retiring_active_competition();

CREATE FUNCTION public.guard_competition_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_status text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.status <> 'draft' THEN
      RAISE EXCEPTION 'Activated competitions cannot be deleted'
        USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id
     OR NEW.competition_key IS DISTINCT FROM OLD.competition_key
     OR NEW.created_by IS DISTINCT FROM OLD.created_by
     OR NEW.created_at IS DISTINCT FROM OLD.created_at
     OR NEW.scoring_configuration_version_id
       IS DISTINCT FROM OLD.scoring_configuration_version_id THEN
    RAISE EXCEPTION 'Competition identity is immutable'
      USING ERRCODE = '42501';
  END IF;
  IF NEW.status = OLD.status THEN
    IF OLD.status <> 'draft' OR current_user <> 'javaneh_identity_executor' THEN
      RAISE EXCEPTION 'Competition details can only change through authorized operations while draft'
        USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
  END IF;
  IF current_user <> 'javaneh_identity_executor'
     OR NOT (
       (OLD.status = 'draft' AND NEW.status = 'active')
       OR (OLD.status = 'active' AND NEW.status = 'retired')
     ) THEN
    RAISE EXCEPTION 'Invalid or unauthorized competition lifecycle transition'
      USING ERRCODE = '42501';
  END IF;

  SELECT v.status INTO v_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = NEW.scoring_configuration_version_id;
  IF NEW.status = 'active'
     AND (
       v_status IS DISTINCT FROM 'active'
       OR NOT public.scoring_configuration_is_ready(
         NEW.scoring_configuration_version_id
       )
     ) THEN
    RAISE EXCEPTION 'Competition scoring configuration is not ready'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_competition_lifecycle()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER competitions_lifecycle_guard
  BEFORE UPDATE OR DELETE ON public.competitions
  FOR EACH ROW EXECUTE FUNCTION public.guard_competition_lifecycle();

CREATE FUNCTION public.scoring_configuration_is_ready(p_version_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_version public.scoring_configuration_versions%ROWTYPE;
  v_configuration_key text;
BEGIN
  SELECT v.* INTO v_version
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = p_version_id;
  SELECT c.configuration_key INTO v_configuration_key
    FROM public.scoring_configurations AS c
    WHERE c.id = v_version.configuration_id;
  IF NOT FOUND
     OR v_version.development_max_points IS NULL
     OR v_version.human_jury_max_points IS NULL
     OR v_version.overall_max_points IS NULL
     OR v_version.overall_max_points <>
       v_version.development_max_points + v_version.human_jury_max_points
     OR v_version.rounding_policy IS DISTINCT FROM 'floor' THEN
    RETURN false;
  END IF;

  IF v_configuration_key IS DISTINCT FROM 'javaneh-approved-scoring-policy-v1'
     OR v_version.version_number <> 1 THEN
    IF (SELECT pg_catalog.count(*)
          FROM public.scoring_stage_catalog AS s
          WHERE s.configuration_version_id = p_version_id) <> 7
       OR (SELECT COALESCE(pg_catalog.sum(s.maximum_points), 0)
             FROM public.scoring_stage_catalog AS s
             WHERE s.configuration_version_id = p_version_id
               AND s.stage_kind = 'development')
         <> v_version.development_max_points
       OR (SELECT s.maximum_points
             FROM public.scoring_stage_catalog AS s
             WHERE s.configuration_version_id = p_version_id
               AND s.stage_number = 7)
         IS DISTINCT FROM v_version.human_jury_max_points
       OR EXISTS (
         SELECT 1
           FROM public.scoring_stage_catalog AS s
           LEFT JOIN (
             SELECT m.configuration_version_id, m.stage_number,
               pg_catalog.sum(m.point_value) AS points
             FROM public.scoring_milestone_catalog AS m
             WHERE m.configuration_version_id = p_version_id
             GROUP BY m.configuration_version_id, m.stage_number
           ) AS totals
             ON totals.configuration_version_id = s.configuration_version_id
            AND totals.stage_number = s.stage_number
           WHERE s.configuration_version_id = p_version_id
             AND (
               (s.stage_number = 7 AND totals.points IS NOT NULL)
               OR (s.stage_number BETWEEN 1 AND 6
                   AND COALESCE(totals.points, 0) <> s.maximum_points)
             )
       )
       OR EXISTS (
         SELECT 1
           FROM public.scoring_milestone_catalog AS m
           WHERE m.configuration_version_id = p_version_id
             AND (
               m.stage_number NOT BETWEEN 1 AND 6
               OR m.validation_mode NOT IN ('qualitative', 'objective')
               OR m.validation_policy IS NULL
               OR m.catalog_status <> 'approved'
               OR m.descriptor_status <> 'approved'
               OR m.is_active
               OR m.evaluator_instructions IS NULL
               OR (m.validation_mode = 'qualitative'
                   AND (
                     m.level_0_description IS NULL
                     OR m.level_1_description IS NULL
                     OR m.level_2_description IS NULL
                     OR m.level_3_description IS NULL
                     OR m.level_4_description IS NULL
                     OR m.evidence_guidance IS NULL
                   ))
             )
       )
       OR NOT EXISTS (
         SELECT 1
           FROM public.scoring_milestone_catalog AS m
           WHERE m.configuration_version_id = p_version_id
       ) THEN
      RETURN false;
    END IF;
    RETURN true;
  END IF;

  IF v_version.development_max_points IS DISTINCT FROM 700
     OR v_version.human_jury_max_points IS DISTINCT FROM 300
     OR v_version.overall_max_points IS DISTINCT FROM 1000 THEN
    RETURN false;
  END IF;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_stage_catalog AS s
        WHERE s.configuration_version_id = p_version_id) <> 7
     OR (SELECT pg_catalog.sum(s.maximum_points)
           FROM public.scoring_stage_catalog AS s
           WHERE s.configuration_version_id = p_version_id
             AND s.stage_kind = 'development') <> 700
     OR (SELECT s.maximum_points
           FROM public.scoring_stage_catalog AS s
           WHERE s.configuration_version_id = p_version_id
             AND s.stage_number = 7) IS DISTINCT FROM 300
     OR EXISTS (
       SELECT 1
         FROM (VALUES
           (1, 'Problem Definition', 80),
           (2, 'Identification of Social Capacities', 100),
           (3, 'Idea Development', 140),
           (4, 'Implementation Planning', 140),
           (5, 'Feasibility and Resilience', 120),
           (6, 'Final Dossier Preparation', 120),
           (7, 'Human Jury Evaluation', 300)
         ) AS expected(stage_number, display_name, maximum_points)
         LEFT JOIN public.scoring_stage_catalog AS actual
           ON actual.configuration_version_id = p_version_id
          AND actual.stage_number = expected.stage_number
         WHERE actual.stage_number IS NULL
            OR actual.display_name <> expected.display_name
            OR actual.maximum_points <> expected.maximum_points
            OR actual.sort_order <> expected.stage_number
            OR actual.stage_kind <> CASE
              WHEN expected.stage_number = 7 THEN 'human_jury'
              ELSE 'development'
            END
     ) THEN
    RETURN false;
  END IF;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_evaluation_levels AS l
        WHERE l.configuration_version_id = p_version_id) <> 5
     OR EXISTS (
       SELECT 1
         FROM (VALUES
           (0, 'Not achieved', 0.00::numeric),
           (1, 'Very limited', 0.25::numeric),
           (2, 'Developing', 0.50::numeric),
           (3, 'Satisfactory', 0.75::numeric),
           (4, 'Fully achieved and supported', 1.00::numeric)
         ) AS expected(evaluation_level, display_label, multiplier)
         LEFT JOIN public.scoring_evaluation_levels AS actual
           ON actual.configuration_version_id = p_version_id
          AND actual.evaluation_level = expected.evaluation_level
         WHERE actual.evaluation_level IS NULL
            OR actual.display_label <> expected.display_label
            OR actual.multiplier <> expected.multiplier
     ) THEN
    RETURN false;
  END IF;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_milestone_catalog AS m
        WHERE m.configuration_version_id = p_version_id
          AND m.catalog_version = '1.0') <> 28
     OR (SELECT pg_catalog.count(*)
           FROM public.scoring_milestone_catalog AS m
           WHERE m.configuration_version_id = p_version_id) <> 28
     OR EXISTS (
       SELECT 1
         FROM public.scoring_stage_catalog AS s
         LEFT JOIN public.scoring_milestone_catalog AS m
           ON m.configuration_version_id = s.configuration_version_id
          AND m.stage_number = s.stage_number
          AND m.catalog_version = '1.0'
         WHERE s.configuration_version_id = p_version_id
           AND (
             (s.stage_number = 7 AND m.milestone_key IS NOT NULL)
             OR (s.stage_number BETWEEN 1 AND 6
                 AND COALESCE(m.point_value, 0) > s.maximum_points)
           )
     )
     OR EXISTS (
       SELECT 1
         FROM public.scoring_stage_catalog AS s
         LEFT JOIN (
           SELECT m.configuration_version_id, m.stage_number,
             pg_catalog.sum(m.point_value) AS points
           FROM public.scoring_milestone_catalog AS m
           WHERE m.configuration_version_id = p_version_id
             AND m.catalog_version = '1.0'
           GROUP BY m.configuration_version_id, m.stage_number
         ) AS totals
           ON totals.configuration_version_id = s.configuration_version_id
          AND totals.stage_number = s.stage_number
         WHERE s.configuration_version_id = p_version_id
           AND s.stage_number BETWEEN 1 AND 6
           AND COALESCE(totals.points, 0) <> s.maximum_points
     )
     OR EXISTS (
       SELECT 1
         FROM public.scoring_milestone_catalog AS m
         WHERE m.configuration_version_id = p_version_id
           AND m.catalog_version = '1.0'
           AND (
             m.milestone_key !~ '^S[1-6]-M[1-5]$'
             OR m.stage_number NOT BETWEEN 1 AND 6
             OR m.validation_mode <> 'qualitative'
             OR m.validation_policy IS DISTINCT FROM
               '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
             OR m.catalog_status <> 'approved'
             OR m.descriptor_status <> 'approved'
             OR m.is_active
             OR m.level_0_description IS NULL
             OR m.level_1_description IS NULL
             OR m.level_2_description IS NULL
             OR m.level_3_description IS NULL
             OR m.level_4_description IS NULL
             OR m.evidence_guidance IS NULL
             OR m.evaluator_instructions IS NULL
           )
     )
     OR EXISTS (
       SELECT 1
         FROM (VALUES
           ('S1-M1', 1, 25), ('S1-M2', 1, 20),
           ('S1-M3', 1, 20), ('S1-M4', 1, 15),
           ('S2-M1', 2, 25), ('S2-M2', 2, 25),
           ('S2-M3', 2, 25), ('S2-M4', 2, 25),
           ('S3-M1', 3, 30), ('S3-M2', 3, 35),
           ('S3-M3', 3, 35), ('S3-M4', 3, 20), ('S3-M5', 3, 20),
           ('S4-M1', 4, 25), ('S4-M2', 4, 35),
           ('S4-M3', 4, 25), ('S4-M4', 4, 30), ('S4-M5', 4, 25),
           ('S5-M1', 5, 25), ('S5-M2', 5, 25),
           ('S5-M3', 5, 25), ('S5-M4', 5, 25), ('S5-M5', 5, 20),
           ('S6-M1', 6, 30), ('S6-M2', 6, 30),
           ('S6-M3', 6, 20), ('S6-M4', 6, 20), ('S6-M5', 6, 20)
         ) AS expected(milestone_key, stage_number, point_value)
         LEFT JOIN public.scoring_milestone_catalog AS actual
           ON actual.configuration_version_id = p_version_id
          AND actual.milestone_key = expected.milestone_key
          AND actual.catalog_version = '1.0'
         WHERE actual.milestone_key IS NULL
            OR actual.stage_number <> expected.stage_number
            OR actual.point_value <> expected.point_value
     ) THEN
    RETURN false;
  END IF;

  RETURN true;
END
$function$;
ALTER FUNCTION public.scoring_configuration_is_ready(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.scoring_configuration_is_ready(uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.activate_scoring_configuration_version(
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
    SELECT 1 FROM public.scoring_role_assignments AS r
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
  IF EXISTS (
    SELECT 1
      FROM public.scoring_configuration_versions AS v
      WHERE v.id = p_version_id
        AND v.development_max_points IS NOT NULL
  ) AND NOT public.scoring_configuration_is_ready(p_version_id) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'configuration_incomplete');
  END IF;

  UPDATE public.scoring_milestone_catalog AS m
    SET catalog_status = 'active',
        is_active = true,
        modified_at = pg_catalog.clock_timestamp(),
        modified_by = v_actor_id
    WHERE m.configuration_version_id = p_version_id
      AND m.catalog_version IS NOT NULL
      AND m.catalog_status = 'approved';

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

CREATE FUNCTION public.set_competition_status(
  p_competition_id uuid,
  p_status text,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
  v_competition public.competitions%ROWTYPE;
  v_event_type text;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_competition_id IS NULL
     OR p_status NOT IN ('active', 'retired')
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
    SELECT 1 FROM public.scoring_role_assignments AS r
    WHERE r.user_id = v_actor_id
      AND r.role_name = 'scoring_administrator'
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator authorization required'
      USING ERRCODE = '42501';
  END IF;

  SELECT c.* INTO v_competition
    FROM public.competitions AS c
    WHERE c.id = p_competition_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF (v_competition.status = 'draft' AND p_status = 'active') THEN
    v_event_type := 'activated';
    IF NOT public.scoring_configuration_is_ready(
      v_competition.scoring_configuration_version_id
    ) OR NOT EXISTS (
      SELECT 1
        FROM public.scoring_configuration_versions AS v
        WHERE v.id = v_competition.scoring_configuration_version_id
          AND v.status = 'active'
    ) THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'configuration_incomplete');
    END IF;
  ELSIF v_competition.status = 'active' AND p_status = 'retired' THEN
    v_event_type := 'retired';
  ELSE
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;

  UPDATE public.competitions AS c
    SET status = p_status,
        modified_by = v_actor_id,
        updated_at = pg_catalog.clock_timestamp()
    WHERE c.id = p_competition_id;
  INSERT INTO public.competition_events (
    competition_id, actor_user_id, event_type, reason
  )
  VALUES (p_competition_id, v_actor_id, v_event_type, p_reason);
  RETURN pg_catalog.jsonb_build_object('outcome', p_status);
END
$function$;
ALTER FUNCTION public.set_competition_status(uuid, text, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.set_competition_status(uuid, text, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_competition_status(uuid, text, text)
  TO authenticated;

CREATE FUNCTION public.guard_milestone_validation_level()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_mode text;
BEGIN
  SELECT m.validation_mode INTO v_mode
    FROM public.scoring_milestone_catalog AS m
    WHERE m.configuration_version_id = NEW.configuration_version_id
      AND m.milestone_key = NEW.milestone_key;
  IF v_mode = 'qualitative'
     AND (
       NEW.evaluation_level IS NULL
       OR (NEW.evaluation_level = 0 AND NEW.decision <> 'rejected')
       OR (NEW.evaluation_level > 0 AND NEW.decision <> 'approved')
     ) THEN
    RAISE EXCEPTION 'Qualitative milestone decisions require a matching evaluation level'
      USING ERRCODE = '23514';
  END IF;
  IF v_mode IS DISTINCT FROM 'qualitative'
     AND NEW.evaluation_level IS NOT NULL THEN
    RAISE EXCEPTION 'Evaluation levels are only valid for qualitative milestones'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
REVOKE ALL ON FUNCTION public.guard_milestone_validation_level()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER milestone_validations_level_guard
  BEFORE INSERT ON public.milestone_validations
  FOR EACH ROW EXECUTE FUNCTION public.guard_milestone_validation_level();

CREATE FUNCTION public.validate_milestone_with_level(
  p_idea_id uuid,
  p_configuration_version_id uuid,
  p_milestone_key text,
  p_expected_revision integer,
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
     OR p_milestone_key !~ '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$'
     OR p_expected_revision IS NULL
     OR p_expected_revision < 1
     OR p_evaluation_level IS NULL
     OR p_evaluation_level NOT BETWEEN 0 AND 4
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
    SELECT 1 FROM public.scoring_role_assignments AS r
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
    FROM public.ideas AS i WHERE i.id = p_idea_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_owner_id = v_actor_id THEN
    RAISE EXCEPTION 'A Validator cannot validate their own idea'
      USING ERRCODE = '42501';
  END IF;
  IF v_revision <> p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'stale_evidence', 'current_revision', v_revision
    );
  END IF;
  SELECT v.status INTO v_version_status
    FROM public.scoring_configuration_versions AS v
    WHERE v.id = p_configuration_version_id FOR SHARE;
  IF v_version_status IS DISTINCT FROM 'active'
     OR NOT EXISTS (
       SELECT 1 FROM public.scoring_milestone_catalog AS m
       WHERE m.configuration_version_id = p_configuration_version_id
         AND m.milestone_key = p_milestone_key
         AND m.is_active
         AND m.validation_mode = 'qualitative'
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
      'outcome', 'already_decided', 'decision', v_existing_decision
    );
  END IF;

  INSERT INTO public.milestone_validations (
    idea_id, participant_id, configuration_version_id, milestone_key,
    reviewed_revision, decision, reason, validator_id, evaluation_level
  )
  VALUES (
    p_idea_id, v_owner_id, p_configuration_version_id, p_milestone_key,
    v_revision,
    CASE WHEN p_evaluation_level = 0 THEN 'rejected' ELSE 'approved' END,
    p_reason, v_actor_id, p_evaluation_level
  )
  RETURNING validation_id INTO v_validation_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', CASE WHEN p_evaluation_level = 0 THEN 'rejected' ELSE 'approved' END,
    'validation_id', v_validation_id,
    'reviewed_revision', v_revision,
    'evaluation_level', p_evaluation_level
  );
END
$function$;
ALTER FUNCTION public.validate_milestone_with_level(uuid, uuid, text, integer, smallint, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.validate_milestone_with_level(uuid, uuid, text, integer, smallint, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.validate_milestone_with_level(uuid, uuid, text, integer, smallint, text)
  TO authenticated;

CREATE FUNCTION public.calculate_scoring_milestone_points(
  p_configuration_version_id uuid,
  p_milestone_key text,
  p_evaluation_level smallint
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT pg_catalog.floor(m.point_value * l.multiplier)::integer
    FROM public.scoring_milestone_catalog AS m
    JOIN public.scoring_evaluation_levels AS l
      ON l.configuration_version_id = m.configuration_version_id
    WHERE m.configuration_version_id = p_configuration_version_id
      AND m.milestone_key = p_milestone_key
      AND m.validation_mode = 'qualitative'
      AND l.evaluation_level = p_evaluation_level
$function$;
ALTER FUNCTION public.calculate_scoring_milestone_points(uuid, text, smallint)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.calculate_scoring_milestone_points(uuid, text, smallint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.calculate_scoring_milestone_points(uuid, text, smallint)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_official_points_ledger()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_version_status text;
  v_milestone public.scoring_milestone_catalog%ROWTYPE;
  v_original public.official_points_ledger%ROWTYPE;
  v_validation public.milestone_validations%ROWTYPE;
  v_expected_points integer;
  v_stage_max integer;
  v_development_max integer;
  v_stage_points bigint;
  v_development_points bigint;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'Official points ledger entries are append-only'
      USING ERRCODE = '42501';
  END IF;

  SELECT v.status, v.development_max_points
    INTO v_version_status, v_development_max
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
       OR NEW.stage_number IS DISTINCT FROM v_milestone.stage_number THEN
      RAISE EXCEPTION 'Award does not match an active approved milestone'
        USING ERRCODE = '42501';
    END IF;

    IF v_milestone.catalog_version IS NULL THEN
      v_expected_points := v_milestone.point_value;
    ELSE
        IF NOT EXISTS (
          SELECT 1
            FROM public.competitions AS competition
            WHERE competition.scoring_configuration_version_id =
                NEW.configuration_version_id
              AND competition.status = 'active'
        ) THEN
          RAISE EXCEPTION 'Competition must be active before awarding points'
            USING ERRCODE = '42501';
        END IF;
        SELECT validation.* INTO v_validation
        FROM public.milestone_validations AS validation
        WHERE validation.validation_id = NEW.source_reference;
      IF NOT FOUND
         OR v_validation.decision <> 'approved'
         OR v_validation.evaluation_level IS NULL
         OR v_validation.validator_id IS DISTINCT FROM NEW.recorded_by
         OR v_validation.participant_id IS DISTINCT FROM NEW.user_id
         OR v_validation.idea_id IS DISTINCT FROM NEW.idea_id
         OR v_validation.configuration_version_id
           IS DISTINCT FROM NEW.configuration_version_id
         OR v_validation.milestone_key IS DISTINCT FROM NEW.milestone_key THEN
        RAISE EXCEPTION 'Award must match an approved level evaluation'
          USING ERRCODE = '42501';
      END IF;
      v_expected_points := public.calculate_scoring_milestone_points(
        NEW.configuration_version_id,
        NEW.milestone_key,
        v_validation.evaluation_level
      );
    END IF;
    IF v_expected_points IS NULL
       OR v_expected_points <= 0
       OR NEW.points IS DISTINCT FROM v_expected_points
       OR NEW.points > v_milestone.point_value THEN
      RAISE EXCEPTION 'Award points do not match the configured evaluation level'
        USING ERRCODE = '23514';
    END IF;

    SELECT s.maximum_points INTO v_stage_max
      FROM public.scoring_stage_catalog AS s
      WHERE s.configuration_version_id = NEW.configuration_version_id
        AND s.stage_number = NEW.stage_number;
    IF v_stage_max IS NOT NULL THEN
      PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
          'javaneh:score-budget:v1:' || NEW.configuration_version_id::text
            || ':' || NEW.idea_id::text,
          0
        )
      );
      SELECT COALESCE(pg_catalog.sum(l.points), 0)
        INTO v_stage_points
        FROM public.official_points_ledger AS l
        WHERE l.idea_id = NEW.idea_id
          AND l.configuration_version_id = NEW.configuration_version_id
          AND l.stage_number = NEW.stage_number;
      IF v_stage_points + NEW.points > v_stage_max THEN
        RAISE EXCEPTION 'Award exceeds the configured stage maximum'
          USING ERRCODE = '23514';
      END IF;
      SELECT COALESCE(pg_catalog.sum(l.points), 0)
        INTO v_development_points
        FROM public.official_points_ledger AS l
        WHERE l.idea_id = NEW.idea_id
          AND l.configuration_version_id = NEW.configuration_version_id
          AND l.stage_number BETWEEN 1 AND 6;
      IF NEW.stage_number BETWEEN 1 AND 6
         AND v_development_points + NEW.points > v_development_max THEN
        RAISE EXCEPTION 'Award exceeds the configured development maximum'
          USING ERRCODE = '23514';
      END IF;
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

CREATE OR REPLACE FUNCTION public.award_validated_milestone(p_validation_id uuid)
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
  v_points integer;
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
    SELECT 1 FROM public.scoring_role_assignments AS r
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
    WHERE v.id = v_validation.configuration_version_id FOR SHARE;
  SELECT m.* INTO v_milestone
    FROM public.scoring_milestone_catalog AS m
    WHERE m.configuration_version_id = v_validation.configuration_version_id
      AND m.milestone_key = v_validation.milestone_key;
  IF v_version_status IS DISTINCT FROM 'active'
     OR NOT FOUND OR NOT v_milestone.is_active
     OR (
       v_milestone.catalog_version IS NOT NULL
       AND NOT EXISTS (
         SELECT 1
           FROM public.competitions AS competition
           WHERE competition.scoring_configuration_version_id =
               v_validation.configuration_version_id
             AND competition.status = 'active'
       )
     ) THEN
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
      'outcome', 'already_awarded', 'entry_id', v_entry_id
    );
  END IF;

  v_points := CASE
    WHEN v_milestone.catalog_version IS NULL THEN v_milestone.point_value
    ELSE public.calculate_scoring_milestone_points(
      v_validation.configuration_version_id,
      v_validation.milestone_key,
      v_validation.evaluation_level
    )
  END;
  IF v_points IS NULL OR v_points <= 0 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'no_points_awarded');
  END IF;

  INSERT INTO public.official_points_ledger (
    idempotency_key, user_id, idea_id, configuration_version_id,
    milestone_key, stage_number, entry_kind, points, source,
    source_reference, reason, recorded_by
  )
  VALUES (
    pg_catalog.gen_random_uuid(),
    v_validation.participant_id,
    v_validation.idea_id,
    v_validation.configuration_version_id,
    v_validation.milestone_key,
    v_milestone.stage_number,
    'award',
    v_points,
    'milestone_validation',
    v_validation.validation_id,
    v_validation.reason,
    v_actor_id
  )
  RETURNING entry_id INTO v_entry_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'awarded',
    'entry_id', v_entry_id,
    'points', v_points
  );
END
$function$;
ALTER FUNCTION public.award_validated_milestone(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.award_validated_milestone(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.award_validated_milestone(uuid)
  TO authenticated;

DO $seed_configuration$
DECLARE
  v_configuration_id uuid;
  v_version_id uuid;
BEGIN
  INSERT INTO public.scoring_configurations (configuration_key)
  VALUES ('javaneh-approved-scoring-policy-v1')
  ON CONFLICT (configuration_key) WHERE configuration_key IS NOT NULL
  DO NOTHING;
  SELECT c.id INTO v_configuration_id
    FROM public.scoring_configurations AS c
    WHERE c.configuration_key = 'javaneh-approved-scoring-policy-v1';

  INSERT INTO public.scoring_configuration_versions (
    configuration_id,
    version_number,
    development_max_points,
    human_jury_max_points,
    overall_max_points,
    rounding_policy
  )
  VALUES (v_configuration_id, 1, 700, 300, 1000, 'floor')
  ON CONFLICT (configuration_id, version_number) DO NOTHING;
  SELECT v.id INTO v_version_id
    FROM public.scoring_configuration_versions AS v
    WHERE v.configuration_id = v_configuration_id
      AND v.version_number = 1;

  INSERT INTO public.scoring_stage_catalog (
    configuration_version_id, stage_number, display_name,
    stage_kind, maximum_points, sort_order
  )
  VALUES
    (v_version_id, 1, 'Problem Definition', 'development', 80, 1),
    (v_version_id, 2, 'Identification of Social Capacities', 'development', 100, 2),
    (v_version_id, 3, 'Idea Development', 'development', 140, 3),
    (v_version_id, 4, 'Implementation Planning', 'development', 140, 4),
    (v_version_id, 5, 'Feasibility and Resilience', 'development', 120, 5),
    (v_version_id, 6, 'Final Dossier Preparation', 'development', 120, 6),
    (v_version_id, 7, 'Human Jury Evaluation', 'human_jury', 300, 7)
  ON CONFLICT (configuration_version_id, stage_number) DO NOTHING;

  INSERT INTO public.scoring_evaluation_levels (
    configuration_version_id, evaluation_level, display_label, multiplier
  )
  VALUES
    (v_version_id, 0, 'Not achieved', 0.00),
    (v_version_id, 1, 'Very limited', 0.25),
    (v_version_id, 2, 'Developing', 0.50),
    (v_version_id, 3, 'Satisfactory', 0.75),
    (v_version_id, 4, 'Fully achieved and supported', 1.00)
  ON CONFLICT (configuration_version_id, evaluation_level) DO NOTHING;

  INSERT INTO public.scoring_milestone_catalog (
    configuration_version_id, milestone_key, stage_number, definition,
    point_value, is_active, catalog_version, display_name,
    participant_description, evaluator_description, validation_mode,
    validation_policy, catalog_status, sort_order, descriptor_status
  )
  VALUES
    (v_version_id, 'S1-M1', 1, 'Clarity and precision of problem description', 25, false, '1.0', 'Clarity and precision of problem description', 'Clarity and precision of problem description', 'Clarity and precision of problem description', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 1, 'pending'),
    (v_version_id, 'S1-M2', 1, 'Identification of affected populations', 20, false, '1.0', 'Identification of affected populations', 'Identification of affected populations', 'Identification of affected populations', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 2, 'pending'),
    (v_version_id, 'S1-M3', 1, 'Relevant observations, experiences, or evidence', 20, false, '1.0', 'Relevant observations, experiences, or evidence', 'Relevant observations, experiences, or evidence', 'Relevant observations, experiences, or evidence', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 3, 'pending'),
    (v_version_id, 'S1-M4', 1, 'Explanation of the problem''s social significance', 15, false, '1.0', 'Explanation of the problem''s social significance', 'Explanation of the problem''s social significance', 'Explanation of the problem''s social significance', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 4, 'pending'),
    (v_version_id, 'S2-M1', 2, 'Identification of relevant people, groups, and actors', 25, false, '1.0', 'Identification of relevant people, groups, and actors', 'Identification of relevant people, groups, and actors', 'Identification of relevant people, groups, and actors', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 1, 'pending'),
    (v_version_id, 'S2-M2', 2, 'Identification of local assets and resources', 25, false, '1.0', 'Identification of local assets and resources', 'Identification of local assets and resources', 'Identification of local assets and resources', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 2, 'pending'),
    (v_version_id, 'S2-M3', 2, 'Identification of relationships, networks, and collaboration capacities', 25, false, '1.0', 'Identification of relationships, networks, and collaboration capacities', 'Identification of relationships, networks, and collaboration capacities', 'Identification of relationships, networks, and collaboration capacities', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 3, 'pending'),
    (v_version_id, 'S2-M4', 2, 'Explanation of how identified capacities relate to the problem', 25, false, '1.0', 'Explanation of how identified capacities relate to the problem', 'Explanation of how identified capacities relate to the problem', 'Explanation of how identified capacities relate to the problem', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 4, 'pending'),
    (v_version_id, 'S3-M1', 3, 'Examination of alternative solutions and approaches', 30, false, '1.0', 'Examination of alternative solutions and approaches', 'Examination of alternative solutions and approaches', 'Examination of alternative solutions and approaches', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 1, 'pending'),
    (v_version_id, 'S3-M2', 3, 'Alignment of the idea with the identified problem', 35, false, '1.0', 'Alignment of the idea with the identified problem', 'Alignment of the idea with the identified problem', 'Alignment of the idea with the identified problem', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 2, 'pending'),
    (v_version_id, 'S3-M3', 3, 'Innovation and added value', 35, false, '1.0', 'Innovation and added value', 'Innovation and added value', 'Innovation and added value', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 3, 'pending'),
    (v_version_id, 'S3-M4', 3, 'Coherence and clarity of the selected idea', 20, false, '1.0', 'Coherence and clarity of the selected idea', 'Coherence and clarity of the selected idea', 'Coherence and clarity of the selected idea', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 4, 'pending'),
    (v_version_id, 'S3-M5', 3, 'Participant''s active contribution and ownership of the idea', 20, false, '1.0', 'Participant''s active contribution and ownership of the idea', 'Participant''s active contribution and ownership of the idea', 'Participant''s active contribution and ownership of the idea', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 5, 'pending'),
    (v_version_id, 'S4-M1', 4, 'Definition of objectives and expected outcomes', 25, false, '1.0', 'Definition of objectives and expected outcomes', 'Definition of objectives and expected outcomes', 'Definition of objectives and expected outcomes', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 1, 'pending'),
    (v_version_id, 'S4-M2', 4, 'Design of implementation activities and steps', 35, false, '1.0', 'Design of implementation activities and steps', 'Design of implementation activities and steps', 'Design of implementation activities and steps', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 2, 'pending'),
    (v_version_id, 'S4-M3', 4, 'Definition of roles and responsibilities', 25, false, '1.0', 'Definition of roles and responsibilities', 'Definition of roles and responsibilities', 'Definition of roles and responsibilities', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 3, 'pending'),
    (v_version_id, 'S4-M4', 4, 'Identification of resources and implementation requirements', 30, false, '1.0', 'Identification of resources and implementation requirements', 'Identification of resources and implementation requirements', 'Identification of resources and implementation requirements', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 4, 'pending'),
    (v_version_id, 'S4-M5', 4, 'Implementation timeline and sequence', 25, false, '1.0', 'Implementation timeline and sequence', 'Implementation timeline and sequence', 'Implementation timeline and sequence', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 5, 'pending'),
    (v_version_id, 'S5-M1', 5, 'Identification of assumptions and constraints', 25, false, '1.0', 'Identification of assumptions and constraints', 'Identification of assumptions and constraints', 'Identification of assumptions and constraints', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 1, 'pending'),
    (v_version_id, 'S5-M2', 5, 'Examination of risks and implementation barriers', 25, false, '1.0', 'Examination of risks and implementation barriers', 'Examination of risks and implementation barriers', 'Examination of risks and implementation barriers', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 2, 'pending'),
    (v_version_id, 'S5-M3', 5, 'Examination of resource availability', 25, false, '1.0', 'Examination of resource availability', 'Examination of resource availability', 'Examination of resource availability', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 3, 'pending'),
    (v_version_id, 'S5-M4', 5, 'Identification of adaptation and resilience strategies', 25, false, '1.0', 'Identification of adaptation and resilience strategies', 'Identification of adaptation and resilience strategies', 'Identification of adaptation and resilience strategies', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 4, 'pending'),
    (v_version_id, 'S5-M5', 5, 'Revision and improvement based on feasibility analysis', 20, false, '1.0', 'Revision and improvement based on feasibility analysis', 'Revision and improvement based on feasibility analysis', 'Revision and improvement based on feasibility analysis', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 5, 'pending'),
    (v_version_id, 'S6-M1', 6, 'Completeness of the dossier', 30, false, '1.0', 'Completeness of the dossier', 'Completeness of the dossier', 'Completeness of the dossier', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 1, 'pending'),
    (v_version_id, 'S6-M2', 6, 'Coherence across dossier sections', 30, false, '1.0', 'Coherence across dossier sections', 'Coherence across dossier sections', 'Coherence across dossier sections', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 2, 'pending'),
    (v_version_id, 'S6-M3', 6, 'Traceability of claims and evidence', 20, false, '1.0', 'Traceability of claims and evidence', 'Traceability of claims and evidence', 'Traceability of claims and evidence', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 3, 'pending'),
    (v_version_id, 'S6-M4', 6, 'Clarity and quality of presentation', 20, false, '1.0', 'Clarity and quality of presentation', 'Clarity and quality of presentation', 'Clarity and quality of presentation', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 4, 'pending'),
    (v_version_id, 'S6-M5', 6, 'Participant''s final review and confirmation', 20, false, '1.0', 'Participant''s final review and confirmation', 'Participant''s final review and confirmation', 'Participant''s final review and confirmation', 'qualitative', '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}', 'approved', 5, 'pending')
  ON CONFLICT (configuration_version_id, milestone_key) DO NOTHING;

  INSERT INTO public.competitions (
    competition_key, name, description, scoring_configuration_version_id
  )
  VALUES (
    'javaneh-social-innovation-v1',
    'Javaneh Social Innovation Competition',
    'Draft competition linked to the approved Version 1.0 scoring policy.',
    v_version_id
  )
  ON CONFLICT (competition_key) DO NOTHING;

  IF NOT public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE NOTICE 'Version 1.0 remains inactive: evaluator descriptors are pending or catalog integrity is incomplete';
  END IF;
END
$seed_configuration$;

COMMENT ON TABLE public.competitions IS
  'Versioned competition identity and lifecycle. Dates, eligibility, registration limits, and leaderboard settings are intentionally not configured.';
COMMENT ON COLUMN public.scoring_configurations.competition_id IS
  'Opaque legacy identifier retained without a foreign key; validated competition links use public.competitions.scoring_configuration_version_id.';
COMMENT ON TABLE public.scoring_stage_catalog IS
  'Versioned stage maxima; Stage 7 is reserved for separate human jury scoring and has no participant milestones.';
COMMENT ON TABLE public.scoring_evaluation_levels IS
  'Approved qualitative scale multipliers. Point awards use floor(maximum points times multiplier).';
COMMENT ON COLUMN public.scoring_milestone_catalog.point_value IS
  'Approved criterion maximum; catalog_version rows are inactive until authorized configuration activation.';
COMMENT ON COLUMN public.scoring_milestone_catalog.descriptor_status IS
  'Detailed level descriptions and evaluator guidance are pending approved source material.';
COMMENT ON TABLE public.competition_events IS
  'Append-only Scoring Administrator competition lifecycle events.';

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
