BEGIN;

DO $prerequisite_check$
BEGIN
  IF NOT pg_catalog.pg_has_role(
       'postgres', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'anon', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'authenticated', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'service_role', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'authenticator', 'javaneh_identity_executor', 'MEMBER'
     ) THEN
    RAISE EXCEPTION 'The existing identity executor prerequisite is missing or unsafe'
      USING ERRCODE = '42501';
  END IF;
END
$prerequisite_check$;

ALTER TABLE public.idea_stages
  ADD COLUMN confirmed_version_id uuid;

UPDATE public.idea_stages
  SET confirmed_version_id = pg_catalog.gen_random_uuid()
  WHERE stage_number IN (1, 2)
    AND status = 'confirmed';

ALTER TABLE public.idea_stages
  ADD CONSTRAINT idea_stages_classification_version_consistent
  CHECK (
    stage_number NOT IN (1, 2)
    OR ((status = 'confirmed') = (confirmed_version_id IS NOT NULL))
  );

CREATE FUNCTION public.assign_idea_stage_confirmation_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
  IF NEW.stage_number IN (1, 2) THEN
    IF NEW.status = 'confirmed'
       AND (
         OLD.status IS DISTINCT FROM NEW.status
         OR OLD.confirmed_version_id IS DISTINCT FROM NEW.confirmed_version_id
       ) THEN
      NEW.confirmed_version_id := pg_catalog.gen_random_uuid();
    ELSIF NEW.status <> 'confirmed' THEN
      NEW.confirmed_version_id := NULL;
    END IF;
  END IF;
  RETURN NEW;
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
ALTER FUNCTION public.assign_idea_stage_confirmation_version()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.assign_idea_stage_confirmation_version()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER idea_stage_confirmation_version
  BEFORE UPDATE ON public.idea_stages
  FOR EACH ROW EXECUTE FUNCTION public.assign_idea_stage_confirmation_version();

ALTER TABLE public.idea_stage_confirmed_versions
  ADD COLUMN source_confirmation_version_id uuid;

CREATE UNIQUE INDEX idea_stage_versions_confirmation_id_idx
  ON public.idea_stage_confirmed_versions (
    idea_id,
    stage_number,
    source_confirmation_version_id
  )
  WHERE source_confirmation_version_id IS NOT NULL;

CREATE FUNCTION public.attach_idea_stage_confirmation_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
  IF NEW.stage_number IN (1, 2) THEN
    SELECT stage.confirmed_version_id
      INTO NEW.source_confirmation_version_id
      FROM public.idea_stages AS stage
      WHERE stage.idea_id = NEW.idea_id
        AND stage.stage_number = NEW.stage_number
        AND stage.status = 'confirmed';
    IF NEW.source_confirmation_version_id IS NULL THEN
      RAISE EXCEPTION 'A confirmed stage version is required for its snapshot'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END
$function$;
ALTER FUNCTION public.attach_idea_stage_confirmation_version()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.attach_idea_stage_confirmation_version()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER idea_stage_version_confirmation_reference
  BEFORE INSERT ON public.idea_stage_confirmed_versions
  FOR EACH ROW EXECUTE FUNCTION public.attach_idea_stage_confirmation_version();

CREATE TABLE public.thematic_taxonomy_versions (
  version text PRIMARY KEY,
  active boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT thematic_taxonomy_versions_key_format
    CHECK (version ~ '^[a-z0-9._-]{1,80}$'),
  CONSTRAINT thematic_taxonomy_versions_time_order
    CHECK (updated_at >= created_at)
);

CREATE UNIQUE INDEX thematic_taxonomy_one_active_idx
  ON public.thematic_taxonomy_versions (active)
  WHERE active;

