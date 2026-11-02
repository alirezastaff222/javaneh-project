BEGIN;

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

ALTER TABLE public.scoring_role_assignments
  DROP CONSTRAINT scoring_role_assignments_role_name_check;
ALTER TABLE public.scoring_role_assignments
  ADD CONSTRAINT scoring_role_assignments_role_name_check
  CHECK (role_name IN (
    'platform_owner', 'scoring_administrator', 'validator', 'jury_member'
  ));

DROP VIEW public.user_point_totals;
DROP VIEW public.user_points_by_stage;
DROP VIEW public.user_points_by_milestone;

ALTER TABLE public.official_points_ledger
  ALTER COLUMN points TYPE numeric(10,2) USING points::numeric,
  DROP CONSTRAINT official_points_ledger_validation_award_shape;
ALTER TABLE public.official_points_ledger
  ADD CONSTRAINT official_points_ledger_validation_award_shape
  CHECK (
    validation_request_id IS NULL
    OR (
      competition_id IS NOT NULL
      AND catalog_version IS NOT NULL
      AND (
        (entry_kind = 'award' AND source = 'milestone_validation')
        OR (
          entry_kind = 'compensation'
          AND source = 'administrative_correction'
          AND original_entry_id IS NOT NULL
        )
      )
    )
  );

CREATE VIEW public.user_point_totals WITH (security_invoker = true) AS
SELECT
  l.user_id,
  COALESCE(pg_catalog.sum(l.points) FILTER (WHERE l.entry_kind = 'award'), 0)::numeric(10,2)
    AS awarded_points,
  COALESCE(pg_catalog.sum(l.points) FILTER (WHERE l.entry_kind = 'compensation'), 0)::numeric(10,2)
    AS compensating_points,
  pg_catalog.sum(l.points)::numeric(10,2) AS net_points
FROM public.official_points_ledger AS l
GROUP BY l.user_id;

CREATE VIEW public.user_points_by_stage WITH (security_invoker = true) AS
SELECT l.user_id, l.idea_id, l.configuration_version_id, l.stage_number,
       pg_catalog.sum(l.points)::numeric(10,2) AS net_points
FROM public.official_points_ledger AS l
GROUP BY l.user_id, l.idea_id, l.configuration_version_id, l.stage_number;

CREATE VIEW public.user_points_by_milestone WITH (security_invoker = true) AS
SELECT l.user_id, l.idea_id, l.configuration_version_id, l.milestone_key,
       pg_catalog.sum(l.points)::numeric(10,2) AS net_points
FROM public.official_points_ledger AS l
GROUP BY l.user_id, l.idea_id, l.configuration_version_id, l.milestone_key;

REVOKE ALL ON TABLE
  public.user_point_totals, public.user_points_by_stage,
  public.user_points_by_milestone
  FROM PUBLIC, anon, service_role;
GRANT SELECT ON TABLE
  public.user_point_totals, public.user_points_by_stage,
  public.user_points_by_milestone
  TO javaneh_identity_executor;
REVOKE SELECT ON TABLE
  public.user_point_totals, public.user_points_by_stage,
  public.user_points_by_milestone
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE
  public.user_point_totals, public.user_points_by_stage,
  public.user_points_by_milestone
  TO javaneh_identity_executor;

CREATE TABLE public.jury_rubric_criteria (
  configuration_version_id uuid NOT NULL
    REFERENCES public.scoring_configuration_versions(id) ON DELETE RESTRICT,
  rubric_version text NOT NULL,
  criterion_key text NOT NULL,
  display_name text NOT NULL,
  description text NOT NULL,
  maximum_points integer NOT NULL CHECK (maximum_points > 0),
  sort_order smallint NOT NULL CHECK (sort_order BETWEEN 1 AND 7),
  PRIMARY KEY (configuration_version_id, criterion_key),
  UNIQUE (configuration_version_id, sort_order),
  UNIQUE (configuration_version_id, rubric_version, criterion_key)
);

