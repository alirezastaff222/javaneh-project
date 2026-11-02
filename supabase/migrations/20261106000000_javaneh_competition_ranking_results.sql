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

CREATE TABLE public.competition_result_versions (
  result_version_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  competition_id uuid NOT NULL REFERENCES public.competitions(id) ON DELETE RESTRICT,
  version_number integer NOT NULL CHECK (version_number > 0),
  status text NOT NULL DEFAULT 'prepared'
    CHECK (status IN ('prepared', 'approved', 'published')),
  prepared_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  prepared_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  approved_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  approved_at timestamptz,
  published_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  published_at timestamptz,
  supersedes_version_id uuid REFERENCES public.competition_result_versions(result_version_id)
    ON DELETE RESTRICT,
  reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(reason)) > 0),
  UNIQUE (competition_id, version_number),
  CONSTRAINT competition_result_versions_state_shape CHECK (
    (status = 'prepared' AND approved_by IS NULL AND approved_at IS NULL
      AND published_by IS NULL AND published_at IS NULL)
    OR (status = 'approved' AND approved_by IS NOT NULL AND approved_at IS NOT NULL
      AND published_by IS NULL AND published_at IS NULL)
    OR (status = 'published' AND approved_by IS NOT NULL AND approved_at IS NOT NULL
      AND published_by IS NOT NULL AND published_at IS NOT NULL)
  )
);

CREATE TABLE public.competition_result_entries (
  result_version_id uuid NOT NULL
    REFERENCES public.competition_result_versions(result_version_id) ON DELETE RESTRICT,
  idea_id uuid NOT NULL REFERENCES public.ideas(id) ON DELETE RESTRICT,
  development_score numeric(10,2) NOT NULL CHECK (development_score BETWEEN 0 AND 700),
  jury_score numeric(10,2) CHECK (jury_score IS NULL OR jury_score BETWEEN 0 AND 300),
  final_score numeric(10,2) CHECK (final_score IS NULL OR final_score BETWEEN 0 AND 1000),
  eligibility text NOT NULL CHECK (eligibility IN ('ranked', 'pending')),
  rank integer CHECK (rank IS NULL OR rank > 0),
  PRIMARY KEY (result_version_id, idea_id),
  CONSTRAINT competition_result_entry_shape CHECK (
    (eligibility = 'ranked'
      AND jury_score IS NOT NULL
      AND final_score = development_score + jury_score
      AND rank IS NOT NULL)
    OR (eligibility = 'pending'
      AND jury_score IS NULL
      AND final_score IS NULL
      AND rank IS NULL)
  )
);

CREATE TABLE public.competition_result_events (
  event_id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  result_version_id uuid NOT NULL
    REFERENCES public.competition_result_versions(result_version_id) ON DELETE RESTRICT,
  competition_id uuid NOT NULL REFERENCES public.competitions(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('prepared', 'approved', 'published')),
  actor_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  reason text NOT NULL CHECK (pg_catalog.length(pg_catalog.btrim(reason)) > 0),
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);

CREATE FUNCTION public.reject_competition_result_event_change()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog
AS $function$
BEGIN
  RAISE EXCEPTION 'Competition result events are immutable'
    USING ERRCODE = '42501';
END
$function$;
ALTER FUNCTION public.reject_competition_result_event_change()
  OWNER TO javaneh_identity_executor;
CREATE TRIGGER competition_result_events_immutable
  BEFORE UPDATE OR DELETE ON public.competition_result_events
  FOR EACH ROW EXECUTE FUNCTION public.reject_competition_result_event_change();

ALTER TABLE public.competition_result_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competition_result_versions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.competition_result_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competition_result_entries FORCE ROW LEVEL SECURITY;
ALTER TABLE public.competition_result_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competition_result_events FORCE ROW LEVEL SECURITY;

CREATE POLICY competition_results_executor_all
  ON public.competition_result_versions FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY competition_result_entries_executor_all
  ON public.competition_result_entries FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);
CREATE POLICY competition_result_events_executor_all
  ON public.competition_result_events FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

