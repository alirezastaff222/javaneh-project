# Javaneh -- Gamification Foundation (M9R1)

**Status:** M9R1 foundation and M9R2 authorization/operations implemented
**Scope:** Versioned scoring configuration, milestone catalog, append-only score ledger, and derived user score views

## Implemented

- Scoring configurations can represent multiple rule sets. The original optional opaque competition UUID remains untouched for historical compatibility; M9R3 adds a separate validated competition relationship.
- Configuration versions begin as `draft`. The database permits only draft-to-approved, approved-to-active, and active-to-retired transitions. Approval actor/time and activation time are recorded.
- Milestone keys are stable within each configuration version. Milestone rows can be staged only while the version is draft. M9R3 seeds the approved Version 1.0 criteria into an inactive configuration.
- Active milestones require a non-empty definition and positive point value. A ledger award must match an active milestone in an active configuration version, including its configured stage and point value.
- Official entries are append-only and carry an idempotency UUID, user and idea identifiers, configuration version, milestone, optional stage, source, reason, actor, and timestamp. Corrections are separate entries that reference and match an original award.
- User-readable totals, stage breakdowns, milestone breakdowns, and history are derived from ledger entries. No rank or leaderboard is provided.
- User and idea identifiers in the ledger intentionally have no cascading foreign keys, so deleting an idea or account cannot rewrite score history. The ledger stores identifiers and audit metadata only, not idea content.

## M9R2 Roles and Permissions

Role assignments use Auth user UUIDs in `scoring_role_assignments`. Grant/revoke events, including bootstrap, are recorded in `scoring_role_audit`.

| Role | Authority |
|---|---|
| Platform Owner | Grants and revokes Scoring Administrators. Cannot be assigned through an application RPC. |
| Scoring Administrator | Grants and revokes Validators; approves, activates, and retires scoring configuration versions; creates compensating score corrections. |
| Validator | Reads the active milestone review queue, records one human approval or rejection per idea/configuration/milestone, and issues the award for their own approved decision. |
| Participant | Uses the existing idea workflow and can read only their own ledger history and derived scores. |

Role-management and privileged operations execute as the existing restricted `javaneh_identity_executor`, with a fixed `pg_catalog` search path and actor identity taken from `javaneh_private.current_uid()`. Clients do not receive direct writes to role, validation, configuration-event, or ledger tables. Role changes and operations serialize on the actor's authorization lock, so a committed revocation blocks subsequent calls. A Validator cannot review their own idea; only the approving Validator can issue its award. A Scoring Administrator cannot correct an award they received or recorded.

## Initial Platform Owner Bootstrap

There is deliberately no first-user-wins logic, public bootstrap RPC, or UUID in a migration. After applying the migrations in an isolated/deployment database, an authorized database operator must independently verify the intended account and connect directly as `supabase_admin` (not with `SET ROLE`). The connection must be superuser or `BYPASSRLS` and have the privileges to read `auth.users` and insert into both role tables. Run the following in one transaction, replacing both placeholders with reviewed values:

```sql
BEGIN;

DO $bootstrap$
DECLARE
  v_target_user_id uuid := 'REPLACE_WITH_VERIFIED_AUTH_USER_UUID';
  v_reason text := 'Initial Platform Owner bootstrap; change-control reference REPLACE_ME';
BEGIN
  IF session_user <> 'supabase_admin' OR current_user <> 'supabase_admin' THEN
    RAISE EXCEPTION 'Connect directly as supabase_admin';
  END IF;
  IF NOT EXISTS (
    SELECT 1
      FROM pg_catalog.pg_roles AS r
      WHERE r.rolname = session_user
        AND (r.rolsuper OR r.rolbypassrls)
  ) THEN
    RAISE EXCEPTION 'Bootstrap requires superuser or BYPASSRLS';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM auth.users AS u WHERE u.id = v_target_user_id
  ) THEN
    RAISE EXCEPTION 'Verified target is not an Auth user';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM public.scoring_role_assignments AS a
      WHERE a.role_name = 'platform_owner'
  ) THEN
    RAISE EXCEPTION 'A Platform Owner is already assigned';
  END IF;
  IF v_reason IS NULL OR pg_catalog.length(pg_catalog.btrim(v_reason)) = 0 THEN
    RAISE EXCEPTION 'A bootstrap reason is required';
  END IF;

  INSERT INTO public.scoring_role_assignments (
    user_id, role_name, assigned_by
  )
  VALUES (v_target_user_id, 'platform_owner', NULL);
  INSERT INTO public.scoring_role_audit (
    event_type, role_name, actor_user_id, target_user_id, reason
  )
  VALUES ('bootstrap_owner', 'platform_owner', NULL, v_target_user_id, v_reason);
END
$bootstrap$;

COMMIT;
```

