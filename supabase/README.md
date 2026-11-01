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

The gamification foundation is additive and documented in
`docs/architecture/09R1-gamification-foundation.md`. Its rollback-only SQL
regression suites are `tests/gamification_foundation.sql` (M9R1) and
`tests/gamification_operations.sql` (M9R2). The M9R2 migration adds restricted
role assignment, configuration lifecycle, human milestone validation, award,
and compensating correction RPCs. Use the architecture note's direct
`supabase_admin` procedure to bootstrap the first Platform Owner; there is no
application bootstrap endpoint. Run both test files only against an isolated
local or dedicated test database as `supabase_admin`.

The M9R3 catalog migration is
`migrations/20261101040000_javaneh_gamification_catalog.sql`. Its
rollback-only regression suite is `tests/gamification_catalog.sql`. It adds
the draft competition model, approved Version 1.0 scoring allocations, and
inactive milestone catalog. Apply it after the M9R2 migration and run the test
as `supabase_admin` against the same isolated database. Detailed evaluator
guidance was completed by M9R6. M9R7 later records the approved Qualitative
validation decision for Stage 4; lifecycle approval and activation remain
separate.

The M9R4 validation migration is
`migrations/20261101053000_javaneh_milestone_validation.sql`; its rollback-only
suite is `tests/gamification_validation.sql`. It adds revision-linked
qualitative, objective, and hybrid milestone submissions, append-only event
history, Validator review, and a scoring-eligibility query. Objective checks
are evaluated server-side, hybrid review requires objective success, and a
failed attempt can be retried after the participant saves a new idea revision.
Stage confirmation remains separate. Eligibility reporting does not activate
scoring or write awards; the Version 1.0 configuration and competition remain
draft. M9R6 records the approved guide and M9R7 records the approved Stage 4
Qualitative decision without changing lifecycle status. Run the suite as
`supabase_admin` against the same isolated local or dedicated test database.

The M9R5 scoring migration is
`migrations/20261101060000_javaneh_authoritative_scoring.sql`; its rollback-only
suite is `tests/gamification_scoring.sql`. It extends the existing ledger and
award RPC, uses the single exact-numeric floor formula, verifies M9R4
eligibility, records immutable competition/catalog/validation references, and
enforces award uniqueness and configured score caps. Corrections remain
attributable compensating entries; award retries return the original entry.
No scoring configuration or competition is activated by this migration.

For an actual multi-session test, use a fresh disposable database: run
`tests/gamification_scoring_concurrency.sql` as `supabase_admin` to commit a
test request, run `tests/gamification_scoring_concurrent.pgbench` with two
clients and the request UUID it prints, verify exactly one award exists for
that request, then drop the disposable database. This concurrency fixture is
committed for independent workers and must not run against a persistent or
shared database.

The M9R6 evaluator guide migration is
`migrations/20261101070000_javaneh_evaluator_guidance_v1.sql`. It enriches
the existing 28 Version 1.0 catalog records with product-owner-approved
focus, Level 4 indicators, illustrative evidence, applicable fairness
cautions, and shared evaluator instructions. The shared five-level
interpretations are stored once in `scoring_evaluation_levels`; unsupported
criterion-specific level 0–3 descriptions are not created. M9R7 selects
Qualitative validation for all five Stage 4 milestones, yielding 26
Qualitative and 2 Hybrid milestones and a complete configuration readiness
result. Product-owner decisions are not recorded as authenticated
configuration approval or activation.

Run `tests/gamification_evaluator_guidance.sql` as `supabase_admin` against
the same isolated database. It rolls back its temporary tests. Authorized
Validators read the guidance through the restricted
`get_milestone_evaluation_guide` RPC; client roles receive no direct catalog
writes. The canonical guide is
`../docs/gamification/M9R6_EVALUATOR_GUIDANCE_V1.md`. M9R7's migration is
`migrations/20261101080000_javaneh_stage4_qualitative_decision.sql`, with
rollback-only suite `tests/gamification_stage4_qualitative_decision.sql`.
The decision is recorded in
`../docs/gamification/M9R7_STAGE4_QUALITATIVE_DECISION.md`. Neither the
scoring configuration nor competition is activated.

The M9R8 idea workflow migration is
`migrations/20261101090000_javaneh_durable_idea_workflow.sql`. It extends the
existing `ideas`/`idea_stages` model with durable wizard-step state and
server-validated final submission. Draft payload writes, owner isolation,
three-idea quota enforcement, creation retries, and permanent deletion reuse
the existing restricted-executor RPCs. Deletion remains unavailable for
submitted ideas and is blocked when immutable validation or award history
exists. No `idea_sessions` table or separate content store is introduced.

Run `tests/idea_workflow.sql` as `supabase_admin` against the isolated database;
it rolls back all fixtures. To exercise concurrent quota requests, use only a
fresh disposable database: run
`tests/idea_workflow_quota_concurrency_setup.sql`, then
`pgbench -n -c 2 -t 1 -f tests/idea_workflow_quota_concurrent.pgbench`, verify
that there are three ideas and one each of `created` and `quota_exceeded`
results, then drop the disposable database. Do not run that committed fixture
against a persistent or shared database.

M9R9 adds the generated stable stage keys and ordered confirmation progression
in `migrations/20261101100000_javaneh_canonical_seven_stage_progression.sql`.
The existing seven `idea_stages` rows remain authoritative for progress;
`ideas.current_step` stores the participant's navigation position and advances
atomically with a successful confirmation. The participant tracker and
canonical labels/outcomes use `src/lib/ideas/stages.ts`. Stage 7 stays locked
and empty for participants; final submission moves the persisted position to
that human-review stage without implementing a judging workflow.

