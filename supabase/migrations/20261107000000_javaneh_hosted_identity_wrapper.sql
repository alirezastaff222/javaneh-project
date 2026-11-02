BEGIN;

DO $identity_prerequisite_check$
BEGIN
  IF current_user <> 'postgres' OR session_user <> current_user THEN
    RAISE EXCEPTION
      'Run this identity-wrapper migration directly as postgres'
      USING ERRCODE = '42501';
  END IF;

  IF NOT pg_catalog.pg_has_role(
       'postgres', 'javaneh_identity_bridge', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'anon', 'javaneh_identity_bridge', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'authenticated', 'javaneh_identity_bridge', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'service_role', 'javaneh_identity_bridge', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'authenticator', 'javaneh_identity_bridge', 'MEMBER'
     ) THEN
    RAISE EXCEPTION
      'The bridge role is missing migration-only membership or is assumable by a client role'
      USING ERRCODE = '42501';
  END IF;

  IF pg_catalog.to_regnamespace('javaneh_private') IS NULL
     OR pg_catalog.to_regprocedure('auth.uid()') IS NULL
     OR NOT pg_catalog.has_schema_privilege('postgres', 'auth', 'USAGE')
     OR NOT pg_catalog.has_function_privilege(
       'postgres', 'auth.uid()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION
      'The private schema or postgres Auth access required by the narrow wrapper is unavailable'
      USING ERRCODE = '42501';
  END IF;
END
$identity_prerequisite_check$;

CREATE OR REPLACE FUNCTION javaneh_private.auth_uid()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT auth.uid()
$function$;

ALTER FUNCTION javaneh_private.auth_uid() OWNER TO postgres;
REVOKE ALL ON FUNCTION javaneh_private.auth_uid()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION javaneh_private.auth_uid()
  TO javaneh_identity_bridge;

SET ROLE javaneh_identity_bridge;

CREATE OR REPLACE FUNCTION javaneh_private.current_uid()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT javaneh_private.auth_uid()
$function$;

REVOKE ALL ON FUNCTION javaneh_private.current_uid()
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION javaneh_private.current_uid()
  TO authenticated, javaneh_identity_executor;

RESET ROLE;
ALTER FUNCTION javaneh_private.current_uid() OWNER TO javaneh_identity_bridge;

DO $identity_wrapper_validation$
BEGIN
  IF pg_catalog.pg_get_userbyid((
       SELECT procedure.proowner
       FROM pg_catalog.pg_proc AS procedure
       JOIN pg_catalog.pg_namespace AS namespace
         ON namespace.oid = procedure.pronamespace
       WHERE namespace.nspname = 'javaneh_private'
         AND procedure.proname = 'auth_uid'
     )) <> 'postgres'
     OR pg_catalog.pg_get_userbyid((
       SELECT procedure.proowner
       FROM pg_catalog.pg_proc AS procedure
       JOIN pg_catalog.pg_namespace AS namespace
         ON namespace.oid = procedure.pronamespace
       WHERE namespace.nspname = 'javaneh_private'
         AND procedure.proname = 'current_uid'
     )) <> 'javaneh_identity_bridge'
     OR pg_catalog.has_function_privilege(
       'anon', 'javaneh_private.auth_uid()', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'authenticated', 'javaneh_private.auth_uid()', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'javaneh_private.current_uid()', 'EXECUTE'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'javaneh_private.current_uid()', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION
      'The identity-wrapper owner or execution grants are unsafe'
      USING ERRCODE = '42501';
  END IF;
END
$identity_wrapper_validation$;

COMMIT;
