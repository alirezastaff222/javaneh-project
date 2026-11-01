# Phase 8 — Human Evaluation Lifecycle Foundation

## Scope and boundaries

Each successfully submitted idea receives one initial Stage 7 evaluation
cycle, regardless of competition assignment. Stage 7 remains human-only and
participant-empty. Its lifecycle does not change `ideas.status`, competition
eligibility, scoring, ranking, or selection. `completed` means only that the
human evaluation process finished.

The cycle moves only through `awaiting_review`, `in_progress`, and `completed`.
Submission creates `awaiting_review`; a separately authorized assignment
manager assigns one evaluator without changing that state; the assigned
evaluator starts and completes the cycle. A reassignment is allowed only while
the cycle is awaiting review. Start and completion are idempotent and write
audit events in the same transaction as the state change.

## Stable dossier requirement

The evaluator may start only when database time is at or after
`ideas.submitted_at + INTERVAL '168 hours'`, the exact boundary enforced by
`edit_submitted_idea`. Start locks the idea row before reading the deadline and
revision. The edit RPC locks that same row, so a successful edit and evaluation
start serialize. Start stores the authoritative `ideas.revision` as
`evaluated_revision`; it does not duplicate dossier content. Completion
requires that revision to remain unchanged.

## Authorization and audit

The additive migration
`supabase/migrations/20261101230000_javaneh_human_evaluation_lifecycle.sql`
adds forced-RLS permission, cycle, and append-only event tables. Evaluation
permissions are separate from scoring `validator`, `scoring_administrator`,
and `platform_owner` roles. A privileged deployment/database operator
provisions the narrow `assignment_manager` and `human_evaluator` permissions;
there is no participant-facing role-management RPC. Assignment requires an
assignment manager and a separately permissioned evaluator. The evaluator
must remain assigned and authorized to start and complete.

`assign_idea_evaluator`, `start_idea_evaluation`,
`complete_idea_evaluation`, and `get_own_idea_evaluation_status` are
`SECURITY DEFINER` functions owned by the restricted identity executor with a
fixed `pg_catalog` search path. Participant access is through the last,
owner-scoped RPC only. Internal cycle/permission/event rows are not directly
available to client roles. Event rows cannot be updated or deleted by the
executor and are written atomically with successful operations.

Assigned evaluator UUIDs and event actor UUIDs intentionally are not foreign
keys to Auth users so evaluator account deletion does not prevent the existing
account-deletion cascade. If an assigned evaluator loses access or deletes
their account after starting, this package has no reassignment/recovery
transition; an active cycle may remain in progress. No recovery behavior is
authorized here.

## Participant projection

The participant workspace loads only the evaluation status and safe
start/completion timestamps for submitted ideas. It shows awaiting review,
in progress, or completed; completion is explicitly not represented as a
competition result. Evaluator identity, audit metadata, notes, feedback, and
jury scoring are excluded. The existing development scorecard remains
separate and unchanged.

## Deferred work

Feedback drafting/publication and participant feedback display belong to
Package 7B, which is documented in
`docs/architecture/phase8-human-evaluation-feedback-publication.md`.
Jury criteria, scores, ranking, selection, and final competition results
belong to Phase 10. Notifications are not part of this package.

The rollback-only test suite is
`supabase/tests/human_evaluation_lifecycle.sql`. Run it as `supabase_admin`
against an isolated database after applying the ordered migrations.
