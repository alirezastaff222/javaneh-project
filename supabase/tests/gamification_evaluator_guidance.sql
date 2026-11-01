-- Run against an isolated local Supabase database as supabase_admin.
-- All M9R6 fixtures and temporary policy transitions are rolled back.
BEGIN;

DO $m9r6_security_test$
BEGIN
  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_milestone_catalog', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_milestone_catalog', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_milestone_catalog', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_evaluation_levels', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.scoring_evaluation_levels', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.scoring_milestone_catalog', 'INSERT'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated',
       'public.get_milestone_evaluation_guide(uuid,text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon',
       'public.get_milestone_evaluation_guide(uuid,text)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'service_role',
       'public.get_milestone_evaluation_guide(uuid,text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Guidance grants expose a direct catalog write or unsafe reader';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_class AS relation
      JOIN pg_catalog.pg_namespace AS namespace
        ON namespace.oid = relation.relnamespace
      WHERE namespace.nspname = 'public'
        AND relation.relname = 'scoring_milestone_catalog'
        AND relation.relrowsecurity
        AND relation.relforcerowsecurity
  ) OR (
    SELECT pg_catalog.count(*)
      FROM pg_catalog.pg_proc AS function
      JOIN pg_catalog.pg_roles AS owner
        ON owner.oid = function.proowner
      WHERE function.oid IN (
        'public.scoring_configuration_is_ready(uuid)'::regprocedure,
        'public.milestone_validation_is_operational(uuid,text)'::regprocedure,
        'public.evaluate_milestone_objective_policy(uuid,uuid,text)'::regprocedure,
        'public.get_milestone_evaluation_guide(uuid,text)'::regprocedure
      )
        AND owner.rolname = 'javaneh_identity_executor'
        AND function.proconfig @> ARRAY['search_path=pg_catalog']
  ) <> 4 THEN
    RAISE EXCEPTION 'Catalog RLS or readiness function is missing';
  END IF;
END
$m9r6_security_test$;

DO $m9r6_catalog_test$
DECLARE
  v_version_id uuid;
  v_count integer;
  v_development_total integer;
  v_bad_count integer;
