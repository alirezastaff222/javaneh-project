# Javaneh --- Deletion Audit Specification (03H)

**Document ID:** JAVANEH-DB-03H\
**Status:** Deletion-audit design approved; implementation and managed
Supabase validation pending\
**Version:** Reconstructed reference specification\
**Related document:** `03G-final-database-architecture.md`

> **Provenance:** This is a reconstructed reference copy based on the
> deletion-audit design approved during the Javaneh architecture
> process. It is not a byte-for-byte copy of an earlier source file. The
> design is approved conceptually, but trigger behavior has not yet been
> proven in a live or isolated Supabase test environment.

## 1. Purpose

Define audit behavior for permanent idea deletion. Substantive idea data
must be permanently removed while a minimal, content-free record remains
that deletion occurred.

Two authorized paths exist: 1. participant-initiated deletion of an
eligible idea; 2. account deletion through Supabase Auth, causing ideas
to be deleted by the `auth.users` FK cascade.

Every other deletion path is unauthorized and must be rejected.
Authorization must not be inferred merely because a row is being deleted
or a trigger is nested.

## 2. Non-negotiable invariants

1.  Every authorized idea deletion produces exactly one corresponding
    audit event.
2.  Idea deletion and audit insertion are atomic in one transaction.
3.  Audit failure aborts and rolls back deletion.
4.  Participant and account-cascade deletion are explicitly
    distinguished.
5.  Unknown, direct, unmarked, or unauthorized deletion is rejected.
6.  `pg_trigger_depth()` is diagnostic only, not proof of authorized
    account cascade.
7.  A custom transaction-local setting alone is not sufficient
    authorization proof.
8.  Direct client deletion of ideas is prohibited by grants and RLS.
9.  Only the hardened participant deletion function may initiate
    participant deletion.
10. The `auth.users` account-deletion trigger is the trusted entry point
    for account-cascade audit pre-recording.
11. Audit contains no substantive idea content.
12. Constraints and exact-match checks prevent duplicate audit records.

## 3. Audit table

Use `public.idea_deletion_audit` as defined in 03G.

Fields: - `deleted_idea_id`: deleted idea UUID, primary key, no FK to
`ideas`; - `owner_id`: former owner UUID, no FK to `auth.users`; -
`actor_id`: nullable UUID FK to `auth.users(id)` with
`ON DELETE SET NULL`; - `creation_request_id`: original creation
idempotency UUID; - `deleted_at`: timestamp; - `operation`: exactly
`participant_delete` or `account_cascade`; - `reason_code`: controlled,
content-free classification.

Constraints: - PK on `deleted_idea_id`; - unique
`(owner_id, creation_request_id)`; - no FK from deleted idea ID or
former owner ID back to deleted rows; - no idea title, description,
stage data, messages, AI output, dossier content, file names, or other
substantive content; - no ordinary client-facing read/write policies.

Any future administrative access requires a separate least-privilege
design.

## 4. Participant-initiated deletion

### 4.1 Entry point

Only:

`delete_own_idea(p_idea_id)`

The function must: 1. derive actor from `auth.uid()`; 2. reject
unauthenticated calls; 3. acquire the same per-owner quota advisory lock
used by creation; 4. lock target idea row; 5. verify actor owns idea; 6.
allow only `draft` and `in_progress`; 7. reject `submitted` in this
initial package; 8. establish transaction-local deletion context for
exact idea and owner; 9. delete idea; 10. allow dependent rows to
cascade; 11. rely on idea deletion trigger to write exactly one
`participant_delete` audit event; 12. commit deletion and audit
together.

Do not trust caller-supplied actor/owner values.

### 4.2 Exact-match context

The participant function sets a transaction-local marker identifying: -
authorized path `participant_delete`; - exact idea ID; - exact owner ID.

The idea deletion trigger must not trust the marker alone. It
verifies: - marker identifies exact `OLD.id`; - marker identifies exact
`OLD.owner_id`; - `auth.uid()` equals `OLD.owner_id`; - call is through
the controlled participant deletion path; - eligible lifecycle state was
enforced under the required lock and is reliably verifiable.

Only when all checks match may the trigger insert a `participant_delete`
audit row. Missing, malformed, mismatched, or unexpected context is
rejected.

