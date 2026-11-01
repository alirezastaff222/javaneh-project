-- Run against an isolated local database as supabase_admin.
-- All participant fixtures and scorecard checks are rolled back.
BEGIN;

DO $scorecard_security_test$
DECLARE
  v_index_predicate text;
  v_function record;
BEGIN
  SELECT pg_catalog.pg_get_expr(index.indpred, index.indrelid)
    INTO v_index_predicate
    FROM pg_catalog.pg_index AS index
    WHERE index.indrelid = 'public.competitions'::regclass
      AND index.indexrelid =
        'public.competitions_one_active_global_idx'::regclass
      AND index.indisunique;
  IF v_index_predicate IS NULL
     OR v_index_predicate NOT LIKE '%active%' THEN
    RAISE EXCEPTION 'A global single-active-competition index is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_attribute AS attribute
      WHERE attribute.attrelid = 'public.ideas'::regclass
        AND attribute.attname = 'competition_id'
        AND NOT attribute.attisdropped
  ) OR NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_trigger AS trigger
      WHERE trigger.tgrelid = 'public.ideas'::regclass
        AND trigger.tgname = 'ideas_competition_assignment_guard'
        AND NOT trigger.tgisinternal
  ) THEN
    RAISE EXCEPTION 'Explicit immutable idea participation is not installed';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.ideas', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.milestone_validation_requests', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.milestone_validation_events', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.user_point_totals', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.user_points_by_stage', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.user_points_by_milestone', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'Raw score, validation, or aggregate reads bypass the scorecard';
  END IF;

  IF pg_catalog.has_function_privilege(
       'anon', 'public.get_participant_idea_scorecard(uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated',
       'public.get_participant_idea_scorecard(uuid)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.assign_idea_competition(uuid,uuid)', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.assign_idea_competition(uuid,uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Scorecard or staff assignment RPC grants are unsafe';
  END IF;

  SELECT procedure.prosecdef, procedure.proconfig,
         procedure.proowner::regrole::text AS owner_name
    INTO v_function
    FROM pg_catalog.pg_proc AS procedure
    WHERE procedure.oid =
      'public.get_participant_idea_scorecard(uuid)'::regprocedure;
  IF NOT v_function.prosecdef
     OR NOT ('search_path=pg_catalog' = ANY(v_function.proconfig))
     OR v_function.owner_name <> 'javaneh_identity_executor' THEN
    RAISE EXCEPTION 'Scorecard RPC owner, fixed search path, or security definer is unsafe';
  END IF;
END
$scorecard_security_test$;

INSERT INTO public.scoring_configurations (id, configuration_key)
VALUES
  ('a9300000-0000-4000-8000-000000000001', 'scorecard-active-test-one'),
  ('a9300000-0000-4000-8000-000000000002', 'scorecard-active-test-two');
INSERT INTO public.scoring_configuration_versions (
  id, configuration_id, version_number, development_max_points,
  human_jury_max_points, overall_max_points, rounding_policy
)
VALUES
  (
    'a9400000-0000-4000-8000-000000000001',
    'a9300000-0000-4000-8000-000000000001', 1, 700, 300, 1000, 'floor'
  ),
  (
    'a9400000-0000-4000-8000-000000000002',
    'a9300000-0000-4000-8000-000000000002', 1, NULL, NULL, NULL, NULL
  );

INSERT INTO public.scoring_stage_catalog (
  configuration_version_id, stage_number, display_name, stage_kind,
  maximum_points, sort_order
)
VALUES
  ('a9400000-0000-4000-8000-000000000001', 1, 'Stage 1', 'development', 80, 1),
  ('a9400000-0000-4000-8000-000000000001', 2, 'Stage 2', 'development', 100, 2),
  ('a9400000-0000-4000-8000-000000000001', 3, 'Stage 3', 'development', 140, 3),
  ('a9400000-0000-4000-8000-000000000001', 4, 'Stage 4', 'development', 140, 4),
  ('a9400000-0000-4000-8000-000000000001', 5, 'Stage 5', 'development', 120, 5),
  ('a9400000-0000-4000-8000-000000000001', 6, 'Stage 6', 'development', 120, 6),
  ('a9400000-0000-4000-8000-000000000001', 7, 'Human Jury', 'human_jury', 300, 7);

INSERT INTO public.scoring_milestone_catalog (
  configuration_version_id, milestone_key, stage_number, definition,
  point_value, is_active, catalog_version, display_name,
  participant_description, evaluator_description, validation_mode,
  validation_policy, catalog_status, sort_order, descriptor_status
)
SELECT
  'a9400000-0000-4000-8000-000000000001',
  milestone.milestone_key,
  milestone.stage_number,
  milestone.milestone_key,
  milestone.point_value,
  true,
  '1.0',
  milestone.milestone_key,
  'Participant-facing test criterion.',
  'Private test-only evaluator description.',
  'qualitative',
  '{"type":"qualitative"}'::jsonb,
  'active',
  milestone.sort_order,
  'approved'
FROM (VALUES
  ('S1-M1', 1, 25, 1), ('S1-M2', 1, 20, 2),
  ('S1-M3', 1, 20, 3), ('S1-M4', 1, 15, 4),
  ('S2-M1', 2, 25, 1), ('S2-M2', 2, 25, 2),
  ('S2-M3', 2, 25, 3), ('S2-M4', 2, 25, 4),
  ('S3-M1', 3, 30, 1), ('S3-M2', 3, 35, 2),
  ('S3-M3', 3, 35, 3), ('S3-M4', 3, 20, 4), ('S3-M5', 3, 20, 5),
  ('S4-M1', 4, 25, 1), ('S4-M2', 4, 35, 2),
  ('S4-M3', 4, 25, 3), ('S4-M4', 4, 30, 4), ('S4-M5', 4, 25, 5),
  ('S5-M1', 5, 25, 1), ('S5-M2', 5, 25, 2),
  ('S5-M3', 5, 25, 3), ('S5-M4', 5, 25, 4), ('S5-M5', 5, 20, 5),
  ('S6-M1', 6, 30, 1), ('S6-M2', 6, 30, 2),
  ('S6-M3', 6, 20, 3), ('S6-M4', 6, 20, 4), ('S6-M5', 6, 20, 5)
) AS milestone(milestone_key, stage_number, point_value, sort_order);

-- This rollback-only fixture bypasses lifecycle triggers to model the already-authorized
-- active state; it is never applied to a persistent competition.
SET LOCAL session_replication_role = replica;
UPDATE public.scoring_configuration_versions
SET status = 'active',
    approved_by = 'a9000000-0000-4000-8000-000000000001',
    approved_at = pg_catalog.now(),
    activated_at = pg_catalog.now()
WHERE id = 'a9400000-0000-4000-8000-000000000001';
SET LOCAL session_replication_role = origin;

INSERT INTO public.competitions (
  id, competition_key, name, description, status,
  scoring_configuration_version_id
)
VALUES (
  'a9500000-0000-4000-8000-000000000001', 'scorecard-active-test-one',
  'Scorecard active test one', 'Rollback-only active competition test.',
  'active', 'a9400000-0000-4000-8000-000000000001'
);

DO $single_active_competition_test$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    INSERT INTO public.competitions (
      id, competition_key, name, description, status,
      scoring_configuration_version_id
    )
    VALUES (
      'a9500000-0000-4000-8000-000000000002', 'scorecard-active-test-two',
      'Scorecard active test two', 'Rollback-only active competition test.',
      'active', 'a9400000-0000-4000-8000-000000000002'
    );
  EXCEPTION WHEN unique_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A second active competition was accepted';
  END IF;
END
$single_active_competition_test$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a9000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated',
    'scorecard-owner@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated',
    'scorecard-other@test.invalid', '', '{}'::jsonb, '{}'::jsonb,
    pg_catalog.now(), pg_catalog.now(), false, false
  );

INSERT INTO public.ideas (id, owner_id, creation_request_id)
VALUES (
  'a9100000-0000-4000-8000-000000000001',
  'a9000000-0000-4000-8000-000000000001',
  'a9200000-0000-4000-8000-000000000001'
);

DO $scorecard_ownership_test$
DECLARE
  v_result jsonb;
  v_assignment_rejected boolean := false;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    'a9000000-0000-4000-8000-000000000001',
    true
  );
  v_result := public.get_participant_idea_scorecard(
    'a9100000-0000-4000-8000-000000000001'
  );
  IF v_result->>'state' <> 'unavailable'
     OR v_result->>'reason' <> 'not_assigned' THEN
    RAISE EXCEPTION 'An unassigned idea must have an explicit unavailable state: %',
      v_result;
  END IF;

  BEGIN
    PERFORM public.assign_idea_competition(
      'a9100000-0000-4000-8000-000000000001',
      'a9500000-0000-4000-8000-000000000001'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_assignment_rejected := true;
  END;
  IF NOT v_assignment_rejected THEN
    RAISE EXCEPTION 'A participant without a scoring role assigned a competition';
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    'a9000000-0000-4000-8000-000000000002',
    true
  );
  v_result := public.get_participant_idea_scorecard(
    'a9100000-0000-4000-8000-000000000001'
  );
  IF v_result->>'state' <> 'unavailable'
     OR v_result->>'reason' <> 'not_found' THEN
    RAISE EXCEPTION 'A different participant must not discover idea score state: %',
      v_result;
  END IF;