CREATE TABLE public.thematic_axes (
  taxonomy_version text NOT NULL
    REFERENCES public.thematic_taxonomy_versions(version) ON DELETE RESTRICT,
  axis_id text NOT NULL,
  official_name text NOT NULL,
  official_definition text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (taxonomy_version, axis_id),
  CONSTRAINT thematic_axes_id_format
    CHECK (axis_id ~ '^[a-z][a-z0-9_]{1,79}$'),
  CONSTRAINT thematic_axes_name_not_empty
    CHECK (pg_catalog.length(pg_catalog.btrim(official_name)) > 0),
  CONSTRAINT thematic_axes_definition_not_empty
    CHECK (pg_catalog.length(pg_catalog.btrim(official_definition)) > 0),
  CONSTRAINT thematic_axes_time_order
    CHECK (updated_at >= created_at)
);

INSERT INTO public.thematic_taxonomy_versions (version, active)
VALUES ('phase7.v1', true)
ON CONFLICT (version) DO UPDATE
SET active = EXCLUDED.active,
    updated_at = pg_catalog.clock_timestamp();

INSERT INTO public.thematic_axes (
  taxonomy_version, axis_id, official_name, official_definition, active
)
VALUES
  (
    'phase7.v1',
    'resource_efficiency',
    'بهینه‌سازی مصرف و کاهش اتلاف منابع با مشارکت مردم',
    'فعال‌سازی مشارکت مردم و شکل‌دهی رفتارهای مسئولانه و پایدار در مدیریت مصرف انرژی، آب، مواد غذایی، کالا و سایر منابع و کاهش اسراف و هدررفت',
    true
  ),
  (
    'phase7.v1',
    'domestic_production',
    'تقویت فرهنگ و کنش مردمی در حمایت از تولید داخلی',
    'تقویت نگرش، ترجیحات و رفتارهای مردم در حمایت آگاهانه و پایدار از تولید داخلی و توسعه الگوهای اجتماعی و فرهنگی پشتیبان تولید ملی',
    true
  ),
  (
    'phase7.v1',
    'economic_mutual_aid',
    'توسعه یاریگری و الگوهای همکاری مردمی در اقتصاد',
    'توسعه سازوکارها و الگوهای نوآورانه یاریگری، مواسات، حمایت متقابل و همکاری اقتصادی مردم از طریق به‌اشتراک‌گذاری و به‌کارگیری منابع، دارایی‌ها، مهارت‌ها و ظرفیت‌های فردی و جمعی برای پاسخ به نیازهای اقتصادی و کاهش فشارهای معیشتی',
    true
  ),
  (
    'phase7.v1',
    'social_resilience',
    'ارتقای تاب‌آوری اجتماعی در مواجهه با فشارهای اقتصادی',
    'تقویت ظرفیت افراد و اجتماعات برای سازگاری و مواجهه جمعی با فشارها و پیامدهای اقتصادی از طریق تقویت پیوندهای اجتماعی، همیاری، اعتماد، امید و ظرفیت‌های حمایت متقابل',
    true
  ),
  (
    'phase7.v1',
    'social_mobilization',
    'نوآوری در ارتباطات، روایت و بسیج اجتماعی',
    'توسعه روایت‌ها، الگوهای ارتباطی و ابتکارات رسانه‌ای نوآورانه برای افزایش آگاهی و انگیزه عمومی، اصلاح نگرش‌ها و رفتارها و ترغیب مردم به مشارکت و کنش هدفمند و پایدار',
    true
  ),
  (
    'phase7.v1',
    'vulnerable_empowerment',
    'نوآوری در الگوهای توانمندسازی و حمایت از اقشار آسیب‌پذیر',
    'توسعه الگوها و راه‌حل‌های نوآورانه برای حمایت و توانمندسازی اقشار آسیب‌پذیر با هدف تقویت ظرفیت و عاملیت آنان، کاهش آسیب‌پذیری و افزایش توان مواجهه با فشارهای اقتصادی',
    true
  )
ON CONFLICT (taxonomy_version, axis_id) DO UPDATE
SET official_name = EXCLUDED.official_name,
    official_definition = EXCLUDED.official_definition,
    active = EXCLUDED.active,
    updated_at = pg_catalog.clock_timestamp();

