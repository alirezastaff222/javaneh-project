# Phase 8 — Human Evaluation Feedback Publication

## Scope

This document covers Package 7B: human feedback drafting, independent
publication, and participant-visible published feedback. It intentionally does
not reintroduce or alter the earlier 700-point development scoring system,
phase-7 evaluation scoring, or any competition ranking logic.

## Lifecycle

Feedback operations are only valid once a submitted idea has a completed
human evaluation cycle. The lifecycle gate remains:

- `idea_evaluation_cycles.status = 'completed'`
- `idea_evaluation_cycles.completed_at IS NOT NULL`

The existing lifecycle migration is still authoritative for state transitions;
Package 7B only authorizes feedback actions once that lifecycle reaches a
completed state.

## Evaluator responsibilities

The assigned evaluator is the only actor who may create or update private
feedback drafts for an idea within the current cycle. The evaluator must hold
`human_evaluator` permission and must match the assigned evaluator for the
current `idea_evaluation_cycles` row.

Drafts are private and remain hidden from participants. An evaluator may
create an initial draft or a correction draft that references the latest
published version for the same cycle. Ordinary updates to published versions
are rejected in the database by immutable guard triggers.

## Publisher responsibilities

The publisher is a different, separately authorized actor. They must hold the
user-scoped `feedback_publisher` permission, and they must not be the same
as the assigned evaluator for the draft being published.

Publication is intentionally a distinct action from drafting. A publisher may
review eligible drafts, validate the cycle state, and publish the selected
draft as a new immutable feedback version. Drafts already consumed by a
previous publication cannot be published again.

## Permission model

The existing narrow permission table remains the authorization model:

- `public.idea_evaluation_permissions(user_id, permission, granted_by, granted_at, reason)`
- Valid permission values include `assignment_manager`, `human_evaluator`, and
  `feedback_publisher`

The new permission value is not inferred from existing roles such as
`platform_owner`, `scoring_administrator`, `validator`, or
`assignment_manager`. The migration preserves the executor-only access model
and does not add a public role-management RPC or UI.

Privileged database operators must grant or revoke `feedback_publisher` with
SQL directly in the database; examples are documentation-only and must not be
executed in the application.

```sql
-- Example: grant feedback publication authority to a specific authenticated user
INSERT INTO public.idea_evaluation_permissions (
  user_id,
  permission,
  granted_by,
  reason
)
VALUES (
  '00000000-0000-0000-0000-000000000123',
  'feedback_publisher',
  '00000000-0000-0000-0000-000000000001',
  'Operator-managed feedback publication authority.'
)
ON CONFLICT (user_id, permission) DO NOTHING;

-- Example: revoke feedback publication authority
DELETE FROM public.idea_evaluation_permissions
WHERE user_id = '00000000-0000-0000-0000-000000000123'
  AND permission = 'feedback_publisher';
```

## Database objects

The additive migration creates:

- `public.idea_feedback_drafts`: private evaluator-authored drafts
- `public.idea_feedback_versions`: immutable published history
- `public.guard_idea_feedback_draft_update()` and
  `public.guard_idea_feedback_version_update()`: database-level immutability
  guards
- RPCs for evaluator, publisher, and participant reads

The draft table enforces a single active draft per completed evaluation cycle.
The published table enforces unique version numbers per cycle and rejects
ordinary updates or deletes.

## RPCs and security boundaries

The relevant RPCs are owned by `javaneh_identity_executor` and use a fixed
`search_path = pg_catalog` with `SECURITY DEFINER`. Direct table access by
`PUBLIC`, `anon`, `authenticated`, and `service_role` is revoked. Only the
executor and the narrowly scoped RPCs are allowed to read or modify internal
feedback tables.

Evaluator-side RPCs include:

- `create_idea_feedback_draft(p_idea_id, p_feedback_content)`
- `get_own_idea_feedback_draft(p_idea_id)`
- `update_idea_feedback_draft(p_draft_id, p_feedback_content)`
- `create_correction_idea_feedback_draft(p_idea_id, p_feedback_content)`

Publisher-side RPCs include:

- `get_eligible_feedback_drafts_for_publication()`
- `get_eligible_feedback_draft_for_publication(p_draft_id)`
- `publish_idea_feedback_draft(p_draft_id)`

Participant-side RPCs include:

- `get_own_idea_published_feedback(p_idea_id)`

The participant function returns only the safe public projection and never the
publisher or evaluator identity, internal notes, or draft data.

## Publication transaction

Publication is executed atomically within the database transaction. It:

1. Validates the publisher identity and permission.
2. Locks the relevant draft and cycle rows.
3. Confirms the draft is still active and eligible.
4. Checks that the draft still references the latest published version.
5. Allocates the next version number.
6. Inserts the immutable version row.
7. Marks the draft as consumed.
8. Returns only a safe success payload.

This prevents stale corrections, duplicate version numbers, and concurrent
publication races from creating inconsistent published history.

## Immutability and corrections

Published feedback is append-only. Each correction creates a new draft tied to
`previous_published_version_id`. When published, the new version references the
previous version and gets the next sequential version number for the cycle.

Older versions remain immutable and unchanged. Participant read endpoints only
return the current published version for the idea. There is no arbitrary
restore or overwrite path through ordinary update operations.

## Participant visibility

Participants may read only feedback that has been successfully published and
only for ideas they own. Any unpublished draft, evaluator identity, publisher
identity, approval metadata, or internal notes remain hidden. Server-side
authorization is enforced at the database layer and the participant workspace
must not trust UI-only filtering.

## Operational precautions

- Keep `feedback_publisher` as a narrowly granted permission assigned by a
  trusted database operator.
- Never infer publisher authority from scoring or assignment roles.
- Never allow direct client access to the internal feedback tables.
- Never expose private evaluation notes through participant-safe RPCs.
- Do not treat the draft or publication tables as user-editable surfaces.
- Preserve the existing audit/event patterns for lifecycle operations.
