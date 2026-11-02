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

ALTER TABLE public.official_points_ledger
  ADD COLUMN competition_id uuid
    REFERENCES public.competitions(id) ON DELETE RESTRICT,
  ADD COLUMN catalog_version text,
  ADD COLUMN validation_request_id uuid
    REFERENCES public.milestone_validation_requests(request_id) ON DELETE RESTRICT,
  ADD COLUMN evaluation_level smallint
    CHECK (evaluation_level IS NULL OR evaluation_level BETWEEN 0 AND 4),
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

CREATE UNIQUE INDEX official_points_ledger_one_award_per_validation_request
  ON public.official_points_ledger (validation_request_id)
  WHERE entry_kind = 'award' AND validation_request_id IS NOT NULL;
CREATE INDEX official_points_ledger_competition_history_idx
  ON public.official_points_ledger (competition_id, recorded_at DESC)
  WHERE competition_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.calculate_scoring_milestone_points(
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
  SELECT CASE
    WHEN milestone.validation_mode = 'objective'
      AND p_evaluation_level IS NULL
      THEN milestone.point_value
    WHEN milestone.validation_mode IN ('qualitative', 'hybrid')
      AND p_evaluation_level BETWEEN 0 AND 4
      THEN pg_catalog.floor(
        milestone.point_value::numeric * level.multiplier
      )::integer
    ELSE NULL
  END
  FROM public.scoring_milestone_catalog AS milestone
  LEFT JOIN public.scoring_evaluation_levels AS level
    ON level.configuration_version_id = milestone.configuration_version_id
   AND level.evaluation_level = p_evaluation_level
  WHERE milestone.configuration_version_id = p_configuration_version_id
    AND milestone.milestone_key = p_milestone_key
$function$;
GRANT CREATE ON SCHEMA public TO javaneh_identity_executor;
ALTER FUNCTION public.calculate_scoring_milestone_points(uuid, text, smallint)
  OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.calculate_scoring_milestone_points(uuid, text, smallint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.calculate_scoring_milestone_points(uuid, text, smallint)
  TO authenticated;

DROP TRIGGER official_points_ledger_m9r4_award_guard
  ON public.official_points_ledger;
DROP FUNCTION public.block_award_for_validation_request();

CREATE OR REPLACE FUNCTION public.guard_official_points_ledger()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $function$
DECLARE
  v_version_status text;
  v_development_max integer;
  v_overall_max integer;
  v_milestone public.scoring_milestone_catalog%ROWTYPE;
  v_stage_max integer;
  v_competition_id uuid;
  v_request public.milestone_validation_requests%ROWTYPE;
  v_validation public.milestone_validations%ROWTYPE;
  v_original public.official_points_ledger%ROWTYPE;
  v_expected_points integer;
  v_stage_points bigint;
  v_development_points bigint;
  v_overall_points bigint;
  v_eligible boolean;
BEGIN
  IF NEW.entry_kind = 'award' AND NEW.source = 'human_jury' THEN
    RETURN NEW;
  END IF;

  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'Official points ledger entries are append-only'
      USING ERRCODE = '42501';
  END IF;

  SELECT version.status, version.development_max_points,
         version.overall_max_points
    INTO v_version_status, v_development_max, v_overall_max
    FROM public.scoring_configuration_versions AS version
    WHERE version.id = NEW.configuration_version_id;
  SELECT milestone.* INTO v_milestone
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = NEW.configuration_version_id
      AND milestone.milestone_key = NEW.milestone_key;

  IF NEW.entry_kind = 'award' THEN
    IF v_version_status IS DISTINCT FROM 'active'
       OR NOT FOUND
       OR NOT v_milestone.is_active
       OR NEW.stage_number = 7
       OR NEW.stage_number IS DISTINCT FROM v_milestone.stage_number THEN
      RAISE EXCEPTION 'Award does not match an active approved milestone'
        USING ERRCODE = '42501';
    END IF;

    IF NEW.validation_request_id IS NOT NULL THEN
      SELECT request.* INTO v_request
        FROM public.milestone_validation_requests AS request
        WHERE request.request_id = NEW.validation_request_id;
      IF NOT FOUND
         OR v_milestone.catalog_version IS NULL
         OR NEW.catalog_version IS DISTINCT FROM v_milestone.catalog_version
         OR NEW.stage_number NOT BETWEEN 1 AND 6
         OR NEW.source <> 'milestone_validation'
         OR NEW.competition_id IS NULL
         OR v_request.idea_id IS DISTINCT FROM NEW.idea_id
         OR v_request.participant_id IS DISTINCT FROM NEW.user_id
         OR v_request.configuration_version_id
           IS DISTINCT FROM NEW.configuration_version_id
         OR v_request.milestone_key IS DISTINCT FROM NEW.milestone_key
         OR v_request.catalog_version IS DISTINCT FROM NEW.catalog_version
         OR v_request.stage_number IS DISTINCT FROM NEW.stage_number
         OR v_request.status <> 'validated'
         OR v_request.idea_revision IS DISTINCT FROM (
           SELECT idea.revision
             FROM public.ideas AS idea
             WHERE idea.id = NEW.idea_id
               AND idea.owner_id = NEW.user_id
         )
         OR NOT public.milestone_validation_is_operational(
           NEW.configuration_version_id, NEW.milestone_key
         )
         OR NOT EXISTS (
           SELECT 1
             FROM public.competitions AS competition
             WHERE competition.id = NEW.competition_id
               AND competition.scoring_configuration_version_id =
                   NEW.configuration_version_id
               AND competition.status = 'active'
         ) THEN
        RAISE EXCEPTION 'Award does not match an eligible active validation request'
          USING ERRCODE = '42501';
      END IF;

      SELECT (public.get_milestone_scoring_eligibility(
        NEW.validation_request_id
      )->>'eligible')::boolean INTO v_eligible;
      IF v_eligible IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'M9R4 scoring eligibility is required before awarding'
          USING ERRCODE = '42501';
      END IF;

      IF v_request.validation_mode = 'objective' THEN
        IF NEW.evaluation_level IS NOT NULL
           OR NEW.source_reference IS DISTINCT FROM v_request.request_id THEN
          RAISE EXCEPTION 'Objective award must reference its evaluated request'
            USING ERRCODE = '23514';
        END IF;
        IF NEW.recorded_by IS DISTINCT FROM v_request.participant_id THEN
          RAISE EXCEPTION 'Objective award actor must be the submitting participant'
            USING ERRCODE = '42501';
        END IF;
        v_expected_points := public.calculate_scoring_milestone_points(
          NEW.configuration_version_id, NEW.milestone_key, NULL
        );
      ELSE
        SELECT validation.* INTO v_validation
          FROM public.milestone_validations AS validation
          WHERE validation.validation_request_id = v_request.request_id;
        IF NOT FOUND
           OR v_validation.decision <> 'approved'
           OR v_validation.outcome <> 'validated'
           OR v_validation.evaluation_level IS NULL
           OR NEW.evaluation_level IS DISTINCT FROM
             v_validation.evaluation_level
           OR NEW.source_reference IS DISTINCT FROM v_validation.validation_id
           OR NEW.recorded_by IS DISTINCT FROM v_validation.validator_id THEN
          RAISE EXCEPTION 'Human award must reference its approved validation decision'
            USING ERRCODE = '42501';
        END IF;
        v_expected_points := public.calculate_scoring_milestone_points(
          NEW.configuration_version_id, NEW.milestone_key,
          v_validation.evaluation_level
        );
      END IF;
    ELSIF v_milestone.catalog_version IS NOT NULL THEN
      RAISE EXCEPTION 'Versioned catalog awards require M9R4 scoring eligibility'
        USING ERRCODE = '42501';
    ELSE
      IF NEW.competition_id IS NOT NULL
         OR NEW.catalog_version IS NOT NULL
         OR NEW.evaluation_level IS NOT NULL THEN
        RAISE EXCEPTION 'Legacy award cannot assert versioned scoring metadata'
          USING ERRCODE = '23514';
      END IF;
      v_expected_points := v_milestone.point_value;
    END IF;

    IF v_expected_points IS NULL
       OR v_expected_points <= 0
       OR NEW.points IS DISTINCT FROM v_expected_points
       OR NEW.points > v_milestone.point_value THEN
      RAISE EXCEPTION 'Award points do not match the configured milestone result'
        USING ERRCODE = '23514';
    END IF;

    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'javaneh:score-budget:v1:' || NEW.configuration_version_id::text
          || ':' || NEW.idea_id::text,
        0
      )
    );
    SELECT stage.maximum_points INTO v_stage_max
      FROM public.scoring_stage_catalog AS stage
      WHERE stage.configuration_version_id = NEW.configuration_version_id
        AND stage.stage_number = NEW.stage_number;
    IF NEW.validation_request_id IS NOT NULL AND v_stage_max IS NULL THEN
      RAISE EXCEPTION 'Versioned award requires a configured stage maximum'
        USING ERRCODE = '23514';
    END IF;
    IF v_stage_max IS NOT NULL THEN
      SELECT COALESCE(pg_catalog.sum(ledger.points), 0)
        INTO v_stage_points
        FROM public.official_points_ledger AS ledger
        WHERE ledger.idea_id = NEW.idea_id
          AND ledger.configuration_version_id = NEW.configuration_version_id
          AND ledger.stage_number = NEW.stage_number;
      IF v_stage_points + NEW.points > v_stage_max THEN
        RAISE EXCEPTION 'Award exceeds the configured stage maximum'
          USING ERRCODE = '23514';
      END IF;
    END IF;
    IF NEW.stage_number BETWEEN 1 AND 6 THEN
      SELECT COALESCE(pg_catalog.sum(ledger.points), 0)
        INTO v_development_points
        FROM public.official_points_ledger AS ledger
        WHERE ledger.idea_id = NEW.idea_id
          AND ledger.configuration_version_id = NEW.configuration_version_id
          AND ledger.stage_number BETWEEN 1 AND 6;
      IF v_development_points + NEW.points > v_development_max THEN
        RAISE EXCEPTION 'Award exceeds the configured development maximum'
          USING ERRCODE = '23514';
      END IF;
    END IF;
    SELECT COALESCE(pg_catalog.sum(ledger.points), 0)
      INTO v_overall_points
      FROM public.official_points_ledger AS ledger
      WHERE ledger.idea_id = NEW.idea_id
        AND ledger.configuration_version_id = NEW.configuration_version_id;
    IF v_overall_points + NEW.points > v_overall_max THEN
      RAISE EXCEPTION 'Award exceeds the configured overall maximum'
        USING ERRCODE = '23514';
    END IF;
  ELSE
    IF NEW.original_entry_id IS NULL THEN
      RAISE EXCEPTION 'Compensation must reference an original award'
        USING ERRCODE = '23514';
    END IF;
    SELECT ledger.* INTO v_original
      FROM public.official_points_ledger AS ledger
      WHERE ledger.entry_id = NEW.original_entry_id;
    IF NOT FOUND
       OR v_original.entry_kind <> 'award'
       OR v_original.user_id IS DISTINCT FROM NEW.user_id
       OR v_original.idea_id IS DISTINCT FROM NEW.idea_id
       OR v_original.configuration_version_id
         IS DISTINCT FROM NEW.configuration_version_id
       OR v_original.milestone_key IS DISTINCT FROM NEW.milestone_key
       OR v_original.stage_number IS DISTINCT FROM NEW.stage_number
       OR NEW.points >= 0
       OR NEW.points < -v_original.points
       OR NEW.competition_id IS DISTINCT FROM v_original.competition_id
       OR NEW.catalog_version IS DISTINCT FROM v_original.catalog_version
       OR NEW.validation_request_id IS DISTINCT FROM
         v_original.validation_request_id
       OR NEW.evaluation_level IS DISTINCT FROM v_original.evaluation_level THEN
      RAISE EXCEPTION 'Compensation must preserve its original award references and remain within its value'
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
  v_request public.milestone_validation_requests%ROWTYPE;
  v_validation public.milestone_validations%ROWTYPE;
  v_idea public.ideas%ROWTYPE;
  v_version public.scoring_configuration_versions%ROWTYPE;
  v_milestone public.scoring_milestone_catalog%ROWTYPE;
  v_competition public.competitions%ROWTYPE;
  v_existing public.official_points_ledger%ROWTYPE;
  v_validation_id uuid;
  v_evaluation_level smallint;
  v_source_reference uuid;
  v_reason text;
  v_points integer;
  v_is_request boolean := false;
  v_constraint_name text;
  v_eligible boolean;
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

  SELECT request.* INTO v_request
    FROM public.milestone_validation_requests AS request
    WHERE request.request_id = p_validation_id;
  v_is_request := FOUND;
  IF v_is_request THEN
    IF v_request.validation_mode = 'objective' THEN
      IF v_request.participant_id <> v_actor_id THEN
        RAISE EXCEPTION 'Only the participant may request an objective award'
          USING ERRCODE = '42501';
      END IF;
    ELSE
      IF NOT EXISTS (
        SELECT 1
          FROM public.scoring_role_assignments AS role_assignment
          WHERE role_assignment.user_id = v_actor_id
            AND role_assignment.role_name = 'validator'
      ) THEN
        RAISE EXCEPTION 'Validator authorization required'
          USING ERRCODE = '42501';
      END IF;
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'javaneh:milestone-submission:v1:' || v_request.idea_id::text || ':'
          || v_request.configuration_version_id::text || ':'
          || v_request.milestone_key || ':' || v_request.idea_revision::text,
        0
      )
    );
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'javaneh:milestone-award:v1:' || v_request.idea_id::text || ':'
          || v_request.configuration_version_id::text || ':'
          || v_request.milestone_key,
        0
      )
    );
    SELECT idea.* INTO v_idea
      FROM public.ideas AS idea
      WHERE idea.id = v_request.idea_id
      FOR UPDATE;
    IF NOT FOUND OR v_idea.owner_id <> v_request.participant_id THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'ownership_changed');
    END IF;
    SELECT request.* INTO v_request
      FROM public.milestone_validation_requests AS request
      WHERE request.request_id = p_validation_id
      FOR UPDATE;
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
    END IF;
    IF v_request.validation_mode <> 'objective' THEN
      SELECT validation.* INTO v_validation
        FROM public.milestone_validations AS validation
        WHERE validation.validation_request_id = v_request.request_id;
      IF NOT FOUND OR v_validation.validator_id <> v_actor_id THEN
        RAISE EXCEPTION 'Only the deciding Validator may issue this award'
          USING ERRCODE = '42501';
      END IF;
      v_evaluation_level := v_validation.evaluation_level;
      v_validation_id := v_validation.validation_id;
      v_source_reference := v_validation.validation_id;
      v_reason := v_validation.reason;
    ELSE
      v_evaluation_level := NULL;
      v_validation_id := NULL;
      v_source_reference := v_request.request_id;
      v_reason := 'Configured objective milestone checks passed.';
    END IF;
    SELECT ledger.* INTO v_existing
      FROM public.official_points_ledger AS ledger
      WHERE ledger.entry_kind = 'award'
        AND ledger.idea_id = v_request.idea_id
        AND ledger.configuration_version_id =
          v_request.configuration_version_id
        AND ledger.milestone_key = v_request.milestone_key;
    IF FOUND THEN
      RETURN pg_catalog.jsonb_build_object(
        'outcome', 'already_awarded',
        'entry_id', v_existing.entry_id,
        'points', v_existing.points,
        'validation_request_id', v_existing.validation_request_id,
        'catalog_version', v_existing.catalog_version,
        'competition_id', v_existing.competition_id,
        'evaluation_level', v_existing.evaluation_level,
        'recorded_at', v_existing.recorded_at
      );
    END IF;
    SELECT (public.get_milestone_scoring_eligibility(
      v_request.request_id
    )->>'eligible')::boolean INTO v_eligible;
    IF v_eligible IS DISTINCT FROM true THEN
      RETURN pg_catalog.jsonb_build_object(
        'outcome', 'not_eligible',
        'request_id', v_request.request_id
      );
    END IF;
    IF v_request.stage_number NOT BETWEEN 1 AND 6 THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
    END IF;
  ELSE
    SELECT validation.* INTO v_validation
      FROM public.milestone_validations AS validation
      WHERE validation.validation_id = p_validation_id;
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_found');
    END IF;
    IF v_validation.validation_request_id IS NOT NULL THEN
      RETURN public.award_validated_milestone(
        v_validation.validation_request_id
      );
    END IF;
    IF NOT EXISTS (
      SELECT 1
        FROM public.scoring_role_assignments AS role_assignment
        WHERE role_assignment.user_id = v_actor_id
          AND role_assignment.role_name = 'validator'
    ) THEN
      RAISE EXCEPTION 'Validator authorization required'
        USING ERRCODE = '42501';
    END IF;
    IF v_validation.validator_id <> v_actor_id THEN
      RAISE EXCEPTION 'Only the approving Validator may issue this milestone award'
        USING ERRCODE = '42501';
    END IF;
    IF v_validation.decision <> 'approved' THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_approved');
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'javaneh:milestone-award:v1:' || v_validation.idea_id::text || ':'
          || v_validation.configuration_version_id::text || ':'
          || v_validation.milestone_key,
        0
      )
    );
    SELECT idea.* INTO v_idea
      FROM public.ideas AS idea
      WHERE idea.id = v_validation.idea_id
      FOR UPDATE;
    IF NOT FOUND OR v_idea.owner_id <> v_validation.participant_id THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'ownership_changed');
    END IF;
    SELECT ledger.* INTO v_existing
      FROM public.official_points_ledger AS ledger
      WHERE ledger.entry_kind = 'award'
        AND ledger.idea_id = v_validation.idea_id
        AND ledger.configuration_version_id =
          v_validation.configuration_version_id
        AND ledger.milestone_key = v_validation.milestone_key;
    IF FOUND THEN
      RETURN pg_catalog.jsonb_build_object(
        'outcome', 'already_awarded',
        'entry_id', v_existing.entry_id,
        'points', v_existing.points,
        'validation_request_id', v_existing.validation_request_id,
        'catalog_version', v_existing.catalog_version,
        'competition_id', v_existing.competition_id,
        'evaluation_level', v_existing.evaluation_level,
        'recorded_at', v_existing.recorded_at
      );
    END IF;
    IF v_validation.reviewed_revision <> v_idea.revision THEN
      RETURN pg_catalog.jsonb_build_object(
        'outcome', 'stale_evidence',
        'current_revision', v_idea.revision
      );
    END IF;
    v_evaluation_level := v_validation.evaluation_level;
    v_validation_id := v_validation.validation_id;
    v_source_reference := v_validation.validation_id;
    v_reason := v_validation.reason;
  END IF;

  SELECT version.* INTO v_version
    FROM public.scoring_configuration_versions AS version
    WHERE version.id = CASE WHEN v_is_request
      THEN v_request.configuration_version_id
      ELSE v_validation.configuration_version_id END
    FOR SHARE;
  SELECT milestone.* INTO v_milestone
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = v_version.id
      AND milestone.milestone_key = CASE WHEN v_is_request
        THEN v_request.milestone_key ELSE v_validation.milestone_key END
    FOR SHARE;
  IF NOT FOUND OR NOT v_milestone.is_active
     OR v_version.status <> 'active' THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
  END IF;
  IF v_milestone.stage_number = 7 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
  END IF;

  IF v_milestone.catalog_version IS NOT NULL THEN
    IF NOT v_is_request
       OR NOT public.milestone_validation_is_operational(
         v_version.id, v_milestone.milestone_key
       ) THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
    END IF;
    SELECT competition.* INTO v_competition
      FROM public.competitions AS competition
      WHERE competition.scoring_configuration_version_id = v_version.id
        AND competition.status = 'active'
      FOR SHARE;
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
    END IF;
    IF v_request.catalog_version IS DISTINCT FROM v_milestone.catalog_version
       OR v_request.stage_number IS DISTINCT FROM v_milestone.stage_number THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
    END IF;
    v_points := public.calculate_scoring_milestone_points(
      v_version.id, v_milestone.milestone_key, v_evaluation_level
    );
  ELSE
    IF v_is_request THEN
      RETURN pg_catalog.jsonb_build_object('outcome', 'not_eligible');
    END IF;
    v_competition.id := NULL;
    v_points := v_milestone.point_value;
    v_evaluation_level := NULL;
  END IF;

  IF v_points IS NULL OR v_points <= 0
     OR v_points > v_milestone.point_value THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'no_points_awarded');
  END IF;

  SELECT ledger.* INTO v_existing
    FROM public.official_points_ledger AS ledger
    WHERE ledger.entry_kind = 'award'
      AND ledger.idea_id = CASE WHEN v_is_request
        THEN v_request.idea_id ELSE v_validation.idea_id END
      AND ledger.configuration_version_id = v_version.id
      AND ledger.milestone_key = v_milestone.milestone_key;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_awarded',
      'entry_id', v_existing.entry_id,
      'points', v_existing.points,
      'validation_request_id', v_existing.validation_request_id,
      'catalog_version', v_existing.catalog_version,
      'competition_id', v_existing.competition_id,
      'evaluation_level', v_existing.evaluation_level,
      'recorded_at', v_existing.recorded_at
    );
  END IF;

  BEGIN
    INSERT INTO public.official_points_ledger (
      idempotency_key, user_id, idea_id, configuration_version_id,
      milestone_key, stage_number, entry_kind, points, source,
      source_reference, reason, recorded_by, competition_id,
      catalog_version, validation_request_id, evaluation_level
    )
    VALUES (
      pg_catalog.gen_random_uuid(),
      CASE WHEN v_is_request THEN v_request.participant_id
        ELSE v_validation.participant_id END,
      CASE WHEN v_is_request THEN v_request.idea_id ELSE v_validation.idea_id END,
      v_version.id,
      v_milestone.milestone_key,
      v_milestone.stage_number,
      'award',
      v_points,
      'milestone_validation',
      v_source_reference,
      v_reason,
      v_actor_id,
      v_competition.id,
      v_milestone.catalog_version,
      CASE WHEN v_is_request THEN v_request.request_id ELSE NULL END,
      v_evaluation_level
    )
    RETURNING * INTO v_existing;
  EXCEPTION WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint_name = CONSTRAINT_NAME;
    IF v_constraint_name NOT IN (
      'official_points_ledger_one_award_per_milestone',
      'official_points_ledger_one_award_per_validation_request'
    ) THEN
      RAISE;
    END IF;
    SELECT ledger.* INTO v_existing
      FROM public.official_points_ledger AS ledger
      WHERE ledger.entry_kind = 'award'
        AND ledger.idea_id = CASE WHEN v_is_request
          THEN v_request.idea_id ELSE v_validation.idea_id END
        AND ledger.configuration_version_id = v_version.id
        AND ledger.milestone_key = v_milestone.milestone_key;
    IF NOT FOUND THEN
      RAISE;
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_awarded',
      'entry_id', v_existing.entry_id,
      'points', v_existing.points,
      'validation_request_id', v_existing.validation_request_id,
      'catalog_version', v_existing.catalog_version,
      'competition_id', v_existing.competition_id,
      'evaluation_level', v_existing.evaluation_level,
      'recorded_at', v_existing.recorded_at
    );
  END;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'awarded',
    'entry_id', v_existing.entry_id,
    'points', v_existing.points,
    'validation_id', v_validation_id,
    'validation_request_id', v_existing.validation_request_id,
    'idea_id', v_existing.idea_id,
    'milestone_key', v_existing.milestone_key,
    'catalog_version', v_existing.catalog_version,
    'competition_id', v_existing.competition_id,
    'configuration_version_id', v_existing.configuration_version_id,
    'evaluation_level', v_existing.evaluation_level,
    'recorded_at', v_existing.recorded_at
  );
