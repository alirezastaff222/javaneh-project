# M9R7 — Stage 4 Qualitative Validation Decision

## Decision and implementation

The approved product decision is to use Qualitative validation for all five
Stage 4 milestones. The additive migration
`20261101080000_javaneh_stage4_qualitative_decision.sql` updates only the
existing Version 1.0 Stage 4 `validation_mode` and `validation_policy`
records. It preserves milestone identities, catalog references, maxima,
guidance, and relationships.

The final development catalog contains 28 milestones: 26 Qualitative and 2
Hybrid (S6-M1 and S6-M5), with no pending or unsupported modes. The Stage 4
milestones use human qualitative evaluation and have no objective/structural
checks. Existing shared evaluator levels remain authoritative; no
criterion-specific levels 0–3 were invented. The retained Hybrid policies
continue to require objective checks as well as human review.

The product owner's rubric decision is not an operational scoring approval.
The database readiness function accepts the complete catalog and guide, but
the Version 1.0 scoring configuration and competition remain draft. No
approval or activation operation is called, and no operational approval event
is created. Awards remain unavailable until the existing separately governed
approval and activation flow is used.

## Readiness and scope

After the decision, `scoring_configuration_is_ready` reports the complete
configuration as ready: the former Stage 4 pending modes no longer block
readiness, and M9R6 evaluator guidance remains complete. This is a
configuration-completeness result only; it does not mean that scoring is
operational or that competition eligibility has been approved.

The migration does not change M9R4 validation eligibility or M9R5 award
guards. Qualitative Stage 4 scoring still requires the existing eligible
validation and, where applicable, approved human evaluation. A participant
stage confirmation, objective structure, or AI interaction does not award
points.

No persistent awards, validation requests, approval events, or activation
events are created by this package. The rollback-only M9R7 suite is
`supabase/tests/gamification_stage4_qualitative_decision.sql`; it verifies
mode counts, preserved allocations and guidance, readiness behavior, Hybrid
requirements, and draft lifecycle state.

## Next package

Proceed with a separately authorized operational approval and activation
readiness package only after the required governance decisions and approvals
are supplied. M9R7 itself does not authorize or perform those operations.