CREATE TABLE public.idea_classification_results (
  classification_id uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  idea_id uuid NOT NULL
    REFERENCES public.ideas(id) ON DELETE CASCADE,
  taxonomy_version text NOT NULL,
  primary_axis_id text NOT NULL,
  secondary_axis_1_id text NOT NULL,
  secondary_axis_2_id text NOT NULL,
  primary_percentage integer NOT NULL,
  secondary_1_percentage integer NOT NULL,
  secondary_2_percentage integer NOT NULL,
  primary_rationale text NOT NULL,
  secondary_1_rationale text NOT NULL,
  secondary_2_rationale text NOT NULL,
  confidence numeric,
  model_id text NOT NULL,
  prompt_version text NOT NULL,
  source_stage_1_revision_id uuid NOT NULL,
  source_stage_2_revision_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (classification_id),
  UNIQUE (idea_id, classification_id),
  CONSTRAINT idea_classification_primary_axis_fk
    FOREIGN KEY (taxonomy_version, primary_axis_id)
    REFERENCES public.thematic_axes(taxonomy_version, axis_id)
    ON DELETE RESTRICT,
  CONSTRAINT idea_classification_secondary_1_axis_fk
    FOREIGN KEY (taxonomy_version, secondary_axis_1_id)
    REFERENCES public.thematic_axes(taxonomy_version, axis_id)
    ON DELETE RESTRICT,
  CONSTRAINT idea_classification_secondary_2_axis_fk
    FOREIGN KEY (taxonomy_version, secondary_axis_2_id)
    REFERENCES public.thematic_axes(taxonomy_version, axis_id)
    ON DELETE RESTRICT,
  CONSTRAINT idea_classification_axes_distinct
    CHECK (
      primary_axis_id <> secondary_axis_1_id
      AND primary_axis_id <> secondary_axis_2_id
      AND secondary_axis_1_id <> secondary_axis_2_id
    ),
  CONSTRAINT idea_classification_percentages_valid
    CHECK (
      primary_percentage BETWEEN 0 AND 100
      AND secondary_1_percentage BETWEEN 0 AND 100
      AND secondary_2_percentage BETWEEN 0 AND 100
      AND primary_percentage::bigint + secondary_1_percentage::bigint
        + secondary_2_percentage::bigint = 100
      AND primary_percentage > secondary_1_percentage
      AND primary_percentage > secondary_2_percentage
    ),
  CONSTRAINT idea_classification_rationales_valid
    CHECK (
      pg_catalog.length(pg_catalog.btrim(primary_rationale)) BETWEEN 1 AND 700
      AND pg_catalog.length(pg_catalog.btrim(secondary_1_rationale)) BETWEEN 1 AND 700
      AND pg_catalog.length(pg_catalog.btrim(secondary_2_rationale)) BETWEEN 1 AND 700
    ),
  CONSTRAINT idea_classification_confidence_valid
    CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  CONSTRAINT idea_classification_metadata_valid
    CHECK (
      pg_catalog.length(pg_catalog.btrim(model_id)) BETWEEN 1 AND 180
      AND pg_catalog.length(pg_catalog.btrim(prompt_version)) BETWEEN 1 AND 80
    )
);

CREATE UNIQUE INDEX idea_classification_logical_result_idx
  ON public.idea_classification_results (
    idea_id,
    source_stage_1_revision_id,
    source_stage_2_revision_id,
    taxonomy_version,
    prompt_version
  );
CREATE INDEX idea_classification_results_idea_created_idx
  ON public.idea_classification_results (idea_id, created_at DESC);

