-- Run against an isolated local Supabase database as supabase_admin.
-- All configuration, catalog, and ledger fixtures are rolled back.
BEGIN;

DO $security_test$
DECLARE
  v_count integer;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname IN (
        'scoring_configurations',
        'scoring_configuration_versions',
        'scoring_milestone_catalog',
        'official_points_ledger'
      )
      AND c.relkind = 'r'
      AND c.relrowsecurity
      AND c.relforcerowsecurity;
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'All scoring tables must have forced RLS';
  END IF;

  IF pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'DELETE'
     )
     OR pg_catalog.has_table_privilege(
       'service_role', 'public.official_points_ledger', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'javaneh_identity_executor', 'public.official_points_ledger', 'UPDATE'
     )
     OR pg_catalog.has_table_privilege(
       'javaneh_identity_executor', 'public.official_points_ledger', 'DELETE'
     ) THEN
    RAISE EXCEPTION 'A client or executor has unapproved ledger mutation privileges';
  END IF;

  IF NOT pg_catalog.has_table_privilege(
       'authenticated', 'public.official_points_ledger', 'SELECT'
     )
     OR NOT pg_catalog.has_table_privilege(
       'authenticated', 'public.user_point_totals', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'Authenticated users lack read access to their RLS-filtered scores';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.scoring_configuration_versions AS v
      WHERE v.status = 'active'
  ) OR EXISTS (
    SELECT 1
      FROM public.scoring_milestone_catalog AS m
      WHERE m.is_active
  ) THEN
    RAISE EXCEPTION 'A migration must not automatically activate scoring rules';
  END IF;
END
$security_test$;

INSERT INTO public.scoring_configurations (id, competition_id)
VALUES ('91000000-0000-4000-8000-000000000001', NULL);
INSERT INTO public.scoring_configuration_versions (
  id, configuration_id, version_number
)
VALUES (
  '92000000-0000-4000-8000-000000000001',
  '91000000-0000-4000-8000-000000000001',
  1
);
INSERT INTO public.scoring_milestone_catalog (
  configuration_version_id,
  milestone_key,
  stage_number,
  definition,
  point_value,
  is_active
)
VALUES (
  '92000000-0000-4000-8000-000000000001',
  'test.milestone',
  1,
  'Rollback-only test fixture; not a product milestone.',
  17,
  true
);

DO $configuration_transition_test$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    UPDATE public.scoring_configuration_versions
      SET status = 'active',
          approved_by = '93000000-0000-4000-8000-000000000001',
          approved_at = pg_catalog.clock_timestamp(),
          activated_at = pg_catalog.clock_timestamp()
      WHERE id = '92000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A draft scoring version bypassed explicit approval';
  END IF;

  UPDATE public.scoring_configuration_versions
    SET status = 'approved',
        approved_by = '93000000-0000-4000-8000-000000000001',
        approved_at = pg_catalog.clock_timestamp()
    WHERE id = '92000000-0000-4000-8000-000000000001';

  v_rejected := false;
  BEGIN
    UPDATE public.scoring_milestone_catalog
      SET point_value = 18
      WHERE configuration_version_id = '92000000-0000-4000-8000-000000000001'
        AND milestone_key = 'test.milestone';
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An approved milestone rule was mutable';
  END IF;

  UPDATE public.scoring_configuration_versions
    SET status = 'active',
        activated_at = pg_catalog.clock_timestamp()
    WHERE id = '92000000-0000-4000-8000-000000000001';
END
$configuration_transition_test$;

INSERT INTO public.official_points_ledger (
  idempotency_key,
  user_id,
  idea_id,
  configuration_version_id,
  milestone_key,
  stage_number,
  entry_kind,
  points,
  source,
  source_reference,
  reason,
  recorded_by
)
VALUES (
  '94000000-0000-4000-8000-000000000001',
  '95000000-0000-4000-8000-000000000001',
  '96000000-0000-4000-8000-000000000001',
  '92000000-0000-4000-8000-000000000001',
  'test.milestone',
  1,
  'award',
  17,
  'rollback_test',
  '97000000-0000-4000-8000-000000000001',
  'Rollback-only award fixture.',
  '93000000-0000-4000-8000-000000000001'
);

DO $award_integrity_test$
DECLARE
  v_rejected boolean := false;