CREATE TABLE public.jury_assignments (
  assignment_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL REFERENCES public.ideas(id) ON DELETE RESTRICT,
  juror_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  configuration_version_id uuid NOT NULL
    REFERENCES public.scoring_configuration_versions(id) ON DELETE RESTRICT,
  dossier_revision integer NOT NULL CHECK (dossier_revision > 0),
  status text NOT NULL DEFAULT 'assigned'
    CHECK (status IN ('assigned', 'recused', 'submitted')),
  conflict_declared boolean NOT NULL DEFAULT false,
  conflict_reason text,
  assigned_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  assigned_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  conflict_declared_at timestamptz,
  CONSTRAINT jury_assignments_conflict_shape CHECK (
    (conflict_declared = false AND conflict_reason IS NULL)
    OR (conflict_declared = true
      AND conflict_reason IS NOT NULL
      AND pg_catalog.length(pg_catalog.btrim(conflict_reason)) > 0)
  ),
  UNIQUE (idea_id, juror_id),
  UNIQUE (idea_id, assignment_id)
);

CREATE INDEX jury_assignments_active_idea_idx
  ON public.jury_assignments (idea_id, status);

CREATE FUNCTION public.guard_jury_assignment_limit()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog
AS $function$
BEGIN
  IF NEW.status <> 'recused' AND (
    SELECT count(*) FROM public.jury_assignments
    WHERE idea_id = NEW.idea_id AND status <> 'recused'
      AND assignment_id <> NEW.assignment_id
  ) >= 3 THEN
    RAISE EXCEPTION 'An idea cannot have more than three active jury assignments'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
ALTER FUNCTION public.guard_jury_assignment_limit() OWNER TO javaneh_identity_executor;
CREATE TRIGGER jury_assignments_limit
  BEFORE INSERT OR UPDATE OF status ON public.jury_assignments
  FOR EACH ROW EXECUTE FUNCTION public.guard_jury_assignment_limit();

CREATE TABLE public.jury_evaluations (
  evaluation_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  assignment_id uuid NOT NULL UNIQUE
    REFERENCES public.jury_assignments(assignment_id) ON DELETE RESTRICT,
  idea_id uuid NOT NULL REFERENCES public.ideas(id) ON DELETE RESTRICT,
  juror_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  configuration_version_id uuid NOT NULL
    REFERENCES public.scoring_configuration_versions(id) ON DELETE RESTRICT,
  rubric_version text NOT NULL,
  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted')),
  total_points integer NOT NULL CHECK (total_points BETWEEN 0 AND 300),
  submitted_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

CREATE TABLE public.jury_evaluation_scores (
  evaluation_id uuid NOT NULL REFERENCES public.jury_evaluations(evaluation_id)
    ON DELETE RESTRICT,
  criterion_key text NOT NULL,
  level smallint NOT NULL CHECK (level BETWEEN 0 AND 4),
  points integer NOT NULL CHECK (points >= 0),
  justification text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(justification)) > 0),
  evidence_reference text,
  PRIMARY KEY (evaluation_id, criterion_key)
);

CREATE TABLE public.jury_publications (
  publication_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL REFERENCES public.ideas(id) ON DELETE RESTRICT,
  configuration_version_id uuid NOT NULL
    REFERENCES public.scoring_configuration_versions(id) ON DELETE RESTRICT,
  rubric_version text NOT NULL,
  final_score numeric(7,2) NOT NULL CHECK (final_score BETWEEN 0 AND 300),
  criterion_averages jsonb NOT NULL,
  status text NOT NULL DEFAULT 'approved'
    CHECK (status IN ('approved', 'published')),
  approved_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  approval_reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(approval_reason)) > 0),
  approved_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  published_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  published_at timestamptz,
  CONSTRAINT jury_publications_publish_shape CHECK (
    (status = 'approved' AND published_by IS NULL AND published_at IS NULL)
    OR (status = 'published' AND published_by IS NOT NULL AND published_at IS NOT NULL)
  ),
  UNIQUE (idea_id, configuration_version_id)
);

