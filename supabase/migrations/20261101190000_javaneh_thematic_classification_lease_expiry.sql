BEGIN;

DO $lease_guard_rename$
BEGIN
  IF pg_catalog.to_regprocedure(
       'public.complete_idea_classification(uuid,uuid,text,text,text[],integer,integer[],jsonb,numeric,text,text,uuid,uuid)'
     ) IS NOT NULL
     AND pg_catalog.to_regprocedure(
       'public.complete_idea_classification_without_lease_guard(uuid,uuid,text,text,text[],integer,integer[],jsonb,numeric,text,text,uuid,uuid)'
     ) IS NULL THEN
    ALTER FUNCTION public.complete_idea_classification(
      uuid, uuid, text, text, text[], integer, integer[], jsonb, numeric,
      text, text, uuid, uuid
    ) RENAME TO complete_idea_classification_without_lease_guard;
  END IF;

  IF pg_catalog.to_regprocedure(
       'public.fail_idea_classification(uuid,uuid,text)'
     ) IS NOT NULL
     AND pg_catalog.to_regprocedure(
       'public.fail_idea_classification_without_lease_guard(uuid,uuid,text)'
     ) IS NULL THEN
    ALTER FUNCTION public.fail_idea_classification(uuid, uuid, text)
      RENAME TO fail_idea_classification_without_lease_guard;
  END IF;
END
$lease_guard_rename$;

ALTER FUNCTION public.complete_idea_classification_without_lease_guard(
  uuid, uuid, text, text, text[], integer, integer[], jsonb, numeric,
  text, text, uuid, uuid
) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION
  public.complete_idea_classification_without_lease_guard(
    uuid, uuid, text, text, text[], integer, integer[], jsonb, numeric,
    text, text, uuid, uuid
  ) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION
  public.complete_idea_classification_without_lease_guard(
    uuid, uuid, text, text, text[], integer, integer[], jsonb, numeric,
    text, text, uuid, uuid
  ) TO javaneh_identity_executor;

ALTER FUNCTION public.fail_idea_classification_without_lease_guard(
  uuid, uuid, text
) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION
  public.fail_idea_classification_without_lease_guard(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION
  public.fail_idea_classification_without_lease_guard(uuid, uuid, text)
  TO javaneh_identity_executor;

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
BEGIN
  SELECT state.*
  INTO v_state
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = p_idea_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_state.status <> 'processing'
     OR v_state.attempt_token IS DISTINCT FROM p_attempt_token
     OR v_state.source_stage_1_revision_id
       IS DISTINCT FROM p_stage_1_revision_id
     OR v_state.source_stage_2_revision_id
       IS DISTINCT FROM p_stage_2_revision_id
     OR v_state.lease_expires_at IS NULL
     OR v_state.lease_expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'stale_attempt');
  END IF;

  RETURN public.complete_idea_classification_without_lease_guard(
    p_idea_id,
    p_attempt_token,
    p_taxonomy_version,
    p_primary_axis_id,
    p_secondary_axis_ids,
    p_primary_percentage,
    p_secondary_percentages,
    p_rationales,
    p_confidence,
    p_model_id,
    p_prompt_version,
    p_stage_1_revision_id,
    p_stage_2_revision_id
  );
END
$function$;
DO $executor_create_check$
BEGIN
  IF pg_catalog.has_schema_privilege(
       'javaneh_identity_executor', 'public', 'CREATE'
     ) THEN
    RAISE EXCEPTION
      'javaneh_identity_executor already has CREATE on public; refusing temporary privilege window'
      USING ERRCODE = '42501';
  END IF;
END
$executor_create_check$;
GRANT CREATE ON SCHEMA public TO javaneh_identity_executor;
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

CREATE OR REPLACE FUNCTION public.fail_idea_classification(
  p_idea_id uuid,
  p_attempt_token uuid,
  p_failure_category text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_state public.idea_classification_state%ROWTYPE;
BEGIN
  SELECT state.*
  INTO v_state
  FROM public.idea_classification_state AS state
  WHERE state.idea_id = p_idea_id
  FOR UPDATE;

  IF NOT FOUND
     OR v_state.status <> 'processing'
     OR v_state.attempt_token IS DISTINCT FROM p_attempt_token
     OR v_state.lease_expires_at IS NULL
     OR v_state.lease_expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'stale_attempt');
  END IF;

  RETURN public.fail_idea_classification_without_lease_guard(
    p_idea_id,
    p_attempt_token,
    p_failure_category
  );
END
$function$;
ALTER FUNCTION public.fail_idea_classification(uuid, uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.fail_idea_classification(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.fail_idea_classification(uuid, uuid, text)
  TO service_role;

COMMIT;
