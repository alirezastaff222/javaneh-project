BEGIN;

CREATE OR REPLACE FUNCTION public.complete_idea_classification(
  p_idea_id uuid,
  p_attempt_token uuid,
  p_taxonomy_version text,
  p_primary_axis_id text,
  p_secondary_axis_ids text[],
  p_primary_percentage integer,
  p_secondary_percentages integer[],
  p_rationales jsonb,
  p_confidence numeric,
  p_model_id text,
  p_prompt_version text,
  p_stage_1_revision_id uuid,
  p_stage_2_revision_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_state public.idea_classification_state%ROWTYPE;
  v_stage_1 uuid;
  v_stage_2 uuid;
  v_classification_id uuid;
  v_total bigint;
BEGIN
  IF p_idea_id IS NULL OR p_attempt_token IS NULL
     OR p_taxonomy_version IS NULL OR p_primary_axis_id IS NULL
     OR p_secondary_axis_ids IS NULL
     OR pg_catalog.cardinality(p_secondary_axis_ids) <> 2
     OR pg_catalog.array_ndims(p_secondary_axis_ids) <> 1
     OR pg_catalog.array_lower(p_secondary_axis_ids, 1) <> 1
     OR p_secondary_axis_ids[1] IS NULL
     OR p_secondary_axis_ids[2] IS NULL
     OR p_secondary_percentages IS NULL
     OR pg_catalog.cardinality(p_secondary_percentages) <> 2
     OR pg_catalog.array_ndims(p_secondary_percentages) <> 1
     OR pg_catalog.array_lower(p_secondary_percentages, 1) <> 1
     OR p_secondary_percentages[1] IS NULL
     OR p_secondary_percentages[2] IS NULL
     OR p_primary_percentage IS NULL
     OR p_rationales IS NULL
     OR pg_catalog.jsonb_typeof(p_rationales) IS DISTINCT FROM 'object'
     OR p_model_id IS NULL OR p_prompt_version IS NULL
     OR p_stage_1_revision_id IS NULL OR p_stage_2_revision_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  IF p_primary_axis_id = p_secondary_axis_ids[1]
     OR p_primary_axis_id = p_secondary_axis_ids[2]
     OR p_secondary_axis_ids[1] = p_secondary_axis_ids[2] THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_axes');
  END IF;
  v_total := p_primary_percentage::bigint
    + p_secondary_percentages[1]::bigint
    + p_secondary_percentages[2]::bigint;
  IF p_primary_percentage NOT BETWEEN 0 AND 100
     OR p_secondary_percentages[1] NOT BETWEEN 0 AND 100
     OR p_secondary_percentages[2] NOT BETWEEN 0 AND 100
     OR v_total <> 100
     OR p_primary_percentage <= p_secondary_percentages[1]
     OR p_primary_percentage <= p_secondary_percentages[2] THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_percentages');
  END IF;

  IF (
       SELECT pg_catalog.count(*)
       FROM pg_catalog.jsonb_object_keys(p_rationales)
     ) <> 3
     OR pg_catalog.jsonb_typeof(
       p_rationales->p_primary_axis_id
     ) IS DISTINCT FROM 'string'
     OR pg_catalog.length(pg_catalog.btrim(p_rationales->>p_primary_axis_id))
       NOT BETWEEN 1 AND 700
     OR pg_catalog.jsonb_typeof(
       p_rationales->p_secondary_axis_ids[1]
     ) IS DISTINCT FROM 'string'
     OR pg_catalog.length(pg_catalog.btrim(
       p_rationales->>p_secondary_axis_ids[1]
     )) NOT BETWEEN 1 AND 700
     OR pg_catalog.jsonb_typeof(
       p_rationales->p_secondary_axis_ids[2]
     ) IS DISTINCT FROM 'string'
     OR pg_catalog.length(pg_catalog.btrim(
       p_rationales->>p_secondary_axis_ids[2]
     )) NOT BETWEEN 1 AND 700 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_rationales');
  END IF;
  IF p_confidence IS NOT NULL AND p_confidence NOT BETWEEN 0 AND 1 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_confidence');
  END IF;
  IF pg_catalog.length(pg_catalog.btrim(p_model_id)) NOT BETWEEN 1 AND 180
     OR pg_catalog.length(pg_catalog.btrim(p_prompt_version))
       NOT BETWEEN 1 AND 80 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_metadata');
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.thematic_taxonomy_versions AS taxonomy
    WHERE taxonomy.version = p_taxonomy_version
      AND taxonomy.active
  ) OR (
    SELECT pg_catalog.count(*)
    FROM public.thematic_axes AS axis
    WHERE axis.taxonomy_version = p_taxonomy_version
      AND axis.active
  ) <> 6 OR EXISTS (
    SELECT 1
    FROM pg_catalog.unnest(
      ARRAY[
        p_primary_axis_id,
        p_secondary_axis_ids[1],
        p_secondary_axis_ids[2]
      ]
    ) AS selected_axis(axis_id)
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.thematic_axes AS axis
      WHERE axis.taxonomy_version = p_taxonomy_version
        AND axis.axis_id = selected_axis.axis_id
        AND axis.active
    )
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_axes');
  END IF;

  SELECT state.* INTO v_state
    FROM public.idea_classification_state AS state
    WHERE state.idea_id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND OR v_state.status <> 'processing'
     OR v_state.attempt_token <> p_attempt_token
     OR v_state.source_stage_1_revision_id <> p_stage_1_revision_id
     OR v_state.source_stage_2_revision_id <> p_stage_2_revision_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'stale_attempt');
  END IF;

  SELECT stage.confirmed_version_id INTO v_stage_1
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = 1
      AND stage.status = 'confirmed';
  SELECT stage.confirmed_version_id INTO v_stage_2
    FROM public.idea_stages AS stage
    WHERE stage.idea_id = p_idea_id
      AND stage.stage_number = 2
      AND stage.status = 'confirmed';
  IF v_stage_1 IS DISTINCT FROM p_stage_1_revision_id
     OR v_stage_2 IS DISTINCT FROM p_stage_2_revision_id THEN
    UPDATE public.idea_classification_state AS state
      SET status = 'stale',
          attempt_token = NULL,
          lease_expires_at = NULL,
          updated_at = pg_catalog.clock_timestamp()
      WHERE state.idea_id = p_idea_id;
    RETURN pg_catalog.jsonb_build_object('outcome', 'stale_source');
  END IF;

  INSERT INTO public.idea_classification_results (
    idea_id,
    taxonomy_version,
    primary_axis_id,
    secondary_axis_1_id,
    secondary_axis_2_id,
    primary_percentage,
    secondary_1_percentage,
    secondary_2_percentage,
    primary_rationale,
    secondary_1_rationale,
    secondary_2_rationale,
    confidence,
    model_id,
    prompt_version,
    source_stage_1_revision_id,
    source_stage_2_revision_id
  )
  VALUES (
    p_idea_id,
    p_taxonomy_version,
    p_primary_axis_id,
    p_secondary_axis_ids[1],
    p_secondary_axis_ids[2],
    p_primary_percentage,
    p_secondary_percentages[1],
    p_secondary_percentages[2],
    p_rationales->>p_primary_axis_id,
    p_rationales->>p_secondary_axis_ids[1],
    p_rationales->>p_secondary_axis_ids[2],
    p_confidence,
    p_model_id,
    p_prompt_version,
    p_stage_1_revision_id,
    p_stage_2_revision_id
  )
  ON CONFLICT (
    idea_id,
    source_stage_1_revision_id,
    source_stage_2_revision_id,
    taxonomy_version,
    prompt_version
  ) DO NOTHING
  RETURNING classification_id INTO v_classification_id;

  IF v_classification_id IS NULL THEN
    SELECT result.classification_id INTO v_classification_id
      FROM public.idea_classification_results AS result
      WHERE result.idea_id = p_idea_id
        AND result.source_stage_1_revision_id = p_stage_1_revision_id
        AND result.source_stage_2_revision_id = p_stage_2_revision_id
        AND result.taxonomy_version = p_taxonomy_version
        AND result.prompt_version = p_prompt_version;
  END IF;

  UPDATE public.idea_classification_state AS state
    SET status = 'current',
        current_classification_id = v_classification_id,
        attempt_token = NULL,
        lease_expires_at = NULL,
        last_failure_category = NULL,
        updated_at = pg_catalog.clock_timestamp()
    WHERE state.idea_id = p_idea_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'completed',
    'classification_id', v_classification_id
  );
