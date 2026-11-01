# M9R8 Idea Workflow — Baseline and Plan

## Baseline before M9R8

- Branch: `main`. The worktree already contained tracked edits to
  `src/app/ideas/ideas-wizard.tsx` and `supabase/README.md`, plus untracked
  M9R1–M9R7 migrations, tests, and documentation. These were retained.
- The wizard creates an `ideas` row through `create_idea`, loads owner-visible
  ideas and `idea_stages` through forced-RLS reads, saves stage JSON through
  `save_idea_content`, and confirms stages through the existing RPCs.
- A new idea has seven `idea_stages`: Stage 1 is active and Stages 2–7 start
  locked. The wizard's only editable field is a text `content` property inside
  a stage's JSON `data`; M9R4 validation may also inspect other JSON keys.
- The database has no `idea_sessions` table. Durable draft data is already
  represented by `ideas` plus `idea_stages`; save idempotency is recorded in
  `idea_save_requests`. Current step was only in the URL/component state, and
  unsaved textarea changes were not durable. The UI had no final-submit or
  delete action.
- `create_idea` already derives the owner from the authenticated JWT, serializes
  requests with a per-owner advisory transaction lock, enforces three
  non-deleted ideas, and uses an owner/request uniqueness key for retries.
  `delete_own_idea` already audits and permanently cascades deletion of stages,
  confirmed snapshots, and save-request rows; it rejects submitted ideas.
- `ideas` and `idea_stages` use forced RLS and expose owner-scoped reads only.
  Privileged writes use fixed-search-path security-definer RPCs owned by the
  restricted identity executor. No idea storage bucket or separate dossier
  table exists. M9R4 validation history and M9R5 ledger references are
  independent records and must not be erased by deletion.
- Baseline checks: `npm run lint`, `npm run typecheck`, and
  `supabase/tests/core_database.sql` passed. The previously completed M9R1–M9R7
  suites and `npm run build` were also passing before this package.

## M9R8 implementation plan

Reuse `ideas` and `idea_stages` as the durable wizard/session model; do not
create a parallel `idea_sessions` table. Add a persisted current-step field
and an authenticated step RPC, plus a transaction-safe, idempotent final
submission RPC. Keep the existing advisory-lock quota and creation retry
behavior. Add an explicit confirmation-backed delete control, and guard
deletion against submitted, validation-history, or award-linked ideas so
immutable evaluation and scoring history cannot be orphaned. Add rollback-only
SQL tests and a disposable two-client quota-boundary test; update the wizard
and database documentation without changing authentication or the seven
existing stage rows.

## Verified implementation

The additive migration
`supabase/migrations/20261101090000_javaneh_durable_idea_workflow.sql` adds
`ideas.current_step`, a server-side text check for the wizard's `content`
field, owner-checked step persistence, and one atomic/idempotent submission
RPC. All six participant stages must already be confirmed; Stage 7 remains
locked. Failed submission leaves the saved idea and revision intact.

The existing quota counts all non-deleted ideas, including submitted ideas;
the existing per-owner transaction advisory lock serializes creates. The
wizard displays the database-backed count as `x of 3`. Permanent deletion
continues to cascade draft stages, confirmed snapshots, and save-request
records, while retaining the existing content-free audit. It is rejected for
submitted ideas and for any idea with validation or award history, which is
preserved by its existing immutable history architecture.

`supabase/tests/idea_workflow.sql` and the core/M9R1–M9R7 SQL suites pass.
The disposable two-client quota test produced exactly one `created`, one
`quota_exceeded`, and three total ideas. Lint, typecheck, production build,
and `git diff --check` pass. The persistent database contains no M9R8 test
users, ideas, deletion events, or other test records.
