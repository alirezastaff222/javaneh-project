-- Use only against the same isolated disposable database as setup.
BEGIN;

CREATE TABLE IF NOT EXISTS public.m9r13_classification_claim_fixture (
  owner_id uuid PRIMARY KEY,
  idea_id uuid NOT NULL UNIQUE,
  creation_request_id uuid NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS public.m9r13_classification_claim_outcomes (
  client_id integer PRIMARY KEY,
  outcome text NOT NULL CHECK (outcome IN ('claimed', 'in_progress'))
);

SELECT pg_catalog.set_config(
  'test.m9r13_idea_id',
  COALESCE((
    SELECT fixture.idea_id::text
    FROM public.m9r13_classification_claim_fixture AS fixture
    WHERE fixture.creation_request_id =
      'ab970000-0000-4000-8000-000000000002'
  ), ''),
  true
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'ab970000-0000-4000-8000-000000000001', true
);

DO $phase7_concurrency_cleanup$
DECLARE
  v_idea_id uuid := NULLIF(
    pg_catalog.current_setting('test.m9r13_idea_id'), ''
  )::uuid;
  v_result jsonb;
BEGIN
  IF v_idea_id IS NOT NULL THEN
    v_result := public.delete_own_idea(v_idea_id);
    IF v_result->>'outcome' NOT IN (
      'deleted', 'not_found_or_already_deleted'
    ) THEN
      RAISE EXCEPTION 'Phase 7 concurrency idea cleanup failed: %', v_result;
    END IF;
  END IF;
END
$phase7_concurrency_cleanup$;

RESET ROLE;

DELETE FROM public.idea_deletion_audit AS audit
WHERE audit.deleted_idea_id = (
  SELECT fixture.idea_id
  FROM public.m9r13_classification_claim_fixture AS fixture
  WHERE fixture.creation_request_id =
    'ab970000-0000-4000-8000-000000000002'
);
DELETE FROM auth.users AS users
WHERE users.id = (
  SELECT fixture.owner_id
  FROM public.m9r13_classification_claim_fixture AS fixture
  WHERE fixture.creation_request_id =
    'ab970000-0000-4000-8000-000000000002'
);
DROP TABLE public.m9r13_classification_claim_outcomes;
DROP TABLE public.m9r13_classification_claim_fixture;

DO $phase7_concurrency_cleanup_assertion$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM auth.users AS users
    WHERE users.id = 'ab970000-0000-4000-8000-000000000001'
  ) OR EXISTS (
    SELECT 1
    FROM public.ideas AS idea
    WHERE idea.creation_request_id =
      'ab970000-0000-4000-8000-000000000002'
  ) OR EXISTS (
    SELECT 1
    FROM public.idea_deletion_audit AS audit
    WHERE audit.creation_request_id =
      'ab970000-0000-4000-8000-000000000002'
  ) OR pg_catalog.to_regclass(
    'public.m9r13_classification_claim_outcomes'
  ) IS NOT NULL OR pg_catalog.to_regclass(
    'public.m9r13_classification_claim_fixture'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'Phase 7 concurrency fixture cleanup was incomplete';
  END IF;
END
$phase7_concurrency_cleanup_assertion$;

COMMIT;
