BEGIN;

REVOKE SELECT ON TABLE public.idea_classification_state FROM authenticated;
GRANT SELECT (
  idea_id,
  status,
  source_stage_1_revision_id,
  source_stage_2_revision_id,
  current_classification_id,
  lease_expires_at,
  last_failure_category,
  attempt_count,
  retry_after
) ON TABLE public.idea_classification_state TO authenticated;

COMMIT;
