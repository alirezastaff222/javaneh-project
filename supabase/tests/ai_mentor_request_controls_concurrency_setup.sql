-- Run only in a fresh disposable database. Independent pgbench sessions use
-- these committed fixtures to exercise the same database RPC concurrently.
BEGIN;

CREATE TABLE public.m9r11_mentor_request_outcomes (
  scenario text NOT NULL,
  client_id integer NOT NULL,
  outcome text NOT NULL,
  state text,
  PRIMARY KEY (scenario, client_id)
);
GRANT INSERT ON public.m9r11_mentor_request_outcomes TO authenticated;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a9b21000-0000-4000-8000-000000000001', 'authenticated',
    'authenticated', 'm9r11-race-same@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a9b21000-0000-4000-8000-000000000002', 'authenticated',
    'authenticated', 'm9r11-race-limit@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  );

COMMIT;

SELECT 'a9b21000-0000-4000-8000-000000000001'::uuid AS same_id_user,
       'a9b21000-0000-4000-8000-000000000002'::uuid AS rate_limit_user,
       'a9b22000-0000-4000-8000-000000000001'::uuid AS shared_request_id;