### 4.3 Audit insertion

Insert: - `deleted_idea_id = OLD.id`; - `owner_id = OLD.owner_id`; -
`actor_id = auth.uid()`; -
`creation_request_id = OLD.creation_request_id`; -
`operation = 'participant_delete'`; - approved content-free
`reason_code`; - deletion timestamp.

Do not copy idea content. PK and unique owner/request constraint provide
duplicate protection. A conflict must not silently count as a successful
new deletion.

## 5. Account deletion through Supabase Auth

### 5.1 Trusted entry point

Account deletion begins with deletion of the corresponding `auth.users`
row.

A controlled `BEFORE DELETE` trigger on `auth.users` establishes
account-deletion context and pre-inserts audit rows for every idea owned
by that account before the FK cascade deletes those ideas.

Use `OLD.id` as account identity. Do not rely on `auth.uid()` being
populated during administrative, service, or Auth-managed deletion; it
may be null.

### 5.2 Pre-record audit rows

Within the same transaction: 1. identify all `public.ideas` rows where
`owner_id = OLD.id`; 2. pre-insert exactly one content-free
`account_cascade` audit row per idea; 3. record idea ID, former owner
ID, creation request ID, timestamp, and approved content-free reason; 4.
set `actor_id` null unless a verified actor is available and explicitly
authorized; 5. establish transaction-local account-deletion context tied
to exact `OLD.id`; 6. allow the FK cascade to proceed.

Audit rows must be inserted before the idea deletion trigger runs. Any
pre-insert failure aborts account deletion.

### 5.3 Idea-trigger exact-match validation

When FK cascade deletes an idea, the idea deletion trigger accepts it as
account cascade only if: - account-deletion context exists; - context
identifies `OLD.owner_id`; - context was established by trusted
`auth.users BEFORE DELETE` trigger; - a pre-existing audit row exists
for exact `OLD.id`; - audit row owner equals `OLD.owner_id`; - audit
`creation_request_id` equals `OLD.creation_request_id`; - audit
operation is `account_cascade`.

The idea trigger does not insert a second audit row. The account trigger
has already inserted it.

Any mismatch rejects deletion.

### 5.4 Why pre-recording is required

A plain `ON DELETE CASCADE` does not itself prove an authorized
account-deletion workflow for audit purposes. Pre-recording creates an
exact per-idea audit witness before the dependent idea row is removed.
The idea trigger validates that witness.

Audit rows and cascaded deletes remain in one transaction. Rollback
removes both pre-recorded audit rows and attempted deletions.

## 6. Reject all other deletion paths

Accepted path A: participant deletion, with all participant marker,
actor, owner, target ID, lifecycle, and controlled-function checks
matching.

Accepted path B: account cascade, with trusted account context and exact
pre-recorded `account_cascade` audit row matching.

Reject: - direct delete by `anon`; - direct delete by `authenticated`; -
direct delete through unapproved service path; - manual SQL delete
without approved participant context; - transaction marker with wrong
idea or owner; - marker without trusted function/trigger path; - account
context that does not match `OLD.owner_id`; - account cascade without
matching pre-recorded audit row; - audit row with mismatching creation
request ID; - any unknown or ambiguous deletion origin.

Never classify unknown deletion as account cascade merely because
`auth.uid()` is null, trigger depth is nested, or `pg_trigger_depth()`
is greater than one.

## 7. Trigger and privilege hardening

### 7.1 Dedicated executor

Use the dedicated executor specified in 03G: - `NOLOGIN`; -
`NOBYPASSRLS`; - not owner of application tables; - not assumable by
client-facing roles; - only required grants.

Do not use `postgres` or `supabase_admin` as general-purpose
`SECURITY DEFINER` owner.

### 7.2 Function hardening

Privileged functions and trigger functions: - use `SECURITY DEFINER`
only when necessary; - set `search_path = pg_catalog`; - fully qualify
non-catalog references; - revoke execution from `PUBLIC`; - grant only
required roles; - validate identities and exact context/row matches; -
avoid dynamic SQL where possible; - fail closed on missing or malformed
context.

### 7.3 Direct table privileges

Client-facing roles must not have direct `DELETE` on `public.ideas`. RLS
must be enabled and forced on all five application tables. RLS does not
replace correct grants and controlled functions.