END
$scorecard_ownership_test$;

SET LOCAL session_replication_role = replica;
UPDATE public.ideas
SET competition_id = 'a9500000-0000-4000-8000-000000000001'
WHERE id = 'a9100000-0000-4000-8000-000000000001';

INSERT INTO public.milestone_validation_requests (
  request_id, idea_id, participant_id, configuration_version_id,
  milestone_key, catalog_version, stage_number, idea_revision,
  validation_mode, status, submitted_by
)
VALUES
  (
    'a9600000-0000-4000-8000-000000000001',
    'a9100000-0000-4000-8000-000000000001',
    'a9000000-0000-4000-8000-000000000001',
    'a9400000-0000-4000-8000-000000000001',
    'S1-M1', '1.0', 1, 1, 'qualitative', 'validated',
    'a9000000-0000-4000-8000-000000000001'
  ),
  (
    'a9600000-0000-4000-8000-000000000002',
    'a9100000-0000-4000-8000-000000000001',
    'a9000000-0000-4000-8000-000000000001',
    'a9400000-0000-4000-8000-000000000001',
    'S1-M2', '1.0', 1, 1, 'qualitative', 'pending_validation',
    'a9000000-0000-4000-8000-000000000001'
  );

INSERT INTO public.official_points_ledger (
  entry_id, idempotency_key, user_id, idea_id, configuration_version_id,
  milestone_key, stage_number, entry_kind, points, original_entry_id,
  source, source_reference, reason, recorded_by, competition_id,
  catalog_version, validation_request_id, evaluation_level
)
VALUES
  (
    'a9700000-0000-4000-8000-000000000001',
    'a9800000-0000-4000-8000-000000000001',
    'a9000000-0000-4000-8000-000000000001',
    'a9100000-0000-4000-8000-000000000001',
    'a9400000-0000-4000-8000-000000000001',
    'S1-M1', 1, 'award', 18, NULL, 'milestone_validation',
    'a9600000-0000-4000-8000-000000000001',
    'private award rationale',
    'a9000000-0000-4000-8000-000000000002',
    'a9500000-0000-4000-8000-000000000001',
    '1.0', 'a9600000-0000-4000-8000-000000000001', 3
  ),
  (
    'a9700000-0000-4000-8000-000000000002',
    'a9800000-0000-4000-8000-000000000002',
    'a9000000-0000-4000-8000-000000000001',
    'a9100000-0000-4000-8000-000000000001',
    'a9400000-0000-4000-8000-000000000001',
    'S1-M1', 1, 'compensation', -6,
    'a9700000-0000-4000-8000-000000000001',
    'administrative_correction',
    'a9600000-0000-4000-8000-000000000001',
    'private correction rationale',
    'a9000000-0000-4000-8000-000000000002',
    'a9500000-0000-4000-8000-000000000001',
    '1.0', NULL, NULL
  );