The null actor in this single bootstrap event means “privileged database bootstrap”; the operator and approval/change-control reference belong in the required reason. Do not execute if the database cannot provide the required direct privileged connection or grants; do not substitute a public RPC or first-user assignment. Subsequent Platform Owner changes are also operational database actions; the public role-management RPC intentionally cannot assign or revoke Platform Owners.

## Milestone Validation and Award

`get_milestone_review_queue()` returns idea-stage content from the existing participant workflow alongside the active milestone definition and idea revision. For milestones without a configured stage, the queue returns the idea's available stages. It does not infer a submission state, milestone criterion, or eligibility rule that M9R1 does not define. Validators record an explicit reason and one immutable decision for the idea/configuration/milestone. A conflicting or repeated decision returns the existing decision; a rejected decision cannot be awarded. Validation records the reviewed idea revision.

`award_validated_milestone(validation_id)` derives the recipient from the locked idea ownership row and the point value/stage from the active catalog. It requires the current Validator role and the same Validator who approved the decision. It does not accept a client user ID or point value. The award, its validation reference, and its ledger row are written in one transaction. Per-milestone unique indexes, the locked validation/idea/configuration rows, and a transaction advisory lock protect retries and competing requests.

`correct_score_award(original_entry_id, reason)` is a separate Scoring Administrator operation. It inserts one compensating ledger row for the exact inverse of an original award, references that award, and records the actor and reason. Empty reasons, self-corrections, non-awards, and duplicate corrections are rejected. Ledger rows remain append-only; totals continue to derive from all entries.

Configuration lifecycle RPCs require a current Scoring Administrator for draft approval, activation, and retirement. Each action records actor, timestamp, and reason in `scoring_configuration_events`. M9R3 adds a validated competition model and separate Scoring Administrator competition lifecycle operation.

The migration does not alter identity bridging, existing RLS policies, the seven-stage lifecycle, confirmation RPCs, or participant UI. It does not award points for AI text, messages, clicks, time, or activity volume.

## M9R3 Version 1.0 Catalog

The additive migration `20261101040000_javaneh_gamification_catalog.sql` reuses
the configuration-version, milestone catalog, role, lifecycle, validation,
and ledger tables. It adds the `scoring_stage_catalog`,
`scoring_evaluation_levels`, and `competitions` tables, plus an append-only
competition event history. The historical `scoring_configurations.competition_id`
remains opaque and has no new foreign key; competitions instead reference a
specific configuration version using a validated foreign key.

The migration seeds the approved stage maxima (80, 100, 140, 140, 120, 120,
and 300), the 700 development / 300 jury / 1000 total allocation, all five
evaluation multipliers, and the 28 explicitly enumerated development
milestones. The policy's regression text says 29 milestones, but its stage
lists contain 28; the request clarified that the 28 enumerated definitions
are authoritative, so no additional criterion was invented. Stage 7 is a
separate human-jury maximum and has no participant milestone.

Criterion maxima are stored in the existing `point_value` column. A selected
qualitative level is multiplied by that maximum and rounded down to a whole
point (`floor`) before award; awards and stage totals are constrained to their
configured maxima. The new `validate_milestone_with_level` operation records
the selected level, while legacy M9R2 milestones continue using their existing
full-value validation path.

All seeded criteria have approved names, descriptions, maxima, and validation
mode. M9R6 completed the evaluator focus, Level 4 indicators, evidence
guidance, and evaluator instructions in the existing catalog. The existing
Scoring Administrator configuration approval and activation operations are
reused. M9R7 records the approved Qualitative product decision for Stage 4;
the Version 1.0 configuration and competition remain draft. The
separate competition lifecycle RPC requires an active, complete configuration.
Only the restricted executor can write authoritative catalog, stage, scale,
competition, validation, and score data; RLS remains enabled and forced.