### 7.4 Trigger depth

`pg_trigger_depth()` may be diagnostic or a secondary consistency check.
It must never be the sole or decisive authorization test for
account-cascade deletion.

## 8. Atomicity and failure handling

Participant transaction includes: - participant validation; - exact
participant context; - idea deletion; - dependent cascades; - one
participant audit insert.

Account transaction includes: - `auth.users BEFORE DELETE`; - account
context; - all account-cascade audit pre-inserts; - FK cascade to
ideas; - idea-trigger exact-match checks; - dependent cascades; - final
account deletion.

Rollback guarantees: - participant audit insert failure rolls back idea
deletion; - any account audit pre-insert failure rolls back account
deletion; - cascade without exact audit witness rolls back cascade and
account deletion; - failed exact-match check leaves no partial deletion
or orphaned audit row.

## 9. Mandatory isolated Supabase tests

### 9.1 Participant deletion

1.  Owner deletes own `draft`: succeeds, exactly one
    `participant_delete` row.
2.  Owner deletes own `in_progress`: succeeds, exactly one audit row.
3.  Owner deletes `submitted`: rejected.
4.  User A deletes User B idea: generic rejection, no audit.
5.  Unauthenticated deletion: rejected.
6.  Direct client `DELETE`: denied.
7.  Repeated deletion: generic `not_found_or_already_deleted`, no
    duplicate.
8.  Audit insertion failure: entire deletion rolls back.
9.  Incorrect participant marker: rejected.
10. Marker for another idea/owner: rejected.

### 9.2 Account cascade

1.  Account with no ideas deletes successfully.
2.  Account with one idea produces exactly one `account_cascade` row.
3.  Account with multiple ideas produces one matching row per idea.
4.  Each audit row matches idea ID, owner ID, and creation request ID.
5.  `actor_id` is null when no verified actor exists.
6.  Audit pre-insert failure rolls back account deletion.
7.  Missing exact audit witness rolls back cascade.
8.  Forged account context without trusted trigger path is rejected.
9.  Stale/unrelated audit row cannot authorize another idea deletion.
10. Account trigger and idea trigger do not duplicate audit.
11. Actual managed Supabase Auth trigger execution and FK behavior pass.

### 9.3 Security

-   `anon`, `authenticated`, and `service_role` cannot assume executor.
-   executor is `NOLOGIN NOBYPASSRLS`.
-   executor is not application table owner.
-   clients cannot directly delete.
-   audit table is not directly readable/writable by ordinary clients.
-   trigger functions have hardened search path and grants.
-   no broad `postgres`/`supabase_admin` definer fallback.

## 10. Environment facts and deployment gate

Read-only observations of the production project: - status Active; -
region `us-east-1`; - PostgreSQL `17.11`; - inspected session isolation
`READ COMMITTED`; - SHA-256 digest function available in `extensions`; -
advisory-lock functions available; - inspected `postgres` role has
`CREATEROLE` and `BYPASSRLS`, but is not superuser; - `anon`,
`authenticated`, `service_role`, and `authenticator` cannot assume or
inherit `postgres`; - no application tables were present in inspected
`public` schema; - no custom account-deletion trigger was found in
inspected scope; - expected migration-history schema/table was not found
in initial preflight.

These observations do not prove implementation or trigger behavior.

**Critical restriction:** Do not install the account-deletion trigger or
apply these migrations to production until complete behavior passes in a
separate isolated Supabase test project.

The current owner decision is to leave production unchanged until a test
environment is available.

If the managed Auth trigger cannot be safely installed or validated in
isolation, stop and request an explicit security/architecture decision.
Do not fall back to unmarked cascade acceptance, `pg_trigger_depth()`
authorization, or a broad administrative definer role.

## 11. Approval statement

The design is conceptually approved: - participant deletion requires
exact controlled context and authenticated owner match; - account
deletion requires trusted `auth.users BEFORE DELETE` pre-recording one
audit event per idea; - idea deletion trigger validates the exact
pre-recorded event and does not duplicate it; - all other deletion paths
fail closed; - audit and deletion are atomic.

**Implementation status:** Not implemented or validated. Managed
Supabase Auth trigger behavior remains a mandatory isolated-environment
test.