BEGIN
  SELECT version.id INTO v_version_id
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1;
  IF v_version_id IS NULL THEN
    RAISE EXCEPTION 'Approved policy Version 1.0 is missing';
  END IF;

  SELECT pg_catalog.count(*), COALESCE(pg_catalog.sum(point_value), 0)::integer
    INTO v_count, v_development_total
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = v_version_id;
  IF v_count <> 28 OR v_development_total <> 700 THEN
    RAISE EXCEPTION 'Expected 28 development criteria totaling 700, got % / %',
      v_count, v_development_total;
  END IF;

  SELECT pg_catalog.count(*) INTO v_bad_count
    FROM (
      VALUES
        ('S1-M1', 1, 25, 'Clarity and precision of the problem description'),
        ('S1-M2', 1, 20, 'Identification of populations affected by the problem'),
        ('S1-M3', 1, 20, 'Presentation of relevant observations, experiences, or evidence'),
        ('S1-M4', 1, 15, 'Explanation of the social significance of the problem'),
        ('S2-M1', 2, 25, 'Identification of relevant people, groups, and actors'),
        ('S2-M2', 2, 25, 'Identification of local assets and resources'),
        ('S2-M3', 2, 25, 'Identification of relationships, networks, and collaboration capacities'),
        ('S2-M4', 2, 25, 'Explanation of how identified capacities relate to the problem'),
        ('S3-M1', 3, 30, 'Exploration of alternative solutions and approaches'),
        ('S3-M2', 3, 35, 'Alignment of the idea with the identified problem'),
        ('S3-M3', 3, 35, 'Innovation and added value'),
        ('S3-M4', 3, 20, 'Coherence and clarity of the selected idea'),
        ('S3-M5', 3, 20, 'Participant''s active involvement and ownership of the idea'),
        ('S4-M1', 4, 25, 'Definition of objectives and expected outcomes'),
        ('S4-M2', 4, 35, 'Design of activities and implementation steps'),
        ('S4-M3', 4, 25, 'Definition of roles and responsibilities'),
        ('S4-M4', 4, 30, 'Identification of implementation resources and requirements'),
        ('S4-M5', 4, 25, 'Scheduling and sequencing of activities'),
        ('S5-M1', 5, 25, 'Identification of assumptions and limitations'),
        ('S5-M2', 5, 25, 'Assessment of implementation risks and barriers'),
        ('S5-M3', 5, 25, 'Assessment of resource accessibility'),
        ('S5-M4', 5, 25, 'Identification of adaptation and resilience strategies'),
        ('S5-M5', 5, 20, 'Revision and improvement based on feasibility analysis'),
        ('S6-M1', 6, 30, 'Completeness of the dossier'),
        ('S6-M2', 6, 30, 'Coherence across dossier sections'),
        ('S6-M3', 6, 20, 'Traceability of claims and evidence'),
        ('S6-M4', 6, 20, 'Clarity and quality of presentation'),
        ('S6-M5', 6, 20, 'Participant''s final review and confirmation of the dossier')
    ) AS expected(milestone_key, stage_number, point_value, display_name)
    LEFT JOIN public.scoring_milestone_catalog AS milestone
      ON milestone.configuration_version_id = v_version_id
     AND milestone.milestone_key = expected.milestone_key
     AND milestone.catalog_version = '1.0'
     AND milestone.stage_number = expected.stage_number
     AND milestone.point_value = expected.point_value
     AND milestone.display_name = expected.display_name
    WHERE milestone.milestone_key IS NULL;
  IF v_bad_count <> 0 THEN
    RAISE EXCEPTION 'Canonical catalog has % missing or mismatched milestone rows',
      v_bad_count;
  END IF;
  IF EXISTS (
    SELECT 1
      FROM public.scoring_milestone_catalog AS milestone
      WHERE milestone.configuration_version_id = v_version_id
        AND milestone.stage_number = 7
  ) THEN
    RAISE EXCEPTION 'Stage 7 must not appear in the development catalog';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM (VALUES
        (1, 'Problem Definition', 80),
        (2, 'Identification of Social Capacities', 100),
        (3, 'Idea Development and Expansion', 140),
        (4, 'Implementation Plan Design', 140),
        (5, 'Feasibility and Resilience Assessment', 120),
        (6, 'Final Dossier Preparation', 120)
      ) AS expected(stage_number, display_name, maximum_points)
      LEFT JOIN public.scoring_stage_catalog AS stage
        ON stage.configuration_version_id = v_version_id
       AND stage.stage_number = expected.stage_number
      LEFT JOIN (
        SELECT milestone.stage_number,
               pg_catalog.sum(milestone.point_value) AS points
          FROM public.scoring_milestone_catalog AS milestone
          WHERE milestone.configuration_version_id = v_version_id
          GROUP BY milestone.stage_number
      ) AS total ON total.stage_number = expected.stage_number
      WHERE stage.maximum_points IS DISTINCT FROM expected.maximum_points
         OR stage.display_name IS DISTINCT FROM expected.display_name
         OR total.points IS DISTINCT FROM expected.maximum_points
  ) OR (SELECT version.human_jury_max_points
          FROM public.scoring_configuration_versions AS version
          WHERE version.id = v_version_id) <> 300
    OR (SELECT version.overall_max_points
          FROM public.scoring_configuration_versions AS version
          WHERE version.id = v_version_id) <> 1000
    OR NOT EXISTS (
      SELECT 1
        FROM public.scoring_stage_catalog AS stage
        WHERE stage.configuration_version_id = v_version_id
          AND stage.stage_number = 7
          AND stage.stage_kind = 'human_jury'
          AND stage.display_name = 'Human Review and Judging'
          AND stage.maximum_points = 300
    ) THEN
    RAISE EXCEPTION 'Approved stage, jury, or competition maxima differ';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.scoring_milestone_catalog AS milestone
      WHERE milestone.configuration_version_id = v_version_id
        AND milestone.catalog_version = '1.0'
        AND (
          milestone.descriptor_status IS DISTINCT FROM 'approved'
          OR milestone.catalog_status IS DISTINCT FROM 'approved'
          OR milestone.is_active
          OR milestone.evaluator_description IS NULL
          OR pg_catalog.length(pg_catalog.btrim(milestone.evaluator_description)) = 0
          OR milestone.level_4_indicators IS NULL
          OR pg_catalog.length(pg_catalog.btrim(milestone.level_4_indicators)) = 0
          OR milestone.evidence_guidance IS NULL
          OR pg_catalog.length(pg_catalog.btrim(milestone.evidence_guidance)) = 0
          OR milestone.evaluator_instructions IS NULL
          OR pg_catalog.length(pg_catalog.btrim(milestone.evaluator_instructions)) = 0
          OR milestone.level_0_description IS NOT NULL
          OR milestone.level_1_description IS NOT NULL
          OR milestone.level_2_description IS NOT NULL
          OR milestone.level_3_description IS NOT NULL
          OR milestone.level_4_description IS NOT NULL
        )
  ) THEN
    RAISE EXCEPTION 'Guidance is incomplete or invents criterion-specific level descriptors';
  END IF;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_evaluation_levels AS level
        WHERE level.configuration_version_id = v_version_id
          AND level.general_description IS NOT NULL) <> 5
     OR EXISTS (
       SELECT 1
         FROM (VALUES
           (0, 'Not achieved', 0.00::numeric, 'No relevant or assessable content is available.'),
           (1, 'Very limited', 0.25::numeric, 'Initial effort exists, but the response is incomplete, unclear, or insufficiently supported.'),
           (2, 'Developing', 0.50::numeric, 'A meaningful part of the criterion is addressed, but significant gaps remain.'),
           (3, 'Satisfactory', 0.75::numeric, 'The criterion is satisfactorily addressed with appropriate explanation and supporting evidence.'),
           (4, 'Fully achieved and supported', 1.00::numeric, 'The criterion is fully addressed in a coherent, accurate, context-sensitive, and sufficiently supported manner.')
         ) AS expected(evaluation_level, display_label, multiplier, general_description)
         LEFT JOIN public.scoring_evaluation_levels AS level
           ON level.configuration_version_id = v_version_id
          AND level.evaluation_level = expected.evaluation_level
         WHERE level.evaluation_level IS NULL
            OR level.display_label <> expected.display_label
            OR level.multiplier <> expected.multiplier
            OR level.general_description <> expected.general_description
     ) THEN
    RAISE EXCEPTION 'Shared evaluation scale differs from approved policy';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM (VALUES
        ('S1-M1', 'qualitative'), ('S1-M2', 'qualitative'),
        ('S1-M3', 'qualitative'), ('S1-M4', 'qualitative'),
        ('S2-M1', 'qualitative'), ('S2-M2', 'qualitative'),
        ('S2-M3', 'qualitative'), ('S2-M4', 'qualitative'),
        ('S3-M1', 'qualitative'), ('S3-M2', 'qualitative'),
        ('S3-M3', 'qualitative'), ('S3-M4', 'qualitative'),
        ('S3-M5', 'qualitative'),
        ('S4-M1', 'qualitative'), ('S4-M2', 'qualitative'),
        ('S4-M3', 'qualitative'), ('S4-M4', 'qualitative'),
        ('S4-M5', 'qualitative'),
        ('S5-M1', 'qualitative'), ('S5-M2', 'qualitative'),
        ('S5-M3', 'qualitative'), ('S5-M4', 'qualitative'),
        ('S5-M5', 'qualitative'),
        ('S6-M1', 'hybrid'), ('S6-M2', 'qualitative'),
        ('S6-M3', 'qualitative'), ('S6-M4', 'qualitative'),
        ('S6-M5', 'hybrid')
      ) AS expected(milestone_key, validation_mode)
      JOIN public.scoring_milestone_catalog AS milestone
        ON milestone.configuration_version_id = v_version_id
       AND milestone.milestone_key = expected.milestone_key
      WHERE milestone.validation_mode <> expected.validation_mode
  ) THEN
    RAISE EXCEPTION 'Milestone validation-mode mapping differs from policy';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.scoring_milestone_catalog AS milestone
      WHERE milestone.configuration_version_id = v_version_id
        AND milestone.evaluation_cautions IS NOT NULL
        AND milestone.milestone_key NOT IN ('S3-M5', 'S6-M4', 'S6-M5')
  ) OR EXISTS (
    SELECT 1
      FROM public.scoring_milestone_catalog AS milestone
      WHERE milestone.configuration_version_id = v_version_id
        AND milestone.milestone_key IN ('S3-M5', 'S6-M4', 'S6-M5')
        AND milestone.evaluation_cautions IS NULL
  ) THEN
    RAISE EXCEPTION 'Criterion-specific evaluation cautions are missing or invented';
  END IF;

  IF (SELECT version.status
        FROM public.scoring_configuration_versions AS version
        WHERE version.id = v_version_id) <> 'draft'
     OR (SELECT version.approved_by
           FROM public.scoring_configuration_versions AS version
           WHERE version.id = v_version_id) IS NOT NULL
     OR (SELECT version.approved_at
           FROM public.scoring_configuration_versions AS version
           WHERE version.id = v_version_id) IS NOT NULL
     OR (SELECT competition.status
           FROM public.competitions AS competition
           WHERE competition.scoring_configuration_version_id = v_version_id)
       <> 'draft' THEN
    RAISE EXCEPTION 'Content approval must not impersonate configuration approval or activation';
  END IF;
