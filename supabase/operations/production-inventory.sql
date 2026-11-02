-- Read-only production inventory for Supabase SQL Editor.
-- Run the whole script in one pass and save every result grid and NOTICE.
-- The DO block dynamically reads migration history only when its table exists;
-- it does not create objects or modify application data.

SELECT
  current_database() AS database_name,
  current_user AS current_role,
  session_user AS login_role,
  current_setting('server_version') AS postgres_version,
  current_setting('transaction_read_only') AS transaction_read_only;

SELECT
  namespace.nspname AS schema_name,
  relation.relname AS object_name,
  CASE relation.relkind
    WHEN 'r' THEN 'table'
    WHEN 'p' THEN 'partitioned table'
    WHEN 'v' THEN 'view'
    WHEN 'm' THEN 'materialized view'
    WHEN 'f' THEN 'foreign table'
    ELSE relation.relkind::text
  END AS object_type,
  pg_catalog.pg_get_userbyid(relation.relowner) AS owner,
  relation.relrowsecurity AS row_level_security,
  relation.relforcerowsecurity AS force_row_level_security
FROM pg_catalog.pg_class AS relation
JOIN pg_catalog.pg_namespace AS namespace
  ON namespace.oid = relation.relnamespace
WHERE namespace.nspname IN (
  'public', 'auth', 'extensions', 'javaneh_private', 'supabase_migrations'
)
  AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
ORDER BY namespace.nspname, relation.relname;

SELECT
  columns.table_schema AS schema_name,
  columns.table_name AS object_name,
  columns.ordinal_position,
  columns.column_name,
  columns.data_type,
  columns.udt_name,
  columns.is_nullable,
  columns.column_default
FROM information_schema.columns AS columns
WHERE columns.table_schema IN ('public', 'auth', 'javaneh_private')
ORDER BY columns.table_schema, columns.table_name, columns.ordinal_position;

SELECT
  namespace.nspname AS schema_name,
  relation.relname AS table_name,
  constraint_row.conname AS constraint_name,
  constraint_row.contype AS constraint_type,
  pg_catalog.pg_get_constraintdef(constraint_row.oid, true) AS definition,
  constraint_row.convalidated AS validated
FROM pg_catalog.pg_constraint AS constraint_row
JOIN pg_catalog.pg_class AS relation
  ON relation.oid = constraint_row.conrelid
JOIN pg_catalog.pg_namespace AS namespace
  ON namespace.oid = relation.relnamespace
WHERE namespace.nspname IN ('public', 'auth')
ORDER BY namespace.nspname, relation.relname, constraint_row.conname;

SELECT
  namespace.nspname AS schema_name,
  relation.relname AS table_name,
  index_row.relname AS index_name,
  pg_catalog.pg_get_indexdef(index_row.oid) AS definition
FROM pg_catalog.pg_index AS index_metadata
JOIN pg_catalog.pg_class AS relation
  ON relation.oid = index_metadata.indrelid
JOIN pg_catalog.pg_class AS index_row
  ON index_row.oid = index_metadata.indexrelid
JOIN pg_catalog.pg_namespace AS namespace
  ON namespace.oid = relation.relnamespace
WHERE namespace.nspname IN ('public', 'auth')
ORDER BY namespace.nspname, relation.relname, index_row.relname;

SELECT
  policy.schemaname AS schema_name,
  policy.tablename AS table_name,
  policy.policyname,
  policy.permissive,
  policy.roles,
  policy.cmd,
  policy.qual AS using_expression,
  policy.with_check
FROM pg_catalog.pg_policies AS policy
WHERE policy.schemaname IN ('public', 'auth')
ORDER BY policy.schemaname, policy.tablename, policy.policyname;

SELECT
  namespace.nspname AS schema_name,
  relation.relname AS table_name,
  trigger_row.tgname AS trigger_name,
  pg_catalog.pg_get_userbyid(procedure.proowner) AS trigger_function_owner,
  pg_catalog.pg_get_triggerdef(trigger_row.oid, true) AS definition,
  trigger_row.tgenabled AS enabled_state