ALTER TABLE public.jury_rubric_criteria ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jury_rubric_criteria FORCE ROW LEVEL SECURITY;
ALTER TABLE public.jury_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jury_assignments FORCE ROW LEVEL SECURITY;
ALTER TABLE public.jury_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jury_evaluations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.jury_evaluation_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jury_evaluation_scores FORCE ROW LEVEL SECURITY;
ALTER TABLE public.jury_publications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jury_publications FORCE ROW LEVEL SECURITY;

CREATE POLICY jury_criteria_executor_all ON public.jury_rubric_criteria
  FOR ALL TO javaneh_identity_executor USING (true) WITH CHECK (true);
CREATE POLICY jury_assignments_executor_all ON public.jury_assignments
  FOR ALL TO javaneh_identity_executor USING (true) WITH CHECK (true);
CREATE POLICY jury_evaluations_executor_all ON public.jury_evaluations
  FOR ALL TO javaneh_identity_executor USING (true) WITH CHECK (true);
CREATE POLICY jury_scores_executor_all ON public.jury_evaluation_scores
  FOR ALL TO javaneh_identity_executor USING (true) WITH CHECK (true);
CREATE POLICY jury_publications_executor_all ON public.jury_publications
  FOR ALL TO javaneh_identity_executor USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE
  public.jury_rubric_criteria, public.jury_assignments,
  public.jury_evaluations, public.jury_evaluation_scores, public.jury_publications
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.jury_rubric_criteria, public.jury_assignments,
  public.jury_evaluations, public.jury_evaluation_scores, public.jury_publications
  TO javaneh_identity_executor;

CREATE FUNCTION public.reject_submitted_jury_history_change()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog
AS $function$
BEGIN
  RAISE EXCEPTION 'Submitted jury evaluations and scores are immutable'
    USING ERRCODE = '42501';
END
$function$;
ALTER FUNCTION public.reject_submitted_jury_history_change() OWNER TO javaneh_identity_executor;
CREATE TRIGGER jury_evaluations_immutable
  BEFORE UPDATE OR DELETE ON public.jury_evaluations
  FOR EACH ROW EXECUTE FUNCTION public.reject_submitted_jury_history_change();
CREATE TRIGGER jury_evaluation_scores_immutable
  BEFORE UPDATE OR DELETE ON public.jury_evaluation_scores
  FOR EACH ROW EXECUTE FUNCTION public.reject_submitted_jury_history_change();

INSERT INTO public.jury_rubric_criteria (
  configuration_version_id, rubric_version, criterion_key, display_name,
  description, maximum_points, sort_order
)
SELECT version.id, 'jury-v1', criteria.criterion_key, criteria.display_name,
       criteria.display_name, criteria.maximum_points, criteria.sort_order
FROM public.scoring_configuration_versions AS version
JOIN public.scoring_configurations AS configuration
  ON configuration.id = version.configuration_id
CROSS JOIN (VALUES
  ('J1', 'Social Significance and Potential Impact', 48, 1),
  ('J2', 'Depth of Problem Understanding', 36, 2),
  ('J3', 'Social Participation and Capacity Building', 44, 3),
  ('J4', 'Innovation and Solution Relevance', 48, 4),
  ('J5', 'Implementation Plan Quality', 44, 5),
  ('J6', 'Feasibility and Sustainability', 44, 6),
  ('J7', 'Scalability and Organizational Learning', 36, 7)
) AS criteria(criterion_key, display_name, maximum_points, sort_order)
WHERE configuration.configuration_key = 'javaneh-approved-scoring-policy-v1'
  AND version.version_number = 1
ON CONFLICT DO NOTHING;

ALTER FUNCTION public.guard_official_points_ledger()
  RENAME TO guard_official_points_ledger_development;
ALTER FUNCTION public.guard_official_points_ledger_development()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.guard_official_points_ledger_development()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guard_official_points_ledger_development()
  TO javaneh_identity_executor;