END
$m9r6_catalog_test$;

DO $m9r6_bad_level_test$
DECLARE
  v_version_id uuid;
  v_rejected boolean := false;
BEGIN
  SELECT version.id INTO v_version_id
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1;
  BEGIN
    INSERT INTO public.scoring_evaluation_levels (
      configuration_version_id, evaluation_level, display_label, multiplier
    )
    VALUES (v_version_id, 5, 'Invalid level', 0.50);
  EXCEPTION WHEN check_violation OR unique_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An evaluation level outside 0-4 was accepted';
  END IF;
END
$m9r6_bad_level_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a7000000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', 'm9r6-validator@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a7000000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', 'm9r6-participant@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a7000000-0000-4000-8000-000000000003', 'authenticated',
    'authenticated', 'm9r6-admin@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  );
INSERT INTO public.scoring_role_assignments (user_id, role_name, assigned_by)
VALUES
  ('a7000000-0000-4000-8000-000000000001', 'validator', NULL),
  ('a7000000-0000-4000-8000-000000000003', 'scoring_administrator', NULL);

SELECT pg_catalog.set_config(
  'test.m9r6_version_id',
  (
    SELECT version.id::text
      FROM public.scoring_configurations AS configuration
      JOIN public.scoring_configuration_versions AS version
        ON version.configuration_id = configuration.id
      WHERE configuration.configuration_key =
        'javaneh-approved-scoring-policy-v1'
        AND version.version_number = 1
  ),
  true
);