FROM pg_catalog.pg_trigger AS trigger_row
JOIN pg_catalog.pg_class AS relation
  ON relation.oid = trigger_row.tgrelid
JOIN pg_catalog.pg_namespace AS namespace
  ON namespace.oid = relation.relnamespace
JOIN pg_catalog.pg_proc AS procedure
  ON procedure.oid = trigger_row.tgfoid
WHERE NOT trigger_row.tgisinternal
  AND (
    namespace.nspname IN ('public', 'auth')
    OR relation.relname = 'users'
  )
ORDER BY namespace.nspname, relation.relname, trigger_row.tgname;

SELECT
  namespace.nspname AS schema_name,
  procedure.proname AS function_name,
  pg_catalog.pg_get_function_identity_arguments(procedure.oid) AS arguments,
  pg_catalog.pg_get_function_result(procedure.oid) AS result_type,
  pg_catalog.pg_get_userbyid(procedure.proowner) AS owner,
  procedure.prosecdef AS security_definer,
  procedure.provolatile AS volatility,
  procedure.proconfig AS function_settings,
  procedure.proacl AS explicit_acl
FROM pg_catalog.pg_proc AS procedure
JOIN pg_catalog.pg_namespace AS namespace
  ON namespace.oid = procedure.pronamespace
WHERE namespace.nspname IN ('public', 'javaneh_private')
   OR (namespace.nspname = 'auth' AND procedure.proname = 'uid')
   OR (
     namespace.nspname = 'extensions'
     AND procedure.oid = pg_catalog.to_regprocedure('extensions.digest(bytea,text)')
   )
ORDER BY namespace.nspname, procedure.proname,
  pg_catalog.pg_get_function_identity_arguments(procedure.oid);

SELECT
  role.rolname,
  role.rolsuper,
  role.rolinherit,
  role.rolcreaterole,
  role.rolcreatedb,
  role.rolcanlogin,
  role.rolreplication,
  role.rolbypassrls,
  role.rolconnlimit
FROM pg_catalog.pg_roles AS role
WHERE role.rolname IN (
  'postgres', 'supabase_admin', 'supabase_auth_admin',
  'javaneh_identity_bridge', 'javaneh_identity_executor',
  'anon', 'authenticated', 'service_role', 'authenticator'
)
ORDER BY role.rolname;

SELECT
  member_role.rolname AS member_role,
  granted_role.rolname AS granted_role,
  membership.admin_option
FROM pg_catalog.pg_auth_members AS membership
JOIN pg_catalog.pg_roles AS granted_role
  ON granted_role.oid = membership.roleid
JOIN pg_catalog.pg_roles AS member_role
  ON member_role.oid = membership.member
WHERE member_role.rolname IN (
  'postgres', 'supabase_admin', 'javaneh_identity_bridge',
  'javaneh_identity_executor', 'anon', 'authenticated',
  'service_role', 'authenticator'
)
   OR granted_role.rolname IN (
  'javaneh_identity_bridge', 'javaneh_identity_executor'
)
ORDER BY member_role.rolname, granted_role.rolname;