No dates, cohort eligibility, registration limits, leaderboard settings, or
final-jury scoring operations are configured. M9R2 still does not determine
whether stage confirmation is required for a criterion or define appeals,
tie-breaking, and reviewer assignment.

## Product Decisions Still Required

- Detailed, approved level descriptors, evidence guidance, and evaluator instructions for every qualitative criterion.
- Which milestones are eligible for validation, whether stage submission/confirmation is required, and the intended evidence/eligibility criteria. M9R2 records explicit human decisions but does not invent these rules.
- Competition dates, cohort, eligibility, and public/private leaderboard visibility.
- Tie-breaking, appeals, dispute handling, reviewer assignment/permissions, and development-versus-jury weighting.
- Account-deletion retention/privacy policy for retained UUID-based score history.

The approved 700 development / 300 jury allocation is encoded. Human Validators retain final review responsibility; no AI approval, jury score entry workflow, or Stage 7 participant workflow is implemented. A milestone currently allows one immutable decision; appeals/re-review need an approved product policy before adding another workflow.

## Validation

`supabase/tests/gamification_foundation.sql` remains the rollback-only M9R1 regression suite. `supabase/tests/gamification_operations.sql` covers the M9R2 role hierarchy, authorization, configuration lifecycle, human decisions, award derivation/idempotency, correction behavior, audit, and ownership checks. Both must run against the same isolated local Supabase database as `core_database.sql`. The award and correction tests exercise repeated calls and database uniqueness guards sequentially; they are not multi-session concurrency tests.

The M9R3 rollback-only suite is `supabase/tests/gamification_catalog.sql`. It
checks the exact point allocations, 28 enumerated milestones, inactive
defaults, rounding, authorization, descriptor readiness gates, forced RLS,
and the opaque legacy competition identifier.

## M9R4 Milestone Validation

The additive migration
`20261101053000_javaneh_milestone_validation.sql` adds revision-linked
submission requests and append-only validation events. It extends milestone
validation modes to `qualitative`, `objective`, and `hybrid`, while preserving
legacy M9R2 validation rows and keeping stage confirmation as a separate
workflow.

Participants submit the current saved idea revision through
`submit_milestone_for_validation`. Qualitative requests enter the Validator
queue; objective requests are evaluated on the server using configured JSON
path checks (`present` or `equals`); hybrid requests reach human review only
when their objective checks pass. Failed checks require a later saved idea
revision and a new request. Validators use `get_milestone_validation_queue`
and `validate_milestone_request`; duplicate submissions for the same
revision are idempotent, and earlier attempts and decisions remain in history.
`get_milestone_scoring_eligibility` reports whether a completed request meets
the configured gates; it does not create ledger entries or activate scoring.

Validation requests and event history use forced RLS. Participants can read
their own requests, while authoritative writes and objective evaluation run
through restricted database functions. Validator decisions are restricted to
authorized Validators who are not reviewing their own ideas. The existing
stage confirmation RPCs are unchanged. The migration does not activate the
Version 1.0 scoring configuration or competition, and no M9R4 workflow issues
official awards.

The rollback-only M9R4 regression suite is
`supabase/tests/gamification_validation.sql`. It covers objective, human, and
hybrid flows; revision retries; authorization and isolation; the distinction
from stage confirmation; eligibility reporting; and absence of ledger writes.

## M9R5 Authoritative Scoring

The additive migration
`20261101060000_javaneh_authoritative_scoring.sql` extends the existing ledger
and award operation; it does not create a second ledger or participant
gamification surface. `award_validated_milestone` accepts a legacy validation
ID for compatible pre-catalog awards or an M9R4 validation request ID for
Version 1.0-style awards. Catalog awards require an active approved
configuration, its active competition, approved validation guidance, and a
positive M9R4 eligibility result. Objective awards are derived from successful
server-side checks; qualitative and hybrid awards use the immutable Validator
decision and its evaluation level. Objective requests can only be awarded by
their participant, and human-reviewed requests only by the deciding Validator.