BEGIN
  BEGIN
    INSERT INTO public.official_points_ledger (
      idempotency_key, user_id, idea_id, configuration_version_id,
      milestone_key, stage_number, entry_kind, points, source, reason, recorded_by
    )
    VALUES (
      '94000000-0000-4000-8000-000000000001',
      '95000000-0000-4000-8000-000000000001',
      '96000000-0000-4000-8000-000000000001',
      '92000000-0000-4000-8000-000000000001',
      'test.milestone', 1, 'award', 17, 'rollback_test',
      'Duplicate request fixture.', '93000000-0000-4000-8000-000000000001'
    );
  EXCEPTION WHEN unique_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Duplicate idempotency key created a second award';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.scoring_milestone_catalog
      SET point_value = 18
      WHERE configuration_version_id = '92000000-0000-4000-8000-000000000001'
        AND milestone_key = 'test.milestone';
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An awarded active milestone rule was mutable';
  END IF;

  v_rejected := false;
  BEGIN
    UPDATE public.official_points_ledger
      SET points = 99
      WHERE idempotency_key = '94000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Historical award was mutable';
  END IF;

  v_rejected := false;
  BEGIN
    DELETE FROM public.official_points_ledger
      WHERE idempotency_key = '94000000-0000-4000-8000-000000000001';
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Historical award was deletable';
  END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.official_points_ledger (
      idempotency_key, user_id, idea_id, configuration_version_id,
      milestone_key, stage_number, entry_kind, points, original_entry_id,
      source, reason, recorded_by
    )
    VALUES (
      '94000000-0000-4000-8000-000000000003',
      '95000000-0000-4000-8000-000000000002',
      '96000000-0000-4000-8000-000000000001',
      '92000000-0000-4000-8000-000000000001',
      'test.milestone', 1, 'compensation', -4,
      (SELECT entry_id FROM public.official_points_ledger
       WHERE idempotency_key = '94000000-0000-4000-8000-000000000001'),
      'rollback_test', 'Mismatched owner fixture.',
      '93000000-0000-4000-8000-000000000001'
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Mismatched compensation was accepted';
  END IF;
END
$award_integrity_test$;

INSERT INTO public.official_points_ledger (
  idempotency_key,
  user_id,
  idea_id,
  configuration_version_id,
  milestone_key,
  stage_number,
  entry_kind,
  points,
  original_entry_id,
  source,
  reason,
  recorded_by
)
SELECT
  '94000000-0000-4000-8000-000000000002',
  l.user_id,
  l.idea_id,
  l.configuration_version_id,
  l.milestone_key,
  l.stage_number,
  'compensation',
  -5,
  l.entry_id,
  'rollback_test',
  'Rollback-only correction fixture.',
  '93000000-0000-4000-8000-000000000001'
FROM public.official_points_ledger AS l
WHERE l.idempotency_key = '94000000-0000-4000-8000-000000000001';

INSERT INTO public.official_points_ledger (
  idempotency_key,
  user_id,
  idea_id,
  configuration_version_id,
  milestone_key,
  stage_number,
  entry_kind,
  points,
  source,
  reason,
  recorded_by
)
VALUES (
  '94000000-0000-4000-8000-000000000004',
  '95000000-0000-4000-8000-000000000002',
  '96000000-0000-4000-8000-000000000002',
  '92000000-0000-4000-8000-000000000001',
  'test.milestone',
  1,
  'award',
  17,
  'rollback_test',
  'Second-user isolation fixture.',
  '93000000-0000-4000-8000-000000000001'
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub',
  '95000000-0000-4000-8000-000000000001',
  true
);

DO $score_derivation_and_isolation_test$
DECLARE
  v_count integer;
  v_points bigint;
  v_rejected boolean := false;
BEGIN
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.official_points_ledger;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'User can see % ledger rows, expected 2', v_count;
  END IF;

  SELECT t.net_points INTO v_points
    FROM public.user_point_totals AS t;
  IF v_points <> 12 THEN
    RAISE EXCEPTION 'Derived net score is %, expected 12', v_points;
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.user_points_by_stage AS s
    WHERE s.net_points = 12 AND s.stage_number = 1;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Stage score breakdown did not include the compensating entry';
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.user_points_by_milestone AS m
    WHERE m.net_points = 12 AND m.milestone_key = 'test.milestone';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Milestone score breakdown did not include the compensating entry';
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.official_points_ledger AS l
    WHERE l.user_id = '95000000-0000-4000-8000-000000000002';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Cross-user ledger rows were visible';
  END IF;

  BEGIN
    INSERT INTO public.official_points_ledger (
      idempotency_key, user_id, idea_id, configuration_version_id,
      milestone_key, stage_number, entry_kind, points, source, reason, recorded_by
    )
    VALUES (
      '94000000-0000-4000-8000-000000000005',
      '95000000-0000-4000-8000-000000000001',
      '96000000-0000-4000-8000-000000000001',
      '92000000-0000-4000-8000-000000000001',
      'test.milestone', 1, 'award', 17, 'client', 'Unauthorized client write.',
      '95000000-0000-4000-8000-000000000001'
    );
    RAISE EXCEPTION 'Authenticated user inserted an official ledger row';
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Unauthorised direct ledger write was not rejected';
  END IF;
END
$score_derivation_and_isolation_test$;

RESET ROLE;
ROLLBACK;