CREATE TABLE public.idea_classification_state (
  idea_id uuid PRIMARY KEY
    REFERENCES public.ideas(id) ON DELETE CASCADE,
  status text NOT NULL
    CHECK (status IN ('pending', 'processing', 'current', 'stale', 'failed')),
  source_stage_1_revision_id uuid NOT NULL,
  source_stage_2_revision_id uuid NOT NULL,
  current_classification_id uuid,
  attempt_token uuid,
  lease_expires_at timestamptz,
  last_failure_category text CHECK (
    last_failure_category IS NULL OR last_failure_category IN (
      'not_configured',
      'input_too_large',
      'circuit_open',
      'circuit_control_unavailable',
      'timeout',
      'network',
      'rate_limited',
      'budget_exceeded',
      'authentication',
      'invalid_response',
      'unavailable',
      'unknown',
      'persistence_unavailable'
    )
  ),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT idea_classification_state_current_fk
    FOREIGN KEY (idea_id, current_classification_id)
    REFERENCES public.idea_classification_results(idea_id, classification_id)
    ON DELETE SET NULL (current_classification_id),
  CONSTRAINT idea_classification_state_attempt_consistent
    CHECK (
      (status = 'processing' AND attempt_token IS NOT NULL
        AND lease_expires_at IS NOT NULL)
      OR (status <> 'processing' AND attempt_token IS NULL
        AND lease_expires_at IS NULL)
    ),
  CONSTRAINT idea_classification_state_current_has_result
    CHECK (status <> 'current' OR current_classification_id IS NOT NULL)
);

CREATE INDEX idea_classification_state_status_updated_idx
  ON public.idea_classification_state (status, updated_at);

ALTER TABLE public.thematic_taxonomy_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.thematic_taxonomy_versions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.thematic_axes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.thematic_axes FORCE ROW LEVEL SECURITY;
ALTER TABLE public.idea_classification_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_classification_results FORCE ROW LEVEL SECURITY;
ALTER TABLE public.idea_classification_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.idea_classification_state FORCE ROW LEVEL SECURITY;

CREATE POLICY thematic_taxonomy_versions_active_read
  ON public.thematic_taxonomy_versions FOR SELECT TO authenticated
  USING (active);
CREATE POLICY thematic_taxonomy_versions_executor_all
  ON public.thematic_taxonomy_versions FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

CREATE POLICY thematic_axes_active_read
  ON public.thematic_axes FOR SELECT TO authenticated
  USING (
    active
    AND EXISTS (
      SELECT 1
      FROM public.thematic_taxonomy_versions AS taxonomy
      WHERE taxonomy.version = thematic_axes.taxonomy_version
        AND taxonomy.active
    )
  );
CREATE POLICY thematic_axes_executor_all
  ON public.thematic_axes FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

CREATE POLICY idea_classification_state_owner_read
  ON public.idea_classification_state FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
    FROM public.ideas AS idea
    WHERE idea.id = idea_classification_state.idea_id
      AND idea.owner_id = javaneh_private.current_uid()
  ));
CREATE POLICY idea_classification_state_executor_all
  ON public.idea_classification_state FOR ALL TO javaneh_identity_executor
  USING (true) WITH CHECK (true);

CREATE POLICY idea_classification_current_owner_read
  ON public.idea_classification_results FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
    FROM public.idea_classification_state AS state
    JOIN public.ideas AS idea ON idea.id = state.idea_id
    WHERE state.idea_id = idea_classification_results.idea_id
      AND state.status = 'current'
      AND state.current_classification_id =
        idea_classification_results.classification_id
      AND idea.owner_id = javaneh_private.current_uid()
  ));
CREATE POLICY idea_classification_results_executor_read_insert
  ON public.idea_classification_results FOR SELECT TO javaneh_identity_executor
  USING (true);
CREATE POLICY idea_classification_results_executor_insert
  ON public.idea_classification_results FOR INSERT TO javaneh_identity_executor
  WITH CHECK (true);

REVOKE ALL ON TABLE
  public.thematic_taxonomy_versions,
  public.thematic_axes,
  public.idea_classification_results,
  public.idea_classification_state
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON TABLE
  public.thematic_taxonomy_versions,
  public.thematic_axes,
  public.idea_classification_state,
  public.idea_classification_results
  TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE
  public.thematic_taxonomy_versions,
  public.thematic_axes
  TO javaneh_identity_executor;
GRANT SELECT, INSERT ON TABLE public.idea_classification_results
  TO javaneh_identity_executor;