REVOKE ALL ON TABLE
  public.competition_result_versions,
  public.competition_result_entries,
  public.competition_result_events
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.competition_result_versions,
  public.competition_result_entries,
  public.competition_result_events
  TO javaneh_identity_executor;

CREATE FUNCTION public.guard_competition_result_history()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog
AS $function$
BEGIN
  IF TG_OP = 'DELETE' OR (
    TG_OP = 'UPDATE' AND (
      OLD.status = 'published'
      OR OLD.competition_id IS DISTINCT FROM NEW.competition_id
      OR OLD.version_number IS DISTINCT FROM NEW.version_number
      OR OLD.prepared_by IS DISTINCT FROM NEW.prepared_by
      OR OLD.prepared_at IS DISTINCT FROM NEW.prepared_at
      OR OLD.supersedes_version_id IS DISTINCT FROM NEW.supersedes_version_id
      OR OLD.reason IS DISTINCT FROM NEW.reason
      OR NOT (
        (OLD.status = 'prepared' AND NEW.status = 'approved')
        OR (OLD.status = 'approved' AND NEW.status = 'published')
      )
    )
  ) THEN
    RAISE EXCEPTION 'Published result versions are immutable'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;
ALTER FUNCTION public.guard_competition_result_history()
  OWNER TO javaneh_identity_executor;

CREATE TRIGGER competition_result_versions_immutable
  BEFORE UPDATE OR DELETE ON public.competition_result_versions
  FOR EACH ROW EXECUTE FUNCTION public.guard_competition_result_history();

CREATE FUNCTION public.guard_published_result_entries()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog
AS $function$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.competition_result_versions AS version
    WHERE version.result_version_id = COALESCE(NEW.result_version_id, OLD.result_version_id)
      AND version.status = 'published'
  ) THEN
    RAISE EXCEPTION 'Published result entries are immutable'
      USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END
$function$;
ALTER FUNCTION public.guard_published_result_entries()
  OWNER TO javaneh_identity_executor;
CREATE TRIGGER competition_result_entries_immutable
  BEFORE INSERT OR UPDATE OR DELETE ON public.competition_result_entries
  FOR EACH ROW EXECUTE FUNCTION public.guard_published_result_entries();

CREATE FUNCTION public.prepare_competition_results(
  p_competition_id uuid, p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.current_uid();
  v_competition public.competitions%ROWTYPE;
  v_version_id uuid;
  v_version_number integer;
  v_previous uuid;
BEGIN
  IF v_actor IS NULL OR p_reason IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_reason)) = 0 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.scoring_role_assignments
    WHERE user_id = v_actor AND role_name = 'scoring_administrator'
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator access required' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('javaneh:results:' || p_competition_id::text, 0)
  );
  SELECT * INTO v_competition FROM public.competitions
  WHERE id = p_competition_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
  END IF;
  IF v_competition.status <> 'closed' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'competition_not_closed');
  END IF;

  SELECT result_version_id INTO v_previous
  FROM public.competition_result_versions
  WHERE competition_id = p_competition_id AND status = 'published'
  ORDER BY version_number DESC LIMIT 1;
  SELECT COALESCE(max(version_number), 0) + 1 INTO v_version_number
  FROM public.competition_result_versions
  WHERE competition_id = p_competition_id;

  INSERT INTO public.competition_result_versions (
    competition_id, version_number, prepared_by, reason, supersedes_version_id
  ) VALUES (
    p_competition_id, v_version_number, v_actor, p_reason, v_previous
  ) RETURNING result_version_id INTO v_version_id;

  INSERT INTO public.competition_result_entries (
    result_version_id, idea_id, development_score, jury_score,
    final_score, eligibility, rank
  )
  WITH candidates AS (
    SELECT idea.id AS idea_id,
      COALESCE((
        SELECT sum(ledger.points)
        FROM public.official_points_ledger AS ledger
        WHERE ledger.idea_id = idea.id
          AND ledger.competition_id = p_competition_id
          AND ledger.configuration_version_id =
            v_competition.scoring_configuration_version_id
          AND ledger.stage_number BETWEEN 1 AND 6
      ), 0)::numeric(10,2) AS development_score,
      jury.final_score AS jury_score
    FROM public.ideas AS idea
    LEFT JOIN public.jury_publications AS jury
      ON jury.idea_id = idea.id
     AND jury.configuration_version_id = v_competition.scoring_configuration_version_id
     AND jury.status = 'published'
    WHERE idea.competition_id = p_competition_id
      AND idea.status = 'submitted'
  ), ranked AS (
    SELECT candidates.*,
      'ranked' AS eligibility,
      development_score + jury_score AS final_score,
      rank() OVER (ORDER BY development_score + jury_score DESC)::integer AS rank
    FROM candidates
    WHERE jury_score IS NOT NULL
  ), pending AS (
    SELECT candidates.*, 'pending' AS eligibility,
      NULL::numeric(10,2) AS final_score, NULL::integer AS rank
    FROM candidates
    WHERE jury_score IS NULL
  )
  SELECT v_version_id, result.idea_id, result.development_score, result.jury_score,
    result.final_score, result.eligibility, result.rank
  FROM (SELECT * FROM ranked UNION ALL SELECT * FROM pending) AS result;

  INSERT INTO public.competition_result_events (
    result_version_id, competition_id, event_type, actor_user_id, reason
  ) VALUES (v_version_id, p_competition_id, 'prepared', v_actor, p_reason);
  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'prepared', 'result_version_id', v_version_id,
    'version_number', v_version_number
  );
