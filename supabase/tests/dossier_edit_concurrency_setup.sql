-- Use only against an isolated disposable database. This setup commits so two
-- independent pgbench sessions can contend on the same submitted revision.
BEGIN;

CREATE TABLE public.m9r10_dossier_concurrency_outcomes (
  backend_pid integer PRIMARY KEY,
  outcome text NOT NULL
);

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES (
  'a9b90000-0000-4000-8000-000000000001', 'authenticated',
  'authenticated', 'm9r10-concurrent@test.invalid', '',
  '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
);

SET LOCAL ROLE authenticated;
SELECT pg_catalog.set_config(
  'request.jwt.claim.sub', 'a9b90000-0000-4000-8000-000000000001', true
);

DO $m9r10_concurrency_setup$
DECLARE
  v_result jsonb;
  v_idea_id uuid;
  v_revision integer := 1;
  v_stage smallint;
BEGIN
  v_result := public.create_idea('a9ba0000-0000-4000-8000-000000000001');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Concurrent dossier idea creation failed: %', v_result;
  END IF;
  v_idea_id := (v_result->>'idea_id')::uuid;

  FOR v_stage IN 1..6 LOOP
    v_result := public.save_idea_content(
      v_idea_id,
      (
        'a9bb0000-0000-4000-8000-0000000000'
          || pg_catalog.lpad(v_stage::text, 2, '0')
      )::uuid,
      v_revision,
      pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'stage_number', v_stage,
          'data', pg_catalog.jsonb_build_object(
            'content', 'concurrency fixture ' || v_stage::text
          )
        )
      )
    );
    IF v_result->>'outcome' <> 'applied' THEN
      RAISE EXCEPTION 'Concurrent fixture stage save failed: %', v_result;
    END IF;
    v_revision := (v_result->>'result_revision')::integer;
    v_result := public.request_idea_stage_confirmation(
      v_idea_id, v_stage::smallint
    );
    IF v_result->>'outcome' <> 'requested' THEN
      RAISE EXCEPTION 'Concurrent fixture confirmation request failed: %',
        v_result;
    END IF;
    v_result := public.confirm_idea_stage(
      v_idea_id, v_stage::smallint, v_revision
    );
    IF v_result->>'outcome' <> 'confirmed' THEN
      RAISE EXCEPTION 'Concurrent fixture stage confirmation failed: %',
        v_result;
    END IF;
  END LOOP;

  v_result := public.submit_idea(
    v_idea_id, 'a9bc0000-0000-4000-8000-000000000001', v_revision
  );
  IF v_result->>'outcome' <> 'submitted' THEN
    RAISE EXCEPTION 'Concurrent dossier submission failed: %', v_result;
  END IF;
END
$m9r10_concurrency_setup$;

RESET ROLE;
COMMIT;

SELECT idea.id AS idea_id, idea.revision AS expected_revision
  FROM public.ideas AS idea
  WHERE idea.creation_request_id =
    'a9ba0000-0000-4000-8000-000000000001';
