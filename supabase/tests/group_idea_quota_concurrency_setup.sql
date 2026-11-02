-- Run only in a fresh disposable database as supabase_admin.
-- Two existing group ideas leave exactly one slot for concurrent clients.
BEGIN;

CREATE TABLE public.group_quota_race_state (group_id uuid NOT NULL);
CREATE TABLE public.group_quota_race_outcomes (
  client_id integer PRIMARY KEY,
  outcome text NOT NULL,
  idea_id uuid
);
GRANT SELECT ON public.group_quota_race_state TO authenticated;
GRANT INSERT ON public.group_quota_race_outcomes TO authenticated;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES (
  'a8100000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'group-quota-race@test.invalid', '',
  '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a8100000-0000-4000-8000-000000000001', true
);
SELECT pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"a8100000-0000-4000-8000-000000000001","email":"group-quota-race@test.invalid"}',
  true
);
DO $seed_group_quota$
DECLARE
  v_result jsonb;
  v_group_id uuid;
BEGIN
  v_result := public.create_participant_group('Quota race group', '');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Group setup failed: %', v_result;
  END IF;
  v_group_id := (v_result->>'group_id')::uuid;
  INSERT INTO public.group_quota_race_state (group_id) VALUES (v_group_id);
  v_result := public.create_group_idea(
    v_group_id, 'a8110000-0000-4000-8000-000000000001'
  );
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'First seed idea failed: %', v_result;
  END IF;
  v_result := public.create_group_idea(
    v_group_id, 'a8110000-0000-4000-8000-000000000002'
  );
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Second seed idea failed: %', v_result;
  END IF;
END
$seed_group_quota$;
RESET ROLE;
COMMIT;
