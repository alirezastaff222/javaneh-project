# M9R9 — Seven-Stage Idea Progression

## Canonical stages and existing field mapping

The participant journey has six development stages followed by a human-only
review stage. Stable keys are stored as generated values on `idea_stages`;
participant-facing labels and intended outcomes are defined once in
`src/lib/ideas/stages.ts`.

| # | Key | Existing wizard content |
|---|---|---|
| 1 | `define_problem` | The existing stage 1 `data.content` text response |
| 2 | `identify_social_capacities` | The existing stage 2 `data.content` text response |
| 3 | `develop_ideas` | The existing stage 3 `data.content` text response |
| 4 | `implementation_plan` | The existing stage 4 `data.content` text response |
| 5 | `feasibility_resilience` | The existing stage 5 `data.content` text response |
| 6 | `idea_dossier` | The existing stage 6 `data.content` text response |
| 7 | `human_review` | No participant content; remains locked and empty |

The current wizard has one generic text field per stage, not separate structured
fields for people, resources, activities, risks, or dossier sections. M9R9
preserves that field and its existing semantics. Stage 7 is reserved for
authorized human evaluation after final submission; no assignment, judging, or
selection workflow is included. The six thematic axes remain undefined.

## Persistence, confirmation, and access

Migration
`supabase/migrations/20261101100000_javaneh_canonical_seven_stage_progression.sql`
adds a generated `stage_key`, so participants cannot submit or alter stage
identifiers. The existing seven `idea_stages` rows and status values remain the
progress source. `ideas.current_step` remains the persisted navigation
position; stage statuses remain the authoritative completion state.

Authenticated, owner-scoped confirmation RPCs serialize on the idea row. They
reject locked and submitted stage requests. A successful
confirmation records its timestamp, unlocks only the next participant stage,
and advances the persisted position in the same transaction when the confirmed
stage was the participant's current position. Repeated requests/confirmations
are idempotent. A failed confirmation does not unlock a stage. Existing content
save, RLS, and restricted-executor authorization paths are retained. Editing
an earlier confirmed stage continues to reopen that stage while preserving
already-unlocked later stages, matching the existing editing behavior and
immutable confirmed-stage snapshots.

After the existing submission succeeds, the same database transaction moves
`current_step` to 7. The stage 7 row itself remains locked and empty. The
participant tracker displays it as awaiting human review based on the
server-confirmed submitted lifecycle state. Ordinary participant stage
operations do not edit submitted content.

## Revision policy and scope boundary

Ordinary drafts continue to use the existing latest-content-in-place behavior
and revision counter. Existing immutable snapshots of previously confirmed
stage content are retained; M9R9 adds no draft-history subsystem.

The current lifecycle has no authorized post-submission dossier editing
workflow or completed-dossier snapshot model. Therefore the proposed 168-hour
editing window is not enabled by M9R9; submitted ideas remain immutable through
ordinary participant operations. A later separately authorized versioning
package must define the editing authorization, atomic snapshot behavior, and
post-window reopening process before such edits are supported.

Stage confirmation is separate from milestone validation and scoring. M9R9
does not add scoring, award, activation, human-review, or eligibility behavior.

## Verification

The rollback-only `supabase/tests/stage_progression.sql` suite checks stable
stage identifiers and ordering, initial and persisted state, locked-stage
rejection, explicit confirmation, no unlock on failed confirmation,
idempotency, ownership, revisiting confirmed stages, the ordinary draft
revision policy, Stage 7 restriction, and submitted-content immutability.
The committed `stage_progression_concurrency_setup.sql` and
`stage_progression_concurrent.pgbench` are for a disposable database only; two
clients may race to confirm the same pending stage, after which the final
confirmed/unlocked state can be checked and all fixtures removed.