CREATE FUNCTION public.guard_official_points_ledger_jury()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_version public.scoring_configuration_versions%ROWTYPE;
  v_competition public.competitions%ROWTYPE;
  v_total numeric(10,2);
BEGIN
  IF NEW.entry_kind <> 'award' OR NEW.source <> 'human_jury' THEN
    RETURN NEW;
  END IF;
  SELECT version.* INTO v_version
    FROM public.scoring_configuration_versions AS version
   WHERE version.id = NEW.configuration_version_id;
  SELECT competition.* INTO v_competition
    FROM public.competitions AS competition
   WHERE competition.id = NEW.competition_id
     AND competition.scoring_configuration_version_id = NEW.configuration_version_id
     AND competition.status = 'active';
  IF v_version.status IS DISTINCT FROM 'active'
     OR v_competition.id IS NULL
     OR NEW.idea_id IS NULL
     OR NEW.stage_number IS DISTINCT FROM 7
     OR NEW.milestone_key IS DISTINCT FROM 'jury-final'
     OR NEW.catalog_version IS DISTINCT FROM 'jury-v1'
     OR NEW.validation_request_id IS NOT NULL
     OR NEW.points < 0 OR NEW.points > 300 THEN
    RAISE EXCEPTION 'Invalid human jury ledger award' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:jury-budget:v1:' || NEW.configuration_version_id::text || ':' ||
      NEW.idea_id::text, 0
    )
  );
  SELECT COALESCE(pg_catalog.sum(ledger.points), 0) INTO v_total
    FROM public.official_points_ledger AS ledger
   WHERE ledger.idea_id = NEW.idea_id
     AND ledger.configuration_version_id = NEW.configuration_version_id
     AND ledger.stage_number = 7;
  IF v_total + NEW.points > 300 THEN
    RAISE EXCEPTION 'Jury award exceeds the configured maximum'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END
$function$;
ALTER FUNCTION public.guard_official_points_ledger_jury()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.guard_official_points_ledger_jury()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guard_official_points_ledger_jury()
  TO javaneh_identity_executor;
DROP TRIGGER official_points_ledger_guard ON public.official_points_ledger;
CREATE TRIGGER official_points_ledger_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.official_points_ledger
  FOR EACH ROW EXECUTE FUNCTION public.guard_official_points_ledger_development();
CREATE TRIGGER official_points_ledger_jury_guard
  BEFORE INSERT OR UPDATE OR DELETE ON public.official_points_ledger
  FOR EACH ROW EXECUTE FUNCTION public.guard_official_points_ledger_jury();

CREATE OR REPLACE FUNCTION public.assign_jury_member(
  p_idea_id uuid, p_juror_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.current_uid();
  v_idea public.ideas%ROWTYPE;
  v_competition public.competitions%ROWTYPE;
  v_assignment uuid;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.scoring_role_assignments r
    WHERE r.user_id = v_actor AND r.role_name = 'scoring_administrator')
    THEN RAISE EXCEPTION 'Scoring Administrator access required' USING ERRCODE = '42501'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('javaneh:jury-assignments:' || p_idea_id::text, 0)
  );
  SELECT idea.* INTO v_idea FROM public.ideas idea WHERE idea.id = p_idea_id;
  SELECT competition.* INTO v_competition FROM public.competitions competition
   WHERE competition.id = v_idea.competition_id AND competition.status = 'active';
  IF v_idea.status <> 'submitted' OR v_competition.id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.scoring_role_assignments r
    WHERE r.user_id = p_juror_id AND r.role_name = 'jury_member')
    THEN RAISE EXCEPTION 'Jury Member authorization required' USING ERRCODE = '42501'; END IF;
  IF (SELECT count(*) FROM public.jury_assignments a
      WHERE a.idea_id = p_idea_id AND a.status <> 'recused') >= 3
    THEN RETURN pg_catalog.jsonb_build_object('outcome', 'full'); END IF;
  INSERT INTO public.jury_assignments (
    idea_id, juror_id, configuration_version_id, dossier_revision, assigned_by
  ) VALUES (
    p_idea_id, p_juror_id, v_competition.scoring_configuration_version_id,
    v_idea.revision, v_actor
  ) ON CONFLICT (idea_id, juror_id) DO NOTHING
  RETURNING assignment_id INTO v_assignment;
  RETURN pg_catalog.jsonb_build_object(
    'outcome', CASE WHEN v_assignment IS NULL THEN 'already_assigned' ELSE 'assigned' END,
    'assignment_id', COALESCE(v_assignment, (
      SELECT assignment_id FROM public.jury_assignments
       WHERE idea_id = p_idea_id AND juror_id = p_juror_id
    ))
  );
