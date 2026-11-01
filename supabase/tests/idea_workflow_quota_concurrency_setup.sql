-- Run only in a fresh disposable database as supabase_admin, then drop it.
-- Two active ideas leave exactly one slot for concurrent pgbench clients.
BEGIN;

CREATE TABLE public.m9r8_quota_concurrency_outcomes (
  client_id integer PRIMARY KEY,
  outcome text NOT NULL,
  idea_id uuid
);
GRANT INSERT ON public.m9r8_quota_concurrency_outcomes TO authenticated;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES (
  'a9800000-0000-4000-8000-000000000001', 'authenticated',
  'authenticated', 'm9r8-quota-race@test.invalid', '',
  '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9800000-0000-4000-8000-000000000001', true
);
DO $seed_quota_boundary$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.create_idea('a9810000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'First quota-boundary idea failed: %', v_result;
  END IF;
  v_result := public.create_idea('a9810000-0000-4000-8000-000000000002');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Second quota-boundary idea failed: %', v_result;
  END IF;
END
$seed_quota_boundary$;
RESET ROLE;
COMMIT;