WITH expected_roles(role_name) AS (
  VALUES
    ('postgres'),
    ('supabase_admin'),
    ('javaneh_identity_bridge'),
    ('javaneh_identity_executor'),
    ('anon'),
    ('authenticated'),
    ('service_role'),
    ('authenticator')
)
SELECT
  expected_roles.role_name,
  role.oid IS NOT NULL AS role_exists,
  CASE WHEN role.oid IS NOT NULL AND pg_catalog.to_regnamespace('auth') IS NOT NULL
    THEN pg_catalog.has_schema_privilege(role.rolname, 'auth', 'USAGE')
  END AS auth_schema_usage,
  CASE WHEN role.oid IS NOT NULL
         AND pg_catalog.to_regprocedure('auth.uid()') IS NOT NULL
    THEN pg_catalog.has_function_privilege(
      role.rolname, pg_catalog.to_regprocedure('auth.uid()'), 'EXECUTE'
    )
  END AS auth_uid_execute,
  CASE WHEN role.oid IS NOT NULL
         AND pg_catalog.to_regclass('auth.users') IS NOT NULL
    THEN pg_catalog.has_table_privilege(role.rolname, 'auth.users', 'REFERENCES')
  END AS auth_users_references,
  CASE WHEN role.oid IS NOT NULL
         AND pg_catalog.to_regclass('auth.users') IS NOT NULL
    THEN pg_catalog.has_table_privilege(role.rolname, 'auth.users', 'TRIGGER')
  END AS auth_users_trigger,
  CASE WHEN role.oid IS NOT NULL
         AND pg_catalog.to_regnamespace('public') IS NOT NULL
    THEN pg_catalog.has_schema_privilege(role.rolname, 'public', 'CREATE')
  END AS public_schema_create,
  CASE WHEN role.oid IS NOT NULL
         AND pg_catalog.to_regnamespace('extensions') IS NOT NULL
    THEN pg_catalog.has_schema_privilege(role.rolname, 'extensions', 'USAGE')
  END AS extensions_schema_usage,
  CASE WHEN role.oid IS NOT NULL
         AND pg_catalog.to_regprocedure('extensions.digest(bytea,text)') IS NOT NULL
    THEN pg_catalog.has_function_privilege(
      role.rolname,
      pg_catalog.to_regprocedure('extensions.digest(bytea,text)'),
      'EXECUTE'
    )
  END AS digest_execute
FROM expected_roles
LEFT JOIN pg_catalog.pg_roles AS role
  ON role.rolname = expected_roles.role_name
ORDER BY expected_roles.role_name;

SELECT
  grants.table_schema AS schema_name,
  grants.table_name AS object_name,
  grants.grantee,
  grants.privilege_type,
  grants.is_grantable
FROM information_schema.role_table_grants AS grants
WHERE grants.table_schema IN ('public', 'auth', 'javaneh_private')
  AND grants.grantee IN (
    'PUBLIC', 'postgres', 'supabase_admin', 'javaneh_identity_bridge',
    'javaneh_identity_executor', 'anon', 'authenticated',
    'service_role', 'authenticator'
  )
ORDER BY grants.table_schema, grants.table_name, grants.grantee,
  grants.privilege_type;

SELECT
  grants.specific_schema AS schema_name,
  grants.routine_name AS function_name,
  grants.grantee,
  grants.privilege_type,
  grants.is_grantable
FROM information_schema.role_routine_grants AS grants
WHERE grants.specific_schema IN (
  'public', 'auth', 'extensions', 'javaneh_private'
)
  AND grants.grantee IN (
    'PUBLIC', 'postgres', 'supabase_admin', 'javaneh_identity_bridge',
    'javaneh_identity_executor', 'anon', 'authenticated',
    'service_role', 'authenticator'
  )
ORDER BY grants.specific_schema, grants.routine_name, grants.grantee,
  grants.privilege_type;

SELECT
  COALESCE(
    pg_catalog.to_regclass('supabase_migrations.schema_migrations')::text,
    'NOT FOUND'
  ) AS supabase_migration_history_relation;

DO $migration_inventory$
DECLARE
  v_history text;
BEGIN
  IF pg_catalog.to_regclass('supabase_migrations.schema_migrations') IS NULL THEN
    RAISE NOTICE 'Migration history relation is absent; no migration rows were read.';
    RETURN;
  END IF;

  EXECUTE $query$
    SELECT COALESCE(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'version', COALESCE(
            pg_catalog.to_jsonb(migration_row)->>'version',
            pg_catalog.to_jsonb(migration_row)->>'migration_version'
          ),
          'name', pg_catalog.to_jsonb(migration_row)->>'name'
        )
        ORDER BY COALESCE(
          pg_catalog.to_jsonb(migration_row)->>'version',
          pg_catalog.to_jsonb(migration_row)->>'migration_version'
        )
      )::text,
      '[]'
    )
    FROM supabase_migrations.schema_migrations AS migration_row
  $query$
  INTO v_history;

  RAISE NOTICE 'Recorded migration versions and names: %', v_history;
END
$migration_inventory$;