The existing calculation helper is the single formula path:
`floor(configured milestone maximum * configured numeric multiplier)`.
PostgreSQL `numeric` arithmetic preserves exact multipliers; there is no
floating-point calculation or new rounding policy. Objective checks that pass
receive the configured milestone maximum; human decisions must include a
validated level. The ledger guard independently verifies request, decision,
catalog, competition, points, and current idea-revision references before
insertion. Stage, development, overall, and individual criterion caps are
enforced while the per-idea score-budget advisory lock is held. Stage 7 remains
outside the development award operation.

Awards retain their competition, catalog version, validation request,
evaluation level, configuration, milestone, actor, and timestamp references.
The existing one-award-per-idea/configuration/milestone uniqueness constraint
and a per-request unique index complement transaction advisory locks; retries
return the original ledger entry. Historical opaque competition identifiers
are unchanged. Ledger rows remain append-only, and the existing Scoring
Administrator correction operation writes one attributable, exact compensating
entry without deleting the original or automatically reversing awards after
idea edits or revalidation.

The rollback-only M9R5 suite is `supabase/tests/gamification_scoring.sql`.
It covers the Version 1.0 scale and floor results, objective/human/hybrid
awards, validation eligibility, references, duplicate retries, correction and
immutability, stage confirmation separation, draft configuration denial, and
private ledger access. A real independent-session race is set up by
`supabase/tests/gamification_scoring_concurrency.sql`; that fixture commits
rows for two workers and therefore must run only in a fresh disposable
database, which must be dropped afterward. Run the two-worker
`supabase/tests/gamification_scoring_concurrent.pgbench` script against its
request ID and verify exactly one ledger award. The production Version 1.0
configuration and competition remain draft pending separate operational
approval and activation.

## M9R6 Approved Evaluator Guidance

The additive migration
`20261101070000_javaneh_evaluator_guidance_v1.sql` fills the existing Version
1.0 catalog with the product-owner-approved criteria. It reuses the 28 stable
milestone keys, stage and competition allocations, shared numeric evaluation
levels, descriptor status, and catalog version; it does not add a parallel
rubric or approval workflow.

The existing catalog stores criterion focus in `evaluator_description`,
Level 4 indicators in `level_4_indicators`, illustrative examples in
`evidence_guidance`, specified fairness restrictions in
`evaluation_cautions`, and shared evaluator rules in
`evaluator_instructions`. The shared five-level interpretation is stored once
per scoring version in `scoring_evaluation_levels.general_description`.
Milestone-specific level 0–3 descriptors remain null; none were invented.
`catalog_version = '1.0'` remains the stable guide reference on validation
requests and awards.

Stages 1–5 use Qualitative validation. Stage 6 uses Hybrid for S6-M1 and
S6-M5 and Qualitative for S6-M2 through S6-M4. The Hybrid structural check
only verifies that Stage 6 data is present; the human Validator still decides
the qualitative level. M9R7 records Qualitative mode for all five Stage 4
milestones, resulting in 26 Qualitative and 2 Hybrid milestones with no
pending modes. Stage 4 has no structural point-awarding requirements.

`get_milestone_evaluation_guide` is a read-only Validator-authorized RPC that
returns the approved guidance and shared scale without granting client roles
direct catalog reads. The M9R5 award path recognizes the guide's focus,
Level 4 indicators, evidence guidance, evaluator instructions, and shared
scale while continuing to require active competition/configuration, eligible
validation, and existing ledger constraints. Guidance insertion does not
award points or approve/activate configuration.

The product-owner approval is expressed as approved content status only; it
does not fabricate an authenticated approver, timestamp, or operational
configuration event. Scoring Administrator approval remains a separate
existing RPC. The catalog guard continues to make approved configuration
contents immutable outside a draft. The M9R6 suite is
`supabase/tests/gamification_evaluator_guidance.sql`, and M9R7 is tested by
`supabase/tests/gamification_stage4_qualitative_decision.sql`. The canonical
guide is `docs/gamification/M9R6_EVALUATOR_GUIDANCE_V1.md`; the decision is
recorded in `docs/gamification/M9R7_STAGE4_QUALITATIVE_DECISION.md`. The
Version 1.0 configuration and competition remain draft and are not activated.