SET LOCAL session_replication_role = origin;

DO $scorecard_payload_test$
DECLARE
  v_result jsonb;
  v_milestone_count integer;
  v_stage_count integer;
BEGIN
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub',
    'a9000000-0000-4000-8000-000000000001',
    true
  );
  v_result := public.get_participant_idea_scorecard(
    'a9100000-0000-4000-8000-000000000001'
  );
  IF v_result->>'state' <> 'available'
     OR v_result->>'total_points' <> '12'
     OR v_result->>'maximum_points' <> '700' THEN
    RAISE EXCEPTION 'Available scorecard totals must reflect net ledger points: %',
      v_result;
  END IF;

  SELECT pg_catalog.count(*) INTO v_milestone_count
    FROM pg_catalog.jsonb_array_elements(v_result->'milestones') AS item(value)
    JOIN public.scoring_milestone_catalog AS milestone
      ON milestone.configuration_version_id =
           'a9400000-0000-4000-8000-000000000001'
     AND milestone.display_name = item.value->>'name'
     AND milestone.point_value::text = item.value->>'maximum_points';
  IF pg_catalog.jsonb_array_length(v_result->'milestones') <> 28
     OR v_milestone_count <> 28
     OR EXISTS (
       SELECT 1
         FROM pg_catalog.jsonb_array_elements(v_result->'milestones') AS item(value)
         WHERE (item.value->>'stage_number')::integer NOT BETWEEN 1 AND 6
     ) THEN
    RAISE EXCEPTION 'All 28 milestone maxima must match the configured catalog';
  END IF;

  SELECT pg_catalog.count(*) INTO v_stage_count
    FROM pg_catalog.jsonb_array_elements(v_result->'stages') AS item(value)
    JOIN public.scoring_stage_catalog AS stage
      ON stage.configuration_version_id =
           'a9400000-0000-4000-8000-000000000001'
     AND stage.stage_number = (item.value->>'stage_number')::integer
     AND stage.maximum_points::text = item.value->>'maximum_points'
    WHERE (item.value->>'points')::integer <= stage.maximum_points;
  IF pg_catalog.jsonb_array_length(v_result->'stages') <> 6
     OR v_stage_count <> 6
     OR (v_result->'stages'->0->>'points')::integer <> 12
     OR (v_result->'stages'->0->>'maximum_points')::integer <> 80
     OR 80 - (v_result->'stages'->0->>'points')::integer <> 68 THEN
    RAISE EXCEPTION 'Development stage earned, maximum, or remaining values are invalid';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'milestones') AS item(value)
      WHERE item.value->>'name' = 'S1-M1'
        AND item.value->>'status' = 'awarded'
        AND item.value->>'awarded_points' = '12'
        AND item.value->>'maximum_points' = '25'
  ) OR NOT EXISTS (
    SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'milestones') AS item(value)
      WHERE item.value->>'name' = 'S1-M2'
        AND item.value->>'status' = 'pending_validation'
        AND item.value->>'awarded_points' = '0'
        AND item.value->>'maximum_points' = '20'
  ) THEN
    RAISE EXCEPTION 'Pending validation must remain separate from net awarded points';
  END IF;

  IF (SELECT pg_catalog.sum((item.value->>'points')::integer)
        FROM pg_catalog.jsonb_array_elements(v_result->'history') AS item(value))
       <> 12
     OR pg_catalog.jsonb_array_length(v_result->'history') <> 2 THEN
    RAISE EXCEPTION 'Compensation entries must reduce net ledger points';
  END IF;

  IF v_result::text LIKE '%private award rationale%'
     OR v_result::text LIKE '%private correction rationale%'
     OR v_result::text ~ '"(reason|recorded_by|source_reference|evaluator_id|jury_points|final_competition_score|overall_score|competition_id)"'
     OR v_result::text LIKE '%"stage_number": 7%' THEN
    RAISE EXCEPTION 'Participant scorecard exposed restricted scoring fields';
  END IF;
END
$scorecard_payload_test$;

ROLLBACK;