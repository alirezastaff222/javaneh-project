# M9R10 — Data Resilience and Completed-Dossier Versions

## Draft synchronization

The existing `ideas` and `idea_stages` rows, `save_idea_content` RPC, and
revision counter remain authoritative. The wizard debounces stage saves,
retains the unsynchronized stage text in user-and-idea-scoped browser storage,
and retries transient failures at most three times with increasing delays.
Retries use the same request UUID and payload. Local recovery is removed after
the server confirms synchronization and when the authenticated user changes.
The interface reports database-confirmed, pending, and failed states
separately.

On recovery, local content is restored only when it matches the server revision
or is identical to the server content. A revision mismatch remains a visible
conflict; the participant must choose the database version or explicitly
re-apply the local version against the latest revision. The existing draft
revision policy remains latest-state-only; M9R10 adds no full draft history.

## Submitted-dossier edit window

Migration
`supabase/migrations/20261101110000_javaneh_dossier_resilience.sql` adds the
database-controlled `ideas.submitted_at` value and the
`edit_submitted_idea` restricted-executor RPC. Existing submitted rows are
backfilled from their database `updated_at` timestamp, which was advanced by
the successful submission update in the preceding workflow.

The RPC compares server `clock_timestamp()` with
`submitted_at + INTERVAL '168 hours'`; the client does not supply a timestamp
or deadline. At or after that instant it rejects the edit. The timestamp is
not changed by edits or submission retries. Participant updates to submitted
content remain separate from the existing draft save and stage-confirmation
operations.

Each changed logical edit stores exactly one immutable pre-edit image of all
six participant stages at the current revision, then updates stage content
and increments `ideas.revision` in the same transaction. The per-request
fingerprint ledger makes retry outcomes idempotent and contains no dossier
content. A stale revision is rejected, a no-op creates no snapshot, and
failed edits roll back both the snapshot and content changes. Completed-dossier
snapshots are separate from `idea_stage_confirmed_versions`. Both version
tables cascade with permanent idea deletion; neither is directly accessible
to client roles.

## Reopening authorization

No post-deadline reopening endpoint is exposed. The existing
`platform_owner`, `scoring_administrator`, and `validator` assignments are
scoped to scoring configuration, validation, and award operations; the schema
does not define a dossier-reopening permission, reason/audit contract, or
authorized reopening workflow. Reusing those roles for dossier reopening
would silently expand their authority. A product-approved reopening
authorization and audit policy is the specific dependency required before a
future reopening workflow can be implemented.

## Verification

`supabase/tests/dossier_resilience.sql` is a rollback-only database suite for
timestamp ownership, in-window edits, revision snapshots, retry/no-op/stale
behavior, immutable history, expiration, restricted access, and cascade
deletion. `supabase/tests/core_database.sql` also checks the new protected
tables and deletion cascade. These suites must run as `supabase_admin` against
an isolated database after applying the ordered migrations.