END
$function$;
GRANT CREATE ON SCHEMA public TO javaneh_identity_executor;
ALTER FUNCTION public.award_validated_milestone(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.award_validated_milestone(uuid)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.award_validated_milestone(uuid)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.correct_score_award(
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
      FROM public.scoring_role_assignments AS role_assignment
      WHERE role_assignment.user_id = v_actor_id
        AND role_assignment.role_name = 'scoring_administrator'
  ) THEN
    RAISE EXCEPTION 'Scoring Administrator authorization required'
      USING ERRCODE = '42501';
  END IF;

  SELECT ledger.* INTO v_original
    FROM public.official_points_ledger AS ledger
    WHERE ledger.entry_id = p_original_entry_id
      AND ledger.entry_kind = 'award';
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

  SELECT ledger.entry_id INTO v_entry_id
    FROM public.official_points_ledger AS ledger
    WHERE ledger.entry_kind = 'compensation'
      AND ledger.original_entry_id = p_original_entry_id;
  IF FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'outcome', 'already_corrected',
      'entry_id', v_entry_id
    );
  END IF;

  INSERT INTO public.official_points_ledger (
    idempotency_key, user_id, idea_id, configuration_version_id,
    milestone_key, stage_number, entry_kind, points, original_entry_id,
    source, source_reference, reason, recorded_by, competition_id,
    catalog_version, validation_request_id, evaluation_level
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
    v_actor_id,
    v_original.competition_id,
    v_original.catalog_version,
    v_original.validation_request_id,
    v_original.evaluation_level
  )
  RETURNING entry_id INTO v_entry_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'corrected',
    'entry_id', v_entry_id,
    'points', -v_original.points
  );
END
$function$;
GRANT CREATE ON SCHEMA public TO javaneh_identity_executor;
ALTER FUNCTION public.correct_score_award(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.correct_score_award(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.correct_score_award(uuid, text)
  TO authenticated;

COMMENT ON COLUMN public.official_points_ledger.competition_id IS
  'Validated competition identity for M9R3+ awards; the legacy opaque scoring_configurations.competition_id remains unchanged.';
COMMENT ON COLUMN public.official_points_ledger.catalog_version IS
  'Exact milestone catalog version used for this award; null for historical pre-catalog entries.';
COMMENT ON COLUMN public.official_points_ledger.validation_request_id IS
  'M9R4 request proving the eligible idea revision; null for historical M9R1/M9R2 entries.';
COMMENT ON COLUMN public.official_points_ledger.evaluation_level IS
  'Validator-selected level used by the single authoritative floor-rounded score formula; null for objective awards.';
COMMENT ON FUNCTION public.award_validated_milestone(uuid) IS
  'Issues one authoritative award from either a legacy approved validation ID or an eligible M9R4 request ID; all points and references are derived server-side.';

COMMIT;