DO $m9r6_hybrid_objective_test$
DECLARE
  v_version_id uuid :=
    pg_catalog.current_setting('test.m9r6_version_id')::uuid;
  v_idea_id uuid := 'a7100000-0000-4000-8000-000000000001';
  v_result jsonb;
BEGIN
  INSERT INTO public.ideas (
    id, owner_id, creation_request_id
  )
  VALUES (
    v_idea_id, 'a7000000-0000-4000-8000-000000000002',
    'a7200000-0000-4000-8000-000000000001'
  );
  INSERT INTO public.idea_stages (idea_id, stage_number, data, status)
  VALUES (v_idea_id, 6, '{}'::jsonb, 'in_progress');
  v_result := public.evaluate_milestone_objective_policy(
    v_idea_id, v_version_id, 'S6-M1'
  );
  IF v_result->>'configured' <> 'true'
     OR v_result->>'passed' <> 'false' THEN
    RAISE EXCEPTION 'Hybrid structural check accepted an empty dossier: %',
      v_result;
  END IF;
  UPDATE public.idea_stages
    SET data = '{"section":"draft dossier"}'::jsonb
    WHERE idea_id = v_idea_id AND stage_number = 6;
  v_result := public.evaluate_milestone_objective_policy(
    v_idea_id, v_version_id, 'S6-M1'
  );
  IF v_result->>'configured' <> 'true'
     OR v_result->>'passed' <> 'true' THEN
    RAISE EXCEPTION 'Hybrid structural check rejected nonempty stage data: %',
      v_result;
  END IF;
  IF EXISTS (
    SELECT 1
      FROM public.official_points_ledger AS ledger
      WHERE ledger.idea_id = v_idea_id
  ) THEN
    RAISE EXCEPTION 'Passing a structural check independently created points';
  END IF;
END
$m9r6_hybrid_objective_test$;

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a7000000-0000-4000-8000-000000000002', true
);
DO $m9r6_participant_access_test$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    PERFORM 1
      FROM public.get_milestone_evaluation_guide(
        pg_catalog.current_setting('test.m9r6_version_id')::uuid, 'S1-M1'
      );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Participant read evaluator-only guidance';
  END IF;
  v_rejected := false;
  BEGIN
    PERFORM public.approve_scoring_configuration_version(
      pg_catalog.current_setting('test.m9r6_version_id')::uuid,
      'Unauthorized participant approval test.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Participant approved the scoring configuration';
  END IF;
END
$m9r6_participant_access_test$;

SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a7000000-0000-4000-8000-000000000001', true
);
DO $m9r6_validator_guide_test$
DECLARE
  v_guide record;
  v_rejected boolean := false;
