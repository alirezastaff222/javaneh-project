BEGIN;

DO $m9r7_prerequisite_check$
DECLARE
  v_version_id uuid;
  v_status text;
  v_approved_by uuid;
  v_approved_at timestamptz;
  v_competition_status text;
  v_stage_four_count integer;
BEGIN
  SELECT version.id, version.status, version.approved_by, version.approved_at,
         competition.status
    INTO v_version_id, v_status, v_approved_by, v_approved_at,
         v_competition_status
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    JOIN public.competitions AS competition
      ON competition.scoring_configuration_version_id = version.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1
    FOR UPDATE OF version, competition;

  IF NOT FOUND OR v_status <> 'draft'
     OR v_approved_by IS NOT NULL OR v_approved_at IS NOT NULL
     OR v_competition_status <> 'draft' THEN
    RAISE EXCEPTION
      'Stage 4 product decision requires the existing draft Version 1.0 configuration and draft competition';
  END IF;

  SELECT pg_catalog.count(*) INTO v_stage_four_count
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.catalog_version = '1.0'
      AND milestone.stage_number = 4;
  IF v_stage_four_count <> 5 OR EXISTS (
    SELECT 1
      FROM public.scoring_milestone_catalog AS milestone
      WHERE milestone.configuration_version_id = v_version_id
        AND milestone.catalog_version = '1.0'
        AND milestone.stage_number = 4
        AND (
          milestone.validation_mode <> 'pending'
          OR milestone.validation_policy IS DISTINCT FROM
            '{"type":"unresolved_validation_mode","allowed_modes":["qualitative","hybrid"]}'::jsonb
          OR milestone.point_value IS NULL
          OR milestone.level_4_indicators IS NULL
          OR milestone.evidence_guidance IS NULL
          OR milestone.evaluator_instructions IS NULL
        )
  ) THEN
    RAISE EXCEPTION
      'Expected exactly five complete Version 1.0 Stage 4 milestones pending the product decision';
  END IF;
END
$m9r7_prerequisite_check$;

UPDATE public.scoring_milestone_catalog AS milestone
  SET validation_mode = 'qualitative',
      validation_policy =
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
  WHERE milestone.configuration_version_id = (
      SELECT version.id
        FROM public.scoring_configurations AS configuration
        JOIN public.scoring_configuration_versions AS version
          ON version.configuration_id = configuration.id
        WHERE configuration.configuration_key =
          'javaneh-approved-scoring-policy-v1'
          AND version.version_number = 1
    )
    AND milestone.catalog_version = '1.0'
    AND milestone.stage_number = 4
    AND milestone.validation_mode = 'pending'
    AND milestone.validation_policy =
      '{"type":"unresolved_validation_mode","allowed_modes":["qualitative","hybrid"]}'::jsonb;

DO $m9r7_result_check$
DECLARE
  v_version_id uuid;
BEGIN
  SELECT version.id INTO v_version_id
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_milestone_catalog AS milestone
        WHERE milestone.configuration_version_id = v_version_id
          AND milestone.catalog_version = '1.0'
          AND milestone.stage_number = 4
          AND milestone.validation_mode = 'qualitative'
          AND milestone.validation_policy =
            '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb) <> 5
     OR (SELECT pg_catalog.count(*)
           FROM public.scoring_milestone_catalog AS milestone
           WHERE milestone.configuration_version_id = v_version_id
             AND milestone.catalog_version = '1.0') <> 28
     OR (SELECT pg_catalog.count(*)
           FROM public.scoring_milestone_catalog AS milestone
           WHERE milestone.configuration_version_id = v_version_id
             AND milestone.catalog_version = '1.0'
             AND milestone.validation_mode = 'qualitative') <> 26
     OR (SELECT pg_catalog.count(*)
           FROM public.scoring_milestone_catalog AS milestone
           WHERE milestone.configuration_version_id = v_version_id
             AND milestone.catalog_version = '1.0'
             AND milestone.validation_mode = 'hybrid') <> 2
     OR (SELECT pg_catalog.count(*)
           FROM public.scoring_milestone_catalog AS milestone
           WHERE milestone.configuration_version_id = v_version_id
             AND milestone.catalog_version = '1.0'
             AND milestone.validation_mode = 'pending') <> 0
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
         FROM public.scoring_milestone_catalog AS milestone
         WHERE milestone.configuration_version_id = v_version_id
           AND milestone.catalog_version = '1.0'
           AND milestone.validation_mode NOT IN ('qualitative', 'hybrid')
     )
     OR NOT public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE EXCEPTION
      'Final validation modes or scoring readiness did not match the approved M9R7 decision';
  END IF;

  IF (SELECT version.status
        FROM public.scoring_configuration_versions AS version
        WHERE version.id = v_version_id) <> 'draft'
     OR (SELECT competition.status
           FROM public.competitions AS competition
           WHERE competition.scoring_configuration_version_id = v_version_id)
       <> 'draft' THEN
    RAISE EXCEPTION 'M9R7 must not approve or activate scoring or competition';
  END IF;
END
$m9r7_result_check$;

COMMIT;
