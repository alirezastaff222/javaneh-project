BEGIN;

DO $feedback_draft_constraint_check$
DECLARE
  v_table_oid oid := pg_catalog.to_regclass('public.idea_feedback_drafts');
  v_cycle_attnum smallint;
  v_constraint_count integer;
  v_constraint record;
BEGIN
  IF v_table_oid IS NULL THEN
    RAISE EXCEPTION
      'Expected public.idea_feedback_drafts table is missing';
  END IF;

  SELECT attribute.attnum
    INTO v_cycle_attnum
    FROM pg_catalog.pg_attribute AS attribute
    WHERE attribute.attrelid = v_table_oid
      AND attribute.attname = 'cycle_id'
      AND NOT attribute.attisdropped;
  IF NOT FOUND THEN
    RAISE EXCEPTION
      'Expected cycle_id column on public.idea_feedback_drafts is missing';
  END IF;

  SELECT pg_catalog.count(*)
    INTO v_constraint_count
    FROM pg_catalog.pg_constraint AS constraint_row
    WHERE constraint_row.conrelid = v_table_oid
      AND constraint_row.contype = 'u'
      AND constraint_row.conkey = ARRAY[v_cycle_attnum]::smallint[];
  IF v_constraint_count <> 1 THEN
    RAISE EXCEPTION
      'Expected exactly one global unique constraint on idea_feedback_drafts(cycle_id); found %',
      v_constraint_count;
  END IF;

  SELECT constraint_row.conname,
         pg_catalog.pg_get_constraintdef(constraint_row.oid, true)
           AS constraint_definition,
         constraint_row.convalidated,
         constraint_row.condeferrable,
         constraint_row.condeferred,
         index_row.indisunique,
         index_row.indpred IS NULL AS index_is_not_partial,
         index_row.indnkeyatts,
         index_row.indnatts
    INTO v_constraint
    FROM pg_catalog.pg_constraint AS constraint_row
    JOIN pg_catalog.pg_index AS index_row
      ON index_row.indexrelid = constraint_row.conindid
    WHERE constraint_row.conrelid = v_table_oid
      AND constraint_row.contype = 'u'
      AND constraint_row.conkey = ARRAY[v_cycle_attnum]::smallint[];

  IF v_constraint.conname <> 'idea_feedback_drafts_cycle_id_key'
     OR v_constraint.constraint_definition <> 'UNIQUE (cycle_id)'
     OR NOT v_constraint.convalidated
     OR v_constraint.condeferrable
     OR v_constraint.condeferred
     OR NOT v_constraint.indisunique
     OR NOT v_constraint.index_is_not_partial
     OR v_constraint.indnkeyatts <> 1
     OR v_constraint.indnatts <> 1 THEN
    RAISE EXCEPTION
      'idea_feedback_drafts cycle_id uniqueness does not match the expected global unique constraint';
  END IF;

  EXECUTE pg_catalog.format(
    'ALTER TABLE public.idea_feedback_drafts DROP CONSTRAINT %I',
    v_constraint.conname
  );
END
$feedback_draft_constraint_check$;

CREATE UNIQUE INDEX idea_feedback_drafts_one_active_cycle_idx
  ON public.idea_feedback_drafts (cycle_id)
  WHERE status = 'active';

COMMIT;