BEGIN
  SELECT * INTO v_guide
    FROM public.get_milestone_evaluation_guide(
      pg_catalog.current_setting('test.m9r6_version_id')::uuid, 'S3-M5'
    );
  IF v_guide.milestone_key <> 'S3-M5'
     OR v_guide.catalog_version <> '1.0'
     OR v_guide.evaluator_focus IS NULL
     OR v_guide.level_4_indicators IS NULL
     OR v_guide.evidence_guidance IS NULL
     OR v_guide.evaluation_cautions IS NULL
     OR pg_catalog.jsonb_array_length(v_guide.evaluation_scale) <> 5 THEN
    RAISE EXCEPTION 'Authorized Validator did not receive complete guidance';
  END IF;
  BEGIN
    PERFORM public.approve_scoring_configuration_version(
      pg_catalog.current_setting('test.m9r6_version_id')::uuid,
      'Validator must not approve scoring configuration.'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Validator unexpectedly approved scoring configuration';
  END IF;
END
$m9r6_validator_guide_test$;

RESET ROLE;

DO $m9r6_readiness_test$
DECLARE
  v_version_id uuid :=
    pg_catalog.current_setting('test.m9r6_version_id')::uuid;
  v_indicators text;
BEGIN
  IF NOT public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE EXCEPTION 'Approved Stage 4 decision did not clear mode readiness';
  END IF;
  IF public.milestone_validation_is_operational(v_version_id, 'S4-M1')
     OR public.milestone_validation_is_operational(v_version_id, 'S1-M1') THEN
    RAISE EXCEPTION 'Draft configuration became operational';
  END IF;

  UPDATE public.scoring_milestone_catalog AS milestone
    SET validation_mode = 'pending',
        validation_policy =
          '{"type":"unresolved_validation_mode","allowed_modes":["qualitative","hybrid"]}'::jsonb
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.milestone_key = 'S4-M1';
  IF public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE EXCEPTION 'Pending milestone incorrectly passed configuration readiness';
  END IF;
  UPDATE public.scoring_milestone_catalog AS milestone
    SET validation_mode = 'qualitative',
        validation_policy =
          '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.milestone_key = 'S4-M1';
  IF NOT public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE EXCEPTION 'Qualitative Stage 4 mode failed readiness';
  END IF;

  SELECT milestone.level_4_indicators INTO v_indicators
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.milestone_key = 'S1-M1';
  UPDATE public.scoring_milestone_catalog AS milestone
    SET level_4_indicators = NULL
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.milestone_key = 'S1-M1';
  IF public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE EXCEPTION 'Incomplete evaluator guidance passed configuration readiness';
  END IF;
  UPDATE public.scoring_milestone_catalog AS milestone
    SET level_4_indicators = v_indicators
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.milestone_key = 'S1-M1';
  IF NOT public.scoring_configuration_is_ready(v_version_id) THEN
    RAISE EXCEPTION 'Readiness did not recover after restoring complete guidance';
  END IF;
END
$m9r6_readiness_test$;

DO $m9r6_hybrid_policy_test$
DECLARE
  v_version_id uuid :=
    pg_catalog.current_setting('test.m9r6_version_id')::uuid;
  v_policy jsonb;
BEGIN
  SELECT milestone.validation_policy INTO v_policy
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.milestone_key = 'S6-M1';
  IF v_policy->>'type' <> 'human_qualitative_level'
     OR v_policy->'objective_checks'->0->>'operator'
       <> 'stage_data_present' THEN
    RAISE EXCEPTION 'Hybrid mode does not retain human qualitative judgment';
  END IF;
  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_milestone_catalog AS milestone
        WHERE milestone.configuration_version_id = v_version_id
          AND milestone.validation_mode = 'objective') <> 0 THEN
    RAISE EXCEPTION 'Approved guide unexpectedly configures an objective-only milestone';
  END IF;
END
$m9r6_hybrid_policy_test$;

ROLLBACK;
