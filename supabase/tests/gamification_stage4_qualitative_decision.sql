-- Run against an isolated local Supabase database as supabase_admin.
-- All temporary catalog mutations are rolled back.
BEGIN;

DO $m9r7_decision_test$
DECLARE
  v_version_id uuid;
  v_status text;
  v_competition_status text;
  v_total integer;
BEGIN
  SELECT version.id, version.status, competition.status
    INTO v_version_id, v_status, v_competition_status
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    JOIN public.competitions AS competition
      ON competition.scoring_configuration_version_id = version.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1;
  IF v_version_id IS NULL THEN
    RAISE EXCEPTION 'Version 1.0 and its competition must exist';
  END IF;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_milestone_catalog AS milestone
        WHERE milestone.configuration_version_id = v_version_id
          AND milestone.catalog_version = '1.0') <> 28
     OR (SELECT pg_catalog.count(DISTINCT milestone.milestone_key)
           FROM public.scoring_milestone_catalog AS milestone
           WHERE milestone.configuration_version_id = v_version_id
             AND milestone.catalog_version = '1.0') <> 28 THEN
    RAISE EXCEPTION 'Expected 28 unique Version 1.0 development milestones';
  END IF;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_milestone_catalog AS milestone
        WHERE milestone.configuration_version_id = v_version_id
          AND milestone.catalog_version = '1.0'
          AND milestone.stage_number = 4
          AND milestone.validation_mode = 'qualitative') <> 5
     OR EXISTS (
       SELECT 1
         FROM public.scoring_milestone_catalog AS milestone
         WHERE milestone.configuration_version_id = v_version_id
           AND milestone.catalog_version = '1.0'
           AND milestone.stage_number = 4
           AND (
             milestone.validation_mode <> 'qualitative'
             OR milestone.validation_policy IS DISTINCT FROM
               '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
             OR pg_catalog.jsonb_typeof(
               milestone.validation_policy->'objective_checks'
             ) IS NOT NULL
           )
     ) THEN
    RAISE EXCEPTION 'All five Stage 4 milestones must use qualitative-only validation';
  END IF;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_milestone_catalog AS milestone
        WHERE milestone.configuration_version_id = v_version_id
          AND milestone.catalog_version = '1.0'
          AND milestone.validation_mode = 'qualitative') <> 26
     OR (SELECT pg_catalog.count(*)
           FROM public.scoring_milestone_catalog AS milestone
           WHERE milestone.configuration_version_id = v_version_id
             AND milestone.catalog_version = '1.0'
             AND milestone.validation_mode = 'hybrid') <> 2
     OR EXISTS (
       SELECT 1
         FROM public.scoring_milestone_catalog AS milestone
         WHERE milestone.configuration_version_id = v_version_id
           AND milestone.catalog_version = '1.0'
           AND milestone.validation_mode NOT IN ('qualitative', 'hybrid')
     )
     OR EXISTS (
       SELECT 1
         FROM public.scoring_milestone_catalog AS milestone
         WHERE milestone.configuration_version_id = v_version_id
           AND milestone.catalog_version = '1.0'
           AND milestone.validation_mode = 'hybrid'
           AND milestone.milestone_key NOT IN ('S6-M1', 'S6-M5')
     )
     OR EXISTS (
       SELECT 1
         FROM (VALUES ('S6-M1'), ('S6-M5')) AS expected(milestone_key)
         LEFT JOIN public.scoring_milestone_catalog AS milestone
           ON milestone.configuration_version_id = v_version_id
          AND milestone.catalog_version = '1.0'
          AND milestone.milestone_key = expected.milestone_key
          AND milestone.validation_mode = 'hybrid'
          AND milestone.validation_policy->>'type' =
            'human_qualitative_level'
          AND pg_catalog.jsonb_typeof(
            milestone.validation_policy->'objective_checks'
          ) = 'array'
          AND pg_catalog.jsonb_array_length(
            milestone.validation_policy->'objective_checks'
          ) > 0
         WHERE milestone.milestone_key IS NULL
     ) THEN
    RAISE EXCEPTION 'Validation modes or retained Hybrid human-review policy differ from approval';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.scoring_milestone_catalog AS milestone
      WHERE milestone.configuration_version_id = v_version_id
        AND milestone.catalog_version = '1.0'
        AND (
          milestone.evaluator_description IS NULL
          OR pg_catalog.length(pg_catalog.btrim(
            milestone.evaluator_description
          )) = 0
          OR milestone.level_4_indicators IS NULL
          OR milestone.evidence_guidance IS NULL
          OR milestone.evaluator_instructions IS NULL
          OR milestone.point_value IS NULL
          OR milestone.level_0_description IS NOT NULL
          OR milestone.level_1_description IS NOT NULL
          OR milestone.level_2_description IS NOT NULL
          OR milestone.level_3_description IS NOT NULL
        )
  ) THEN
    RAISE EXCEPTION 'M9R6 guidance is incomplete or criterion-specific levels were invented';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM (VALUES
        (1, 80), (2, 100), (3, 140), (4, 140),
        (5, 120), (6, 120), (7, 300)
      ) AS expected(stage_number, maximum_points)
      LEFT JOIN public.scoring_stage_catalog AS stage
        ON stage.configuration_version_id = v_version_id
       AND stage.stage_number = expected.stage_number
       AND stage.maximum_points = expected.maximum_points
      WHERE stage.stage_number IS NULL
  ) THEN
    RAISE EXCEPTION 'Approved stage maxima changed';
  END IF;
  SELECT pg_catalog.sum(stage.maximum_points) INTO v_total
    FROM public.scoring_stage_catalog AS stage
    WHERE stage.configuration_version_id = v_version_id
      AND stage.stage_number BETWEEN 1 AND 6;
  IF v_total <> 700 THEN
    RAISE EXCEPTION 'Development maximum changed: %', v_total;
  END IF;

  IF NOT public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE EXCEPTION 'Complete Version 1.0 configuration is not ready after M9R7';
  END IF;
  IF v_status <> 'draft' OR v_competition_status <> 'draft' THEN
    RAISE EXCEPTION 'Product rubric decision changed operational lifecycle state';
  END IF;