END
$function$;
ALTER FUNCTION public.assign_jury_member(uuid, uuid) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.assign_jury_member(uuid, uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.assign_jury_member(uuid, uuid) TO authenticated;

CREATE FUNCTION public.manage_jury_member_role(
  p_target_user_id uuid, p_action text, p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE v_actor uuid := javaneh_private.current_uid(); v_changed integer;
BEGIN
  IF p_target_user_id IS NULL OR p_target_user_id = v_actor
     OR p_action NOT IN ('grant', 'revoke')
     OR p_reason IS NULL OR pg_catalog.length(pg_catalog.btrim(p_reason)) = 0
    THEN RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.scoring_role_assignments
    WHERE user_id = v_actor AND role_name = 'scoring_administrator')
    THEN RAISE EXCEPTION 'Scoring Administrator access required' USING ERRCODE = '42501'; END IF;
  IF p_action = 'grant' THEN
    INSERT INTO public.scoring_role_assignments (user_id, role_name, assigned_by)
      VALUES (p_target_user_id, 'jury_member', v_actor)
      ON CONFLICT (user_id, role_name) DO NOTHING;
    GET DIAGNOSTICS v_changed = ROW_COUNT;
  ELSE
    DELETE FROM public.scoring_role_assignments
      WHERE user_id = p_target_user_id AND role_name = 'jury_member';
    GET DIAGNOSTICS v_changed = ROW_COUNT;
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'outcome', CASE WHEN v_changed = 1 THEN p_action || 'ed' ELSE 'already_' || p_action || 'ed' END
  );
END
$function$;
ALTER FUNCTION public.manage_jury_member_role(uuid, text, text) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.manage_jury_member_role(uuid, text, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.manage_jury_member_role(uuid, text, text) TO authenticated;

CREATE FUNCTION public.get_jury_rubric(p_assignment_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE v_actor uuid := javaneh_private.current_uid(); v_assignment public.jury_assignments%ROWTYPE;
BEGIN
  SELECT a.* INTO v_assignment FROM public.jury_assignments a
   WHERE a.assignment_id = p_assignment_id AND a.juror_id = v_actor;
  IF NOT FOUND THEN RAISE EXCEPTION 'Jury assignment access denied' USING ERRCODE = '42501'; END IF;
  RETURN pg_catalog.jsonb_build_object(
    'assignment_id', v_assignment.assignment_id,
    'idea_id', v_assignment.idea_id,
    'dossier_revision', v_assignment.dossier_revision,
    'rubric_version', (SELECT rubric_version FROM public.jury_rubric_criteria
      WHERE configuration_version_id = v_assignment.configuration_version_id LIMIT 1),
    'criteria', (SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'criterion_key', criterion_key, 'display_name', display_name,
      'description', description, 'maximum_points', maximum_points
    ) ORDER BY sort_order) FROM public.jury_rubric_criteria
      WHERE configuration_version_id = v_assignment.configuration_version_id),
    'dossier', (SELECT dossier FROM public.idea_dossier_versions
      WHERE idea_id = v_assignment.idea_id AND revision = v_assignment.dossier_revision)
  );