GRANT SELECT, INSERT, UPDATE ON TABLE public.idea_classification_state
  TO javaneh_identity_executor;

CREATE FUNCTION public.mark_idea_classification_stale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
  IF NEW.stage_number NOT IN (1, 2) THEN
    RETURN NEW;
  END IF;

  IF OLD.data IS DISTINCT FROM NEW.data
     OR (OLD.status = 'confirmed' AND NEW.status <> 'confirmed') THEN
    UPDATE public.idea_classification_state AS state
      SET status = 'stale',
          attempt_token = NULL,
          lease_expires_at = NULL,
          last_failure_category = NULL,
          updated_at = pg_catalog.clock_timestamp()
      WHERE state.idea_id = NEW.idea_id
        AND state.status <> 'stale';
    RETURN NEW;
  END IF;

  IF NEW.status = 'confirmed'
     AND (
       OLD.status IS DISTINCT FROM NEW.status
       OR OLD.confirmed_at IS DISTINCT FROM NEW.confirmed_at
     ) THEN
    IF EXISTS (
      SELECT 1
      FROM public.idea_stages AS stage_1
      JOIN public.idea_stages AS stage_2
        ON stage_2.idea_id = stage_1.idea_id
       AND stage_2.stage_number = 2
      WHERE stage_1.idea_id = NEW.idea_id
        AND stage_1.stage_number = 1
        AND stage_1.status = 'confirmed'
        AND stage_2.status = 'confirmed'
    ) THEN
      INSERT INTO public.idea_classification_state (
        idea_id,
        status,
        source_stage_1_revision_id,
        source_stage_2_revision_id
      )
      SELECT
        stage_1.idea_id,
        'pending',
        stage_1.confirmed_version_id,
        stage_2.confirmed_version_id
      FROM public.idea_stages AS stage_1
      JOIN public.idea_stages AS stage_2
        ON stage_2.idea_id = stage_1.idea_id
       AND stage_2.stage_number = 2
      WHERE stage_1.idea_id = NEW.idea_id
        AND stage_1.stage_number = 1
        AND stage_1.status = 'confirmed'
        AND stage_2.status = 'confirmed'
      ON CONFLICT (idea_id) DO UPDATE
      SET status = 'pending',
          source_stage_1_revision_id = EXCLUDED.source_stage_1_revision_id,
          source_stage_2_revision_id = EXCLUDED.source_stage_2_revision_id,
          attempt_token = NULL,
          lease_expires_at = NULL,
          last_failure_category = NULL,
          updated_at = pg_catalog.clock_timestamp();
    END IF;
  END IF;

  RETURN NEW;
END
$function$;
ALTER FUNCTION public.mark_idea_classification_stale()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.mark_idea_classification_stale()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER idea_classification_source_change
  AFTER UPDATE ON public.idea_stages
  FOR EACH ROW EXECUTE FUNCTION public.mark_idea_classification_stale();