END
$function$;
ALTER FUNCTION public.prepare_competition_results(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.prepare_competition_results(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.prepare_competition_results(uuid, text)
  TO authenticated;

CREATE FUNCTION public.approve_competition_results(
  p_result_version_id uuid, p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE v_actor uuid := javaneh_private.current_uid(); v_version public.competition_result_versions%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.scoring_role_assignments
    WHERE user_id = v_actor AND role_name = 'scoring_administrator')
    THEN RAISE EXCEPTION 'Scoring Administrator access required' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR pg_catalog.length(pg_catalog.btrim(p_reason)) = 0
    THEN RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input'); END IF;
  SELECT * INTO v_version FROM public.competition_result_versions
    WHERE result_version_id = p_result_version_id FOR UPDATE;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('outcome', 'not_found'); END IF;
  IF v_version.status <> 'prepared' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_state');
  END IF;
  UPDATE public.competition_result_versions
  SET status = 'approved', approved_by = v_actor,
      approved_at = pg_catalog.clock_timestamp()
  WHERE result_version_id = p_result_version_id;
  INSERT INTO public.competition_result_events
    (result_version_id, competition_id, event_type, actor_user_id, reason)
  VALUES (p_result_version_id, v_version.competition_id, 'approved', v_actor, p_reason);
  RETURN pg_catalog.jsonb_build_object('outcome', 'approved');
END
$function$;
ALTER FUNCTION public.approve_competition_results(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.approve_competition_results(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.approve_competition_results(uuid, text)
  TO authenticated;

CREATE FUNCTION public.publish_competition_results(
  p_result_version_id uuid, p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor uuid := javaneh_private.current_uid();
  v_version public.competition_result_versions%ROWTYPE;
  v_competition public.competitions%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.scoring_role_assignments
    WHERE user_id = v_actor AND role_name = 'scoring_administrator')
    THEN RAISE EXCEPTION 'Scoring Administrator access required' USING ERRCODE = '42501'; END IF;
  IF p_reason IS NULL OR pg_catalog.length(pg_catalog.btrim(p_reason)) = 0
    THEN RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input'); END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('javaneh:results-publication:' || p_result_version_id::text, 0)
  );
  SELECT * INTO v_version FROM public.competition_result_versions
    WHERE result_version_id = p_result_version_id FOR UPDATE;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('outcome', 'not_found'); END IF;
  SELECT * INTO v_competition FROM public.competitions
    WHERE id = v_version.competition_id FOR SHARE;
  IF v_competition.status <> 'closed' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'competition_not_closed');
  END IF;
  IF v_version.status = 'published' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_published');
  END IF;
  IF v_version.status <> 'approved' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'approval_required');
  END IF;
  UPDATE public.competition_result_versions
  SET status = 'published', published_by = v_actor,
      published_at = pg_catalog.clock_timestamp()
  WHERE result_version_id = p_result_version_id;
  INSERT INTO public.competition_result_events
    (result_version_id, competition_id, event_type, actor_user_id, reason)
  VALUES (p_result_version_id, v_version.competition_id, 'published', v_actor, p_reason);
  RETURN pg_catalog.jsonb_build_object('outcome', 'published');
END
$function$;
ALTER FUNCTION public.publish_competition_results(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.publish_competition_results(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.publish_competition_results(uuid, text)
  TO authenticated;

CREATE FUNCTION public.get_competition_results_admin(p_competition_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER STABLE SET search_path = pg_catalog
AS $function$
  SELECT CASE WHEN NOT EXISTS (
    SELECT 1 FROM public.scoring_role_assignments
    WHERE user_id = javaneh_private.current_uid()
      AND role_name = 'scoring_administrator'
  ) THEN pg_catalog.jsonb_build_object('error', 'Scoring Administrator access required')
  ELSE (
  SELECT pg_catalog.jsonb_build_object(
    'competition_id', competition.id,
    'status', competition.status,
    'versions', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'result_version_id', version.result_version_id,
        'version_number', version.version_number,
        'status', version.status,
        'prepared_at', version.prepared_at,
        'approved_at', version.approved_at,
        'published_at', version.published_at
      ) ORDER BY version.version_number DESC)
      FROM public.competition_result_versions AS version
      WHERE version.competition_id = competition.id
    ), '[]'::jsonb),
    'entries', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'result_version_id', entry.result_version_id,
        'idea_id', entry.idea_id,
        'development_score', entry.development_score,
        'jury_score', entry.jury_score,
        'final_score', entry.final_score,
        'eligibility', entry.eligibility,
        'rank', entry.rank
      ) ORDER BY entry.rank NULLS LAST, entry.idea_id)
      FROM public.competition_result_entries AS entry
      JOIN public.competition_result_versions AS version
        ON version.result_version_id = entry.result_version_id
      WHERE version.competition_id = competition.id
        AND version.result_version_id = (
          SELECT latest.result_version_id
          FROM public.competition_result_versions AS latest
          WHERE latest.competition_id = competition.id
          ORDER BY latest.version_number DESC LIMIT 1
        )
    ), '[]'::jsonb)
  )
  FROM public.competitions AS competition
  WHERE competition.id = p_competition_id
  ) END;