END
$function$;
ALTER FUNCTION public.complete_idea_classification(
  uuid, uuid, text, text, text[], integer, integer[], jsonb, numeric,
  text, text, uuid, uuid
) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.complete_idea_classification(
  uuid, uuid, text, text, text[], integer, integer[], jsonb, numeric,
  text, text, uuid, uuid
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_idea_classification(
  uuid, uuid, text, text, text[], integer, integer[], jsonb, numeric,
  text, text, uuid, uuid
) TO service_role;

CREATE OR REPLACE FUNCTION public.backfill_phase7_classification_state()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_inserted_count integer;
BEGIN
  INSERT INTO public.idea_classification_state (
    idea_id,
    status,
    source_stage_1_revision_id,
    source_stage_2_revision_id,
    current_classification_id
  )
  SELECT
    stage_1.idea_id,
    CASE
      WHEN current_result.classification_id IS NULL THEN 'pending'
      ELSE 'current'
    END,
    stage_1.confirmed_version_id,
    stage_2.confirmed_version_id,
    current_result.classification_id
  FROM public.idea_stages AS stage_1
  JOIN public.idea_stages AS stage_2
    ON stage_2.idea_id = stage_1.idea_id
   AND stage_2.stage_number = 2
   AND stage_2.status = 'confirmed'
  LEFT JOIN LATERAL (
    SELECT result.classification_id
    FROM public.idea_classification_results AS result
    WHERE result.idea_id = stage_1.idea_id
      AND result.source_stage_1_revision_id = stage_1.confirmed_version_id
      AND result.source_stage_2_revision_id = stage_2.confirmed_version_id
      AND result.taxonomy_version = 'phase7.v1'
      AND result.prompt_version = 'phase7.classification.v1'
      AND EXISTS (
        SELECT 1
        FROM public.thematic_taxonomy_versions AS taxonomy
        WHERE taxonomy.version = result.taxonomy_version
          AND taxonomy.active
      )
      AND (
        SELECT pg_catalog.count(*)
        FROM public.thematic_axes AS axis
        WHERE axis.taxonomy_version = result.taxonomy_version
          AND axis.active
          AND axis.axis_id IN (
            result.primary_axis_id,
            result.secondary_axis_1_id,
            result.secondary_axis_2_id
          )
      ) = 3
    LIMIT 1
  ) AS current_result ON true
  WHERE stage_1.stage_number = 1
    AND stage_1.status = 'confirmed'
    AND stage_1.confirmed_version_id IS NOT NULL
    AND stage_2.confirmed_version_id IS NOT NULL
  ON CONFLICT (idea_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;
  RETURN v_inserted_count;
END
$function$;
ALTER FUNCTION public.backfill_phase7_classification_state()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.backfill_phase7_classification_state()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.backfill_phase7_classification_state()
  TO postgres;

SELECT public.backfill_phase7_classification_state();

COMMENT ON FUNCTION public.backfill_phase7_classification_state() IS
  'Idempotently initializes missing Phase 7 state for existing confirmed Stage 1/2 ideas; never overwrites state or classification history.';

COMMIT;
