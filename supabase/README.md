# Javaneh core database

The core schema is installed by the ordered SQL migrations in `migrations/`.
The local Supabase migration role is `postgres`; in the current local stack it
cannot grant privileges on `auth` or create a trigger on `auth.users`.

Before applying the migration for the first time, run
`operations/identity-bridge-prerequisite.sql` in the target local/test database
after connecting directly as `supabase_admin` (not through `SET ROLE`). This
one-time provisioning step:

- creates only `javaneh_identity_bridge` and `javaneh_identity_executor`,
  with the approved restricted role attributes;
- grants those roles to the trusted migration role `postgres` only, so it
  can set function/schema ownership during migrations;
- grants the bridge role only `USAGE` on `auth` and `EXECUTE` on
  `auth.uid()`; and
- grants `postgres` only `REFERENCES` on `auth.users`, needed by the owner
  foreign key, and grants the executor `USAGE` on `extensions` plus
  `EXECUTE` on SHA-256; and
- grants `postgres` only the public-schema object-creation and
  `auth.users` trigger privileges required by the migration.

Neither client role is granted membership in an internal role. Do not grant
these roles to `anon`, `authenticated`, `service_role`, or `authenticator`.
The migration checks each prerequisite and fails rather than weakening the
design. The internal roles are never function fallbacks or table owners.

Use only an isolated local or dedicated test Supabase project for applying
and testing this schema. Do not apply it to production. Keep the private
schema out of the PostgREST exposed-schema list; the repository's local
configuration exposes only `public`.
The migration wraps all schema, privilege, and trigger changes in one
transaction and is intentionally a one-time migration: Supabase migration
history, rather than `IF NOT EXISTS`, prevents accidental reapplication.
The Supabase CLI was unavailable during local validation; SQL was applied
through PostgreSQL directly.

The rollback-only integration checks are in `tests/core_database.sql`. Run
them as `supabase_admin` against the isolated local database after applying
the migration. The script creates temporary Auth fixtures inside one
transaction and rolls the entire test transaction back.
Participants can read their own ideas and live stages. Confirmed-stage
snapshots remain inaccessible to client roles until the deferred visibility
decision in 03G is resolved.

The SQL function contract returns JSON objects with an `outcome` key. Save
results additionally include `result_revision`; replays include
`original_outcome`. Authentication failures raise SQLSTATE `42501`, and
unsupported isolation levels raise SQLSTATE `25001`.