END
$function$;
ALTER FUNCTION public.get_jury_rubric(uuid) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_jury_rubric(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_jury_rubric(uuid) TO authenticated;

CREATE FUNCTION public.declare_jury_conflict(
  p_assignment_id uuid, p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE v_actor uuid := javaneh_private.current_uid();
BEGIN
  UPDATE public.jury_assignments SET conflict_declared = true,
    conflict_reason = p_reason, status = 'recused',
    conflict_declared_at = pg_catalog.clock_timestamp()
   WHERE assignment_id = p_assignment_id AND juror_id = v_actor
     AND pg_catalog.length(pg_catalog.btrim(p_reason)) > 0;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('outcome', 'not_found'); END IF;
  RETURN pg_catalog.jsonb_build_object('outcome', 'recused');
END
$function$;
ALTER FUNCTION public.declare_jury_conflict(uuid, text) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.declare_jury_conflict(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.declare_jury_conflict(uuid, text) TO authenticated;

CREATE FUNCTION public.submit_jury_evaluation(
  p_assignment_id uuid, p_scores jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.current_uid();
  v_assignment public.jury_assignments%ROWTYPE;
  v_evaluation uuid;
  v_total integer;
  v_score jsonb;
  v_criterion public.jury_rubric_criteria%ROWTYPE;
  v_level integer;
  v_points integer;
BEGIN
  SELECT a.* INTO v_assignment FROM public.jury_assignments a
   WHERE a.assignment_id = p_assignment_id AND a.juror_id = v_actor
   FOR UPDATE;
  IF NOT FOUND OR v_assignment.status <> 'assigned' OR v_assignment.conflict_declared
    THEN RAISE EXCEPTION 'Jury assignment is not available' USING ERRCODE = '42501'; END IF;
  IF pg_catalog.jsonb_typeof(p_scores) <> 'array'
    OR pg_catalog.jsonb_array_length(p_scores) <> 7 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_scores');
  END IF;
  INSERT INTO public.jury_evaluations (
    assignment_id, idea_id, juror_id, configuration_version_id, rubric_version, total_points
  ) SELECT p_assignment_id, v_assignment.idea_id, v_actor,
    v_assignment.configuration_version_id, c.rubric_version, 0
    FROM public.jury_rubric_criteria c WHERE c.configuration_version_id =
      v_assignment.configuration_version_id LIMIT 1
  RETURNING evaluation_id INTO v_evaluation;
  FOR v_score IN SELECT * FROM pg_catalog.jsonb_array_elements(p_scores) LOOP
    SELECT c.* INTO v_criterion FROM public.jury_rubric_criteria c
     WHERE c.configuration_version_id = v_assignment.configuration_version_id
       AND c.criterion_key = v_score->>'criterion_key';
    v_level := (v_score->>'level')::integer;
    IF NOT FOUND OR v_level NOT BETWEEN 0 AND 4
      OR pg_catalog.length(pg_catalog.btrim(v_score->>'justification')) = 0 THEN
      RAISE EXCEPTION 'Invalid jury criterion score' USING ERRCODE = '23514';
    END IF;
    v_points := (v_criterion.maximum_points * v_level) / 4;
    v_total := COALESCE(v_total, 0) + v_points;
    INSERT INTO public.jury_evaluation_scores (
      evaluation_id, criterion_key, level, points, justification, evidence_reference
    ) VALUES (
      v_evaluation, v_criterion.criterion_key, v_level, v_points,
      v_score->>'justification', v_score->>'evidence_reference'
    );
  END LOOP;
  IF (SELECT count(*) FROM public.jury_evaluation_scores WHERE evaluation_id = v_evaluation) <> 7 THEN
    RAISE EXCEPTION 'All seven jury criteria are required' USING ERRCODE = '23514';
  END IF;
  UPDATE public.jury_evaluations SET total_points = v_total WHERE evaluation_id = v_evaluation;
  UPDATE public.jury_assignments SET status = 'submitted' WHERE assignment_id = p_assignment_id;
  RETURN pg_catalog.jsonb_build_object('outcome', 'submitted', 'evaluation_id', v_evaluation, 'total_points', v_total);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_scores');
END
$function$;
ALTER FUNCTION public.submit_jury_evaluation(uuid, jsonb) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.submit_jury_evaluation(uuid, jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.submit_jury_evaluation(uuid, jsonb) TO authenticated;

CREATE FUNCTION public.get_assigned_jury_ideas()
RETURNS SETOF jsonb LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
  SELECT pg_catalog.jsonb_build_object(
    'assignment_id', a.assignment_id, 'idea_id', a.idea_id,
    'dossier_revision', a.dossier_revision, 'status', a.status,
    'conflict_declared', a.conflict_declared
  ) FROM public.jury_assignments a
  WHERE a.juror_id = javaneh_private.current_uid()
  ORDER BY a.assigned_at;
$function$;
ALTER FUNCTION public.get_assigned_jury_ideas() OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_assigned_jury_ideas() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_assigned_jury_ideas() TO authenticated;

CREATE FUNCTION public.approve_jury_publication(
  p_idea_id uuid, p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.current_uid();
  v_assignment public.jury_assignments%ROWTYPE;
  v_version uuid;
  v_total numeric;
  v_averages jsonb;
  v_publication uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.scoring_role_assignments
    WHERE user_id = v_actor AND role_name = 'scoring_administrator')
    THEN RAISE EXCEPTION 'Scoring Administrator access required' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR pg_catalog.length(pg_catalog.btrim(p_reason)) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  SELECT a.configuration_version_id INTO v_version FROM public.jury_assignments a
   WHERE a.idea_id = p_idea_id LIMIT 1;
  IF v_version IS NULL OR (SELECT count(*) FROM public.jury_assignments
    WHERE idea_id = p_idea_id AND status = 'submitted' AND NOT conflict_declared) <> 3
    THEN RETURN pg_catalog.jsonb_build_object('outcome', 'incomplete'); END IF;
  SELECT pg_catalog.avg(e.total_points)::numeric(7,2) INTO v_total
    FROM public.jury_evaluations e JOIN public.jury_assignments a
      ON a.assignment_id = e.assignment_id
   WHERE a.idea_id = p_idea_id AND e.status = 'submitted';
  SELECT pg_catalog.jsonb_object_agg(s.criterion_key, s.average_points) INTO v_averages
    FROM (SELECT score.criterion_key, pg_catalog.round(pg_catalog.avg(score.points), 2) average_points
      FROM public.jury_evaluation_scores score JOIN public.jury_evaluations e
        ON e.evaluation_id = score.evaluation_id JOIN public.jury_assignments a
        ON a.assignment_id = e.assignment_id
      WHERE a.idea_id = p_idea_id GROUP BY score.criterion_key) s;
  INSERT INTO public.jury_publications (
    idea_id, configuration_version_id, rubric_version, final_score,
    criterion_averages, approved_by, approval_reason
  ) VALUES (p_idea_id, v_version, 'jury-v1', v_total, v_averages, v_actor, p_reason)
  ON CONFLICT (idea_id, configuration_version_id) DO NOTHING
  RETURNING publication_id INTO v_publication;
  RETURN pg_catalog.jsonb_build_object('outcome',
    CASE WHEN v_publication IS NULL THEN 'already_approved' ELSE 'approved' END,
    'publication_id', COALESCE(v_publication, (SELECT publication_id FROM public.jury_publications
      WHERE idea_id = p_idea_id AND configuration_version_id = v_version)));
END
$function$;
ALTER FUNCTION public.approve_jury_publication(uuid, text) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.approve_jury_publication(uuid, text) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.approve_jury_publication(uuid, text) TO authenticated;

CREATE FUNCTION public.publish_jury_result(p_publication_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.current_uid();
  v_publication public.jury_publications%ROWTYPE;
  v_competition public.competitions%ROWTYPE;
  v_existing uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.scoring_role_assignments
    WHERE user_id = v_actor AND role_name = 'scoring_administrator')
    THEN RAISE EXCEPTION 'Scoring Administrator access required' USING ERRCODE = '42501'; END IF;
  SELECT p.* INTO v_publication FROM public.jury_publications p
   WHERE p.publication_id = p_publication_id FOR UPDATE;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('outcome', 'not_found'); END IF;
  IF v_publication.status = 'published' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_published');
  END IF;
  SELECT c.* INTO v_competition FROM public.competitions c
   WHERE c.scoring_configuration_version_id = v_publication.configuration_version_id
     AND c.status = 'active';
  INSERT INTO public.official_points_ledger (
    idempotency_key, user_id, idea_id, configuration_version_id, milestone_key,
    stage_number, entry_kind, points, source, source_reference, reason, recorded_by,
    competition_id, catalog_version
  )
  SELECT v_publication.publication_id, idea.owner_id, v_publication.idea_id,
    v_publication.configuration_version_id, 'jury-final', 7, 'award',
    v_publication.final_score, 'human_jury', v_publication.publication_id,
    'Published human jury result.', v_actor, v_competition.id, 'jury-v1'
  FROM public.ideas idea WHERE idea.id = v_publication.idea_id
  ON CONFLICT DO NOTHING
  RETURNING entry_id INTO v_existing;
  UPDATE public.jury_publications SET status = 'published',
    published_by = v_actor, published_at = pg_catalog.clock_timestamp()
   WHERE publication_id = p_publication_id;
  RETURN pg_catalog.jsonb_build_object(
    'outcome', CASE WHEN v_existing IS NULL THEN 'already_published' ELSE 'published' END,
    'publication_id', p_publication_id
  );
END
$function$;
ALTER FUNCTION public.publish_jury_result(uuid) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.publish_jury_result(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.publish_jury_result(uuid) TO authenticated;

CREATE FUNCTION public.get_jury_operations_queue()
RETURNS SETOF jsonb LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
  SELECT pg_catalog.jsonb_build_object(
    'idea_id', idea.id,
    'competition_id', idea.competition_id,
    'assignments', (
      SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'assignment_id', assignment.assignment_id,
        'juror_id', assignment.juror_id,
        'status', assignment.status,
        'conflict_declared', assignment.conflict_declared
      ) ORDER BY assignment.assigned_at), '[]'::jsonb)
      FROM public.jury_assignments assignment
      WHERE assignment.idea_id = idea.id
    ),
    'publication', (
      SELECT pg_catalog.jsonb_build_object(
        'publication_id', publication.publication_id,
        'status', publication.status,
        'final_score', publication.final_score
      )
      FROM public.jury_publications publication
      WHERE publication.idea_id = idea.id
    )
  )
  FROM public.ideas idea
  WHERE idea.status = 'submitted'
    AND EXISTS (
      SELECT 1 FROM public.scoring_role_assignments role_assignment
      WHERE role_assignment.user_id = javaneh_private.current_uid()
        AND role_assignment.role_name = 'scoring_administrator'
    )
  ORDER BY idea.submitted_at, idea.id;
$function$;
ALTER FUNCTION public.get_jury_operations_queue() OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_jury_operations_queue() FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_jury_operations_queue() TO authenticated;

CREATE FUNCTION public.get_participant_published_jury_score(p_idea_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
AS $function$
  SELECT CASE WHEN p.status = 'published' AND i.owner_id = javaneh_private.current_uid()
    THEN pg_catalog.jsonb_build_object(
      'state', 'published', 'final_score', p.final_score,
      'maximum_points', 300, 'criterion_averages', p.criterion_averages
    )
    ELSE pg_catalog.jsonb_build_object('state', 'unpublished')
  END
  FROM public.ideas i LEFT JOIN public.jury_publications p
    ON p.idea_id = i.id AND p.status = 'published'
  WHERE i.id = p_idea_id AND i.owner_id = javaneh_private.current_uid();
$function$;
ALTER FUNCTION public.get_participant_published_jury_score(uuid) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_participant_published_jury_score(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_participant_published_jury_score(uuid) TO authenticated;

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