Run `tests/stage_progression.sql` as `supabase_admin` against the isolated
database. The rollback-only suite covers canonical stage ordering, explicit
confirmation and gating, persistence, ownership, idempotency, Stage 7
restriction, and submission state. The M9R9 behavior and field mapping are
documented in `../docs/architecture/M9R9-seven-stage-progression.md`.
For an actual confirmation race, use only a disposable database: run
`tests/stage_progression_concurrency_setup.sql`, pass its printed idea UUID to
`pgbench -n -c 2 -t 1 -D idea_id=<uuid> -f tests/stage_progression_concurrent.pgbench`,
verify Stage 1 is confirmed, Stage 2 is in progress, and `current_step` is 2,
then remove the test user, idea, and deletion-audit fixture or drop the database.

M9R10 adds resilient participant draft autosave and the fixed 168-hour
completed-dossier editing window. Its additive migration is
`migrations/20261101110000_javaneh_dossier_resilience.sql`; the rollback-only
suite is `tests/dossier_resilience.sql`. Run it and the updated
`tests/core_database.sql` as `supabase_admin` against an isolated database
after applying all preceding migrations. Submitted-dossier revision snapshots
are separate from confirmed-stage snapshots and are deleted with a legitimately
deleted idea. The new history tables are inaccessible to client roles.

For a real two-session edit race, use only a disposable database: run
`tests/dossier_edit_concurrency_setup.sql`, pass its printed idea ID and
revision to `pgbench -n -c 2 -t 1 -D user_id=<fixture-user-uuid>
-D idea_id=<printed-idea-uuid> -D expected_revision=<printed-revision>
-f tests/dossier_edit_concurrent.pgbench`; verify the outcomes table has one
`applied` and one `stale_revision` result, and the idea has exactly one
snapshot. The setup creates `m9r10_dossier_concurrency_outcomes`; drop the
disposable database afterward rather than retaining the fixture or its
deletion-audit row.

No post-deadline reopening RPC is available. Existing platform-owner and
scoring-administrator roles are scoped to scoring operations and do not provide
a dossier-reopening permission or audit policy. See
`../docs/architecture/M9R10-data-resilience.md` for the authorization
dependency and lifecycle details.

M9R11 serverless-safe mentor controls are added by
`migrations/20261101120000_javaneh_ai_mentor_request_controls.sql`. It adds a
content-free table keyed by participant and request UUID, protected by forced
RLS and accessible only to the restricted executor. The authenticated reserve
RPC derives the participant from `javaneh_private.current_uid()`, serializes
admissions with a per-user transaction advisory lock, enforces five requests in
a rolling minute, and rejects duplicate IDs in `processing`, `completed`, or
`failed` state. The finish RPC marks provider outcomes without storing AI text.
An indexed cleanup opportunistically removes records older than 24 hours under
a separate advisory lock; request-ID deduplication is guaranteed for that
retention window.

Run `tests/ai_mentor_request_controls.sql` as `supabase_admin` against an
isolated local/test database after applying the migration; it rolls back all
fixtures. To verify actual multi-session behavior, use only a fresh disposable
database: run `tests/ai_mentor_request_controls_concurrency_setup.sql`, then
run both `tests/ai_mentor_request_controls_same_id.pgbench` and
`tests/ai_mentor_request_controls_distinct_ids.pgbench` with eight concurrent
clients and one transaction each. The same-ID run must produce one `admitted`
and seven `duplicate`/`processing` outcomes. The distinct-ID run must produce
five `admitted` and three `rate_limited` outcomes. Verify the contents of
`m9r11_mentor_request_outcomes`, then run
`tests/ai_mentor_request_controls_concurrency_cleanup.sql` or drop the disposable
database. Do not retain or run the committed concurrency fixtures against a
persistent or shared database.

Phase 6 provider availability is implemented by
`migrations/20261101130000_javaneh_ai_mentor_circuit_breaker.sql`. Circuit state
is keyed by provider/model, forced-RLS protected, and writable only through
security-definer RPCs executable by `service_role`; the application uses the
server-only `SUPABASE_SERVICE_ROLE_KEY` for these operations. Never expose this
key to browser code or use it for participant idea operations. The existing
authenticated request quota/idempotency RPCs remain user-scoped.

Three transient failures (timeouts, network failures, provider 5xx, or 429)
within five minutes open the circuit for 60 seconds. After cooldown the
database admits exactly one half-open probe. Probes contain only a static
two-output-token request, have a 15-second timeout and no retry; successful probes
close the circuit, and failed transient probes reopen it with bounded
120/240/300-second backoff. Stale probe leases expire after 30 seconds. Circuit
state is content-free; operational state transitions/results are retained for
90 days. `GET /api/mentor` only reads configuration and circuit state; it does
not make a paid provider call. Recovery is attempted only when a participant
explicitly requests AI assistance after the cooldown.

Run `tests/ai_mentor_circuit_breaker.sql` as `supabase_admin` against an
isolated test database after applying the migration; it rolls back all state.
For actual cross-session half-open exclusion, use only a fresh disposable
database: run `tests/ai_mentor_circuit_breaker_concurrency_setup.sql`, then
`pgbench -n -c 8 -t 1 -f tests/ai_mentor_circuit_breaker_concurrent.pgbench`.
Exactly one row in `m9r12_mentor_circuit_probe_outcomes` must have outcome
`probe`; all others must be blocked in `half_open`. Run
`tests/ai_mentor_circuit_breaker_concurrency_cleanup.sql` or drop that
disposable database. Do not run these committed concurrency fixtures against a
persistent or shared database.
