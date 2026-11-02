-- Run once before applying the core migration. Use the direct postgres
-- session on hosted Supabase, or supabase_admin for local/test provisioning.
BEGIN;

DO $$
BEGIN
  IF current_user NOT IN ('postgres', 'supabase_admin')
     OR session_user <> current_user THEN
    RAISE EXCEPTION
      'Connect directly as postgres (hosted) or supabase_admin (local/test) to run this prerequisite'
      USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'javaneh_identity_bridge'
  ) THEN
    CREATE ROLE javaneh_identity_bridge;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'javaneh_identity_executor'
  ) THEN
    CREATE ROLE javaneh_identity_executor;
  END IF;
END
$$;

ALTER ROLE javaneh_identity_bridge
  NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE;
ALTER ROLE javaneh_identity_executor
  NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER NOCREATEDB NOCREATEROLE;

-- Only the trusted migration role may assume the internal owners.
GRANT javaneh_identity_bridge, javaneh_identity_executor TO postgres;

DO $privilege_check$
BEGIN
  IF current_user = 'supabase_admin' THEN
    -- Local/test provisioning: postgres does not have these privileges there.
    GRANT USAGE ON SCHEMA auth TO javaneh_identity_bridge;
    GRANT EXECUTE ON FUNCTION auth.uid() TO javaneh_identity_bridge;
    GRANT REFERENCES ON TABLE auth.users TO postgres;
    GRANT USAGE ON SCHEMA extensions TO javaneh_identity_executor;
    GRANT EXECUTE ON FUNCTION extensions.digest(bytea, text)
      TO javaneh_identity_executor;
    GRANT CREATE ON SCHEMA public TO postgres;
    GRANT TRIGGER ON TABLE auth.users TO postgres;
  ELSE
    -- Hosted postgres must rely only on privileges already effective for the
    -- internal roles; its effective Auth privileges are not necessarily grantable.
    IF NOT pg_catalog.has_schema_privilege(
         'javaneh_identity_bridge', 'auth', 'USAGE'
       )
       OR NOT pg_catalog.has_function_privilege(
         'javaneh_identity_bridge', 'auth.uid()', 'EXECUTE'
       ) THEN
      RAISE EXCEPTION
        'Hosted ACL blocker: javaneh_identity_bridge needs effective auth USAGE and auth.uid() EXECUTE'
        USING ERRCODE = '42501';
    END IF;

    IF NOT pg_catalog.has_schema_privilege(
         'javaneh_identity_executor', 'extensions', 'USAGE'
       )
       OR NOT pg_catalog.has_function_privilege(
         'javaneh_identity_executor', 'extensions.digest(bytea,text)', 'EXECUTE'
       ) THEN
      RAISE EXCEPTION
        'Hosted ACL blocker: javaneh_identity_executor needs effective extensions USAGE and extensions.digest(bytea,text) EXECUTE'
        USING ERRCODE = '42501';
    END IF;

    IF NOT pg_catalog.has_table_privilege('postgres', 'auth.users', 'REFERENCES')
       OR NOT pg_catalog.has_table_privilege('postgres', 'auth.users', 'TRIGGER')
       OR NOT pg_catalog.has_schema_privilege('postgres', 'public', 'CREATE') THEN
      RAISE EXCEPTION
        'Hosted migration session lacks an effective Auth or public-schema privilege required by the core migration'
        USING ERRCODE = '42501';
    END IF;
  END IF;
END
$privilege_check$;

COMMIT;