END
$m9r7_decision_test$;

DO $m9r7_readiness_negative_test$
DECLARE
  v_version_id uuid;
  v_previous_mode text;
  v_previous_policy jsonb;
  v_rejected boolean := false;
BEGIN
  SELECT version.id INTO v_version_id
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1;

  SELECT milestone.validation_mode, milestone.validation_policy
    INTO v_previous_mode, v_previous_policy
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.catalog_version = '1.0'
      AND milestone.milestone_key = 'S4-M1';
  UPDATE public.scoring_milestone_catalog AS milestone
    SET validation_mode = 'pending',
        validation_policy =
          '{"type":"unresolved_validation_mode","allowed_modes":["qualitative","hybrid"]}'::jsonb
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.catalog_version = '1.0'
      AND milestone.milestone_key = 'S4-M1';
  IF public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE EXCEPTION 'Readiness accepted a pending milestone';
  END IF;

  UPDATE public.scoring_milestone_catalog AS milestone
    SET validation_mode = v_previous_mode,
        validation_policy = v_previous_policy
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.catalog_version = '1.0'
      AND milestone.milestone_key = 'S4-M1';
  UPDATE public.scoring_milestone_catalog AS milestone
    SET level_4_indicators = NULL
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.catalog_version = '1.0'
      AND milestone.milestone_key = 'S4-M1';
  IF public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE EXCEPTION 'Readiness accepted missing evaluator guidance';
  END IF;

  BEGIN
    UPDATE public.scoring_milestone_catalog AS milestone
      SET validation_mode = 'unsupported'
      WHERE milestone.configuration_version_id = v_version_id
        AND milestone.catalog_version = '1.0'
        AND milestone.milestone_key = 'S4-M1';
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Catalog accepted an unsupported validation mode';
  END IF;
END
$m9r7_readiness_negative_test$;

ROLLBACK;