$function$;
ALTER FUNCTION public.get_competition_results_admin(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_competition_results_admin(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_competition_results_admin(uuid)
  TO authenticated;

CREATE FUNCTION public.get_participant_published_result(p_idea_id uuid)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER STABLE SET search_path = pg_catalog
AS $function$
  SELECT CASE WHEN idea.owner_id = javaneh_private.current_uid()
       AND version.status = 'published'
    THEN pg_catalog.jsonb_build_object(
      'state', 'published',
      'competition_id', version.competition_id,
      'result_version_id', version.result_version_id,
      'version_number', version.version_number,
      'development_score', entry.development_score,
      'jury_score', entry.jury_score,
      'final_score', entry.final_score,
      'rank', entry.rank
    )
    ELSE pg_catalog.jsonb_build_object('state', 'unpublished')
  END
  FROM public.ideas AS idea
  LEFT JOIN public.competition_result_entries AS entry ON entry.idea_id = idea.id
  LEFT JOIN public.competition_result_versions AS version
    ON version.result_version_id = entry.result_version_id
   AND version.status = 'published'
  WHERE idea.id = p_idea_id
    AND idea.owner_id = javaneh_private.current_uid()
  ORDER BY version.version_number DESC NULLS LAST
  LIMIT 1;
$function$;
ALTER FUNCTION public.get_participant_published_result(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_participant_published_result(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_participant_published_result(uuid)
  TO authenticated;

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
