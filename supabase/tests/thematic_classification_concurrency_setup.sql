-- Use only against an isolated disposable database. This fixture commits so
-- independent pgbench sessions can contend for one logical classification.
BEGIN;

CREATE TABLE public.m9r13_classification_claim_fixture (
  owner_id uuid PRIMARY KEY,
  idea_id uuid NOT NULL UNIQUE,
  creation_request_id uuid NOT NULL UNIQUE
);

CREATE TABLE public.m9r13_classification_claim_outcomes (
  client_id integer PRIMARY KEY,
  outcome text NOT NULL CHECK (outcome IN ('claimed', 'in_progress'))
);
GRANT INSERT ON public.m9r13_classification_claim_outcomes TO service_role;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES (
  'ab970000-0000-4000-8000-000000000001', 'authenticated',
  'authenticated', 'phase7-concurrent-owner@test.invalid', '',
  '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'ab970000-0000-4000-8000-000000000001', true
);

DO $phase7_concurrency_setup$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_revision integer;
BEGIN
  v_result := public.create_idea('ab970000-0000-4000-8000-000000000002');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Phase 7 concurrency idea creation failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;

  v_result := public.save_idea_content(
    v_idea_id, 'ab970000-0000-4000-8000-000000000003', 1,
    '[{"stage_number":1,"data":{"content":"Concurrent classification problem fixture."}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Phase 7 concurrency Stage 1 save failed: %', v_result;
  END IF;
  v_revision := (v_result->>'result_revision')::integer;
  v_result := public.request_idea_stage_confirmation(v_idea_id, 1::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Phase 7 concurrency Stage 1 request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 1::smallint, v_revision);
  IF v_result->>'outcome' <> 'confirmed' THEN
    RAISE EXCEPTION 'Phase 7 concurrency Stage 1 confirmation failed: %',
      v_result;
  END IF;

  v_result := public.save_idea_content(
    v_idea_id, 'ab970000-0000-4000-8000-000000000004', v_revision,
    '[{"stage_number":2,"data":{"content":"Concurrent classification capacity fixture."}}]'::jsonb
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Phase 7 concurrency Stage 2 save failed: %', v_result;
  END IF;
  v_revision := (v_result->>'result_revision')::integer;
  v_result := public.request_idea_stage_confirmation(v_idea_id, 2::smallint);
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Phase 7 concurrency Stage 2 request failed: %', v_result;
  END IF;
  v_result := public.confirm_idea_stage(v_idea_id, 2::smallint, v_revision);
  IF v_result->>'outcome' <> 'confirmed' THEN
    RAISE EXCEPTION 'Phase 7 concurrency Stage 2 confirmation failed: %',
      v_result;
  END IF;
END
$phase7_concurrency_setup$;

RESET ROLE;
INSERT INTO public.m9r13_classification_claim_fixture (
  owner_id, idea_id, creation_request_id
)
SELECT
  idea.owner_id,
  idea.id,
  idea.creation_request_id
FROM public.ideas AS idea
WHERE idea.creation_request_id = 'ab970000-0000-4000-8000-000000000002';
COMMIT;

SELECT
  fixture.owner_id,
  idea.id AS idea_id,
  stage_1.confirmed_version_id AS stage_1_revision_id,
  stage_2.confirmed_version_id AS stage_2_revision_id
FROM public.m9r13_classification_claim_fixture AS fixture
JOIN public.ideas AS idea
  ON idea.id = fixture.idea_id
JOIN public.idea_stages AS stage_1
  ON stage_1.idea_id = idea.id AND stage_1.stage_number = 1
JOIN public.idea_stages AS stage_2
  ON stage_2.idea_id = idea.id AND stage_2.stage_number = 2
WHERE fixture.creation_request_id = 'ab970000-0000-4000-8000-000000000002';