CREATE FUNCTION public.claim_idea_classification(
  p_idea_id uuid,
  p_participant_id uuid,
  p_stage_1_revision_id uuid,
  p_stage_2_revision_id uuid,
  p_taxonomy_version text,
  p_prompt_version text,
  p_attempt_token uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_owner_id uuid;
  v_stage_1 uuid;
  v_stage_2 uuid;
  v_state public.idea_classification_state%ROWTYPE;
BEGIN
  IF p_idea_id IS NULL OR p_participant_id IS NULL
     OR p_stage_1_revision_id IS NULL
     OR p_stage_2_revision_id IS NULL
     OR p_taxonomy_version IS NULL OR p_prompt_version IS NULL
     OR p_attempt_token IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  SELECT idea.owner_id INTO v_owner_id
    FROM public.ideas AS idea
    WHERE idea.id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND OR v_owner_id <> p_participant_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'not_found_or_not_owned');
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
  IF v_stage_1 IS NULL OR v_stage_2 IS NULL
     OR v_stage_1 <> p_stage_1_revision_id
     OR v_stage_2 <> p_stage_2_revision_id THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'stale_source');
  END IF;

  SELECT state.* INTO v_state
    FROM public.idea_classification_state AS state
    WHERE state.idea_id = p_idea_id
    FOR UPDATE;
  IF NOT FOUND
     OR v_state.source_stage_1_revision_id <> v_stage_1
     OR v_state.source_stage_2_revision_id <> v_stage_2 THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'stale_source');
  END IF;
  IF v_state.status = 'current' AND EXISTS (
    SELECT 1
    FROM public.idea_classification_results AS result
    WHERE result.idea_id = p_idea_id
      AND result.classification_id = v_state.current_classification_id
      AND result.taxonomy_version = p_taxonomy_version
      AND result.prompt_version = p_prompt_version
  ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'already_current');
  END IF;
  IF v_state.status = 'processing'
     AND v_state.lease_expires_at > pg_catalog.clock_timestamp() THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'in_progress');
  END IF;
  IF v_state.status NOT IN ('pending', 'failed', 'processing', 'current') THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'stale_source');
  END IF;

  UPDATE public.idea_classification_state AS state
    SET status = 'processing',
        attempt_token = p_attempt_token,
        lease_expires_at = pg_catalog.clock_timestamp() + INTERVAL '1 minute',
        last_failure_category = NULL,
        updated_at = pg_catalog.clock_timestamp()
    WHERE state.idea_id = p_idea_id;

  RETURN pg_catalog.jsonb_build_object(
    'outcome', 'claimed',
    'attempt_token', p_attempt_token
  );
END
$function$;
ALTER FUNCTION public.claim_idea_classification(
  uuid, uuid, uuid, uuid, text, text, uuid
) OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.claim_idea_classification(
  uuid, uuid, uuid, uuid, text, text, uuid
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_idea_classification(
  uuid, uuid, uuid, uuid, text, text, uuid
) TO service_role;

CREATE FUNCTION public.complete_idea_classification(
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

  IF pg_catalog.jsonb_object_length(p_rationales) <> 3
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

CREATE FUNCTION public.fail_idea_classification(
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
  v_updated_count integer;
BEGIN
  IF p_idea_id IS NULL OR p_attempt_token IS NULL
     OR p_failure_category IS NULL
     OR p_failure_category NOT IN (
       'not_configured',
       'input_too_large',
       'circuit_open',
       'circuit_control_unavailable',
       'timeout',
       'network',
       'rate_limited',
       'budget_exceeded',
       'authentication',
       'invalid_response',
       'unavailable',
       'unknown',
       'persistence_unavailable'
     ) THEN
    RETURN pg_catalog.jsonb_build_object('outcome', 'invalid_input');
  END IF;

  UPDATE public.idea_classification_state AS state
    SET status = 'failed',
        attempt_token = NULL,
        lease_expires_at = NULL,
        last_failure_category = p_failure_category,
        updated_at = pg_catalog.clock_timestamp()
    WHERE state.idea_id = p_idea_id
      AND state.status = 'processing'
      AND state.attempt_token = p_attempt_token;
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN pg_catalog.jsonb_build_object(
    'outcome',
    CASE WHEN v_updated_count = 1 THEN 'failed' ELSE 'stale_attempt' END
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

COMMENT ON TABLE public.thematic_taxonomy_versions IS
  'Versioned official thematic classification taxonomies.';
COMMENT ON TABLE public.thematic_axes IS
  'Database-backed official axis names and definitions by taxonomy version.';
COMMENT ON TABLE public.idea_classification_results IS
  'Append-only successful idea classifications; source content is not copied.';
COMMENT ON TABLE public.idea_classification_state IS
  'Owner-scoped current/pending/stale classification state and bounded work lease.';
COMMENT ON COLUMN public.idea_stage_confirmed_versions.source_confirmation_version_id IS
  'Content-free Stage 1/2 source revision reference retained for classification traceability.';
COMMENT ON COLUMN public.idea_classification_results.confidence IS
  'Optional model confidence, separate from thematic relevance percentages.';

COMMIT;
