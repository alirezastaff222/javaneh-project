-- Run once as supabase_admin before applying the core migration.
-- The migration role (postgres) cannot grant access to the auth schema or
-- create a trigger on auth.users in the local Supabase environment.
BEGIN;

DO $$
BEGIN
  IF current_user <> 'supabase_admin' OR session_user <> 'supabase_admin' THEN
    RAISE EXCEPTION 'Connect directly as supabase_admin to run this prerequisite'
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

-- The bridge must be able to call the verified JWT identity function.
GRANT USAGE ON SCHEMA auth TO javaneh_identity_bridge;
GRANT EXECUTE ON FUNCTION auth.uid() TO javaneh_identity_bridge;

-- Required to create the owner foreign key and call server-side SHA-256.
GRANT REFERENCES ON TABLE auth.users TO postgres;
GRANT USAGE ON SCHEMA extensions TO javaneh_identity_executor;
GRANT EXECUTE ON FUNCTION extensions.digest(bytea, text)
  TO javaneh_identity_executor;

-- The migration role owns its public objects and installs the Auth trigger.
GRANT CREATE ON SCHEMA public TO postgres;
GRANT TRIGGER ON TABLE auth.users TO postgres;

COMMIT;
