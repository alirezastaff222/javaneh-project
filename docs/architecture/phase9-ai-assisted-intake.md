# Phase 9 — AI-Assisted Idea Intake

## Product and canonical stage mapping

The participant-facing journey has eight product phases, but it does not add
new `idea_stages` rows or redefine existing stage keys:

| Product phase | Existing persistence and lifecycle |
|---|---|
| 1. Initial idea | Intake title and initial description become the opening of Stage 1 content. |
| 2. Problem analysis and initial registration | Problem, affected people, and optional observation are appended to Stage 1. The participant explicitly registers and confirms Stage 1. |
| 3. Social capacities | Canonical Stage 2, `identify_social_capacities`. |
| 4. Idea development | Canonical Stage 3, `develop_ideas`. |
| 5. Implementation planning | Canonical Stage 4, `implementation_plan`. |
| 6. Feasibility and resilience | Canonical Stage 5, `feasibility_resilience`. |
| 7. Dossier | Canonical Stage 6, `idea_dossier`, followed by the existing dossier preview. |
| 8. Classification and evaluation preparation | The existing official classification and dossier/submission controls. Human review remains canonical Stage 7 and is never participant-editable or AI-operated. |

The first two product phases are intentionally compact and together target
about five minutes. The form registers the idea only after the participant
reviews and submits the second phase. The primary action uses the existing
`create_idea`, `save_idea_content`, `request_idea_stage_confirmation`, and
`confirm_idea_stage` RPCs. These execute in sequence with stable request IDs,
and the browser persists the operation state in account-scoped `sessionStorage`
so retries recover the same idea rather than creating a duplicate. The created
idea remains an ordinary draft/in-progress idea; this action is not final
submission.

No database migration or parallel idea/session table is introduced. Existing
RLS, quota locking, revision checks, idempotency ledger, stage confirmation,
deletion audit, immutable history, group ownership, and final-submission rules
remain authoritative. Intake creates individual ideas only. Group ideas
continue through their existing group workspace and shared quota flow.

## Mentor interaction

After registration, the participant can continue the same idea in the existing
workspace, return later, or begin another idea. Continuing with the mentor
opens the idea at its persisted current stage. AI is never invoked merely by
loading the page: the participant explicitly clicks the stage-specific mentor
action or submits a question. The mentor can start with one contextual
question and an optional clearly hypothetical example.

Mentor requests continue through `POST /api/mentor`. The server validates the
authenticated owner, persisted current stage, request controls, rate limits,
provider circuit, input bounds, and structured response. Earlier confirmed
stage text is the only prior-stage context. Stage 7 remains forbidden. AI
suggestions and mentor exchanges are not stored as participant content; the
participant's stage text continues through the existing autosave and explicit
confirmation controls. Non-AI guidance remains available when the provider is
unconfigured or unavailable.

## Classification boundary

The official classifier currently dispatches once Stages 1 and 2 have both
been confirmed and uses those confirmed source revisions with the active
database taxonomy. The workspace's ClassificationPanel exposes the current,
pending, stale, and unavailable states. Phase 8 reuses this authoritative
result and the existing dossier/submission controls; it does not issue a
second classification request or write participant-supplied classification
data. The official classification is therefore based on its documented Stage
1/2 inputs, not a new whole-dossier model. Expanding official classification
to consume the full dossier would require a separately designed taxonomy,
revision, dispatch, and history change.

Final submission remains a distinct participant action after all six
participant stages are confirmed. It creates the existing human-evaluation
lifecycle; AI cannot submit, score, rank, approve, reject, or influence the
human-only Stage 7.

## Recovery and privacy

Before registration, the current tab retains only the form answers and
idempotency state needed to resume the intake. The server persists the text
only after the participant submits it. The intake no longer asks for unrelated
education, location, or contact details. Provider credentials and service-role
credentials remain server-only. Mentor input and output are not included in
application logs or persisted conversation history.

The existing three-idea quota applies to each individual account. If the quota
is full, the database rejects creation; the participant is directed to the
existing workspace to delete an eligible idea. Submitted ideas or ideas with
protected evaluation/scoring history remain undeletable under the existing
rules. Deletion success is never inferred by the intake UI.

## Verification

`src/lib/ideas/intake.test.ts` checks Stage 1 serialization, title extraction,
optional-section omission, create/save/confirm ordering, retry idempotency, and
quota rejection before stage writes. Existing workflow, mentor, classification,
and database test suites remain the source of truth for their respective
boundaries. Database-backed tests must run only against an isolated database
after applying migrations in order.