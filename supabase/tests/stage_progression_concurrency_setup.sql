-- Use only against an isolated disposable database. This fixture commits so
-- independent pgbench connections can contend on one pending confirmation.
BEGIN;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES (
  'a9950000-0000-4000-8000-000000000001', 'authenticated',
  'authenticated', 'm9r9-concurrent-owner@test.invalid', '',
  '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9950000-0000-4000-8000-000000000001', true
);

DO $m9r9_concurrency_setup$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
BEGIN
  v_result := public.create_idea('a9960000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Concurrent confirmation idea creation failed: %',
      v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;
  v_result := public.request_idea_stage_confirmation(
    v_idea_id, 1::smallint
  );
  IF v_result->>'outcome' <> 'requested' THEN
    RAISE EXCEPTION 'Concurrent confirmation request setup failed: %',
      v_result;
  END IF;
END
$m9r9_concurrency_setup$;

RESET ROLE;
COMMIT;

SELECT idea.id AS idea_id
  FROM public.ideas AS idea
  WHERE idea.creation_request_id =
    'a9960000-0000-4000-8000-000000000001';
