-- Run only against an isolated local/dedicated Supabase database as supabase_admin.
-- All fixtures and mutations are rolled back when the script exits.
BEGIN;

DO $schema_contract$
BEGIN
  IF NOT pg_catalog.has_table_privilege(
       'authenticated', 'public.participant_groups', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.participant_groups', 'INSERT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.participant_group_memberships', 'SELECT'
     )
     OR pg_catalog.has_table_privilege(
       'authenticated', 'public.participant_group_invitations', 'SELECT'
     )
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', 'public.create_group_idea(uuid,uuid)', 'EXECUTE'
     )
     OR pg_catalog.has_function_privilege(
       'anon', 'public.create_group_idea(uuid,uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'Group table or RPC access is broader than intended';
  END IF;
  IF NOT pg_catalog.has_column_privilege(
       'authenticated', 'public.ideas', 'group_id', 'SELECT'
     )
     OR NOT pg_catalog.has_column_privilege(
       'authenticated', 'public.official_points_ledger', 'group_id', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'Group ownership or score attribution columns are unavailable';
  END IF;
END
$schema_contract$;

INSERT INTO auth.users (
  id, aud, role, email, encrypted_password, raw_app_meta_data,
  raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous
)
VALUES
  (
    'a8000000-0000-4000-8000-000000000101',
    'authenticated', 'authenticated', 'group-owner@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a8000000-0000-4000-8000-000000000102',
    'authenticated', 'authenticated', 'group-member@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  ),
  (
    'a8000000-0000-4000-8000-000000000103',
    'authenticated', 'authenticated', 'group-outsider@test.invalid', '',
    '{}'::jsonb, '{}'::jsonb, pg_catalog.now(), pg_catalog.now(), false, false
  );

SET LOCAL ROLE authenticated;

DO $group_lifecycle$
DECLARE
  v_owner constant uuid := 'a8000000-0000-4000-8000-000000000101';
  v_member constant uuid := 'a8000000-0000-4000-8000-000000000102';
  v_outsider constant uuid := 'a8000000-0000-4000-8000-000000000103';
  v_group uuid;
  v_invitation uuid;
  v_ideas uuid[] := ARRAY[]::uuid[];
  v_result jsonb;
  v_idea_id uuid;
  v_count integer;
  v_index integer;
BEGIN
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_owner, 'email', 'group-owner@test.invalid')::text,
    true);
  v_result := public.create_participant_group('Shared team', 'Test group');
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Group creation failed: %', v_result;
  END IF;
  v_group := (v_result->>'group_id')::uuid;

  v_result := public.create_group_invitation(v_group, 'GROUP-MEMBER@test.invalid');
  IF v_result->>'outcome' <> 'invited' THEN
    RAISE EXCEPTION 'Email invitation failed: %', v_result;
  END IF;
  v_invitation := (v_result->>'invitation_id')::uuid;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_outsider::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_outsider, 'email', 'group-outsider@test.invalid')::text,
    true);
  v_result := public.respond_to_group_invitation(v_invitation, true);
  IF v_result->>'outcome' <> 'not_found' THEN
    RAISE EXCEPTION 'Invitation was accepted by an email-mismatched account';
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_member, 'email', 'group-member@test.invalid')::text,
    true);
  v_result := public.respond_to_group_invitation(v_invitation, true);
  IF v_result->>'outcome' <> 'accepted' THEN
    RAISE EXCEPTION 'Invitation acceptance failed: %', v_result;
  END IF;

  FOR v_index IN 1..3 LOOP
    v_result := public.create_group_idea(
      v_group,
      ('a8010000-0000-4000-8000-' || pg_catalog.lpad(v_index::text, 12, '0'))::uuid
    );
    IF v_result->>'outcome' <> 'created' THEN
      RAISE EXCEPTION 'Group idea % creation failed: %', v_index, v_result;
    END IF;
    v_ideas := pg_catalog.array_append(v_ideas, (v_result->>'idea_id')::uuid);
  END LOOP;
  v_result := public.create_group_idea(
    v_group, 'a8010000-0000-4000-8000-000000000004'
  );
  IF v_result->>'outcome' <> 'quota_exceeded' THEN
    RAISE EXCEPTION 'Group quota allowed a fourth idea: %', v_result;
  END IF;

  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas WHERE id = v_ideas[1];
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Accepted group member cannot read a group idea';
  END IF;
  v_result := public.save_group_idea_content(
    v_ideas[1],
    'a8020000-0000-4000-8000-000000000001',
    1,
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'stage_number', 1,
      'data', pg_catalog.jsonb_build_object('content', 'Shared draft')
    ))
  );
  IF v_result->>'outcome' <> 'applied' THEN
    RAISE EXCEPTION 'Accepted group member could not save shared idea: %', v_result;
  END IF;
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_owner, 'email', 'group-owner@test.invalid')::text,
    true);
  v_result := public.save_idea_content(
    v_ideas[1],
    'a8020000-0000-4000-8000-000000000002',
    2,
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'stage_number', 1,
      'data', pg_catalog.jsonb_build_object('content', 'Owner-anchor bypass')
    ))
  );
  IF v_result->>'outcome' <> 'not_found_or_not_owned' THEN
    RAISE EXCEPTION 'The individual save RPC bypassed group authorization: %', v_result;
  END IF;
  v_result := public.get_participant_idea_scorecard(v_ideas[1]);
  IF v_result->>'state' <> 'unavailable'
     OR v_result->>'reason' <> 'not_found' THEN
    RAISE EXCEPTION 'The individual scorecard RPC exposed a group idea: %', v_result;
  END IF;
  v_result := public.get_own_idea_classification_status(v_ideas[1]);
  IF v_result->>'status' <> 'not_found' THEN
    RAISE EXCEPTION 'The individual classification RPC exposed a group idea: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_member, 'email', 'group-member@test.invalid')::text,
    true);
  v_result := public.get_group_idea_classification_status(v_ideas[1]);
  IF v_result->>'status' NOT IN ('missing', 'not_found') THEN
    RAISE EXCEPTION 'A group member could not read shared classification state: %', v_result;
  END IF;
  v_result := public.submit_group_idea(
    v_ideas[1],
    'a8030000-0000-4000-8000-000000000001',
    2
  );
  IF v_result->>'outcome' <> 'not_authorized' THEN
    RAISE EXCEPTION 'A non-owner was allowed to submit a group idea: %', v_result;
  END IF;
  v_result := public.delete_group_idea(v_ideas[1]);
  IF v_result->>'outcome' <> 'not_authorized' THEN
    RAISE EXCEPTION 'A non-owner was allowed to delete a group idea: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_outsider::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_outsider, 'email', 'group-outsider@test.invalid')::text,
    true);
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas WHERE id = v_ideas[1];
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'A non-member can read a group idea';
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_owner::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_owner, 'email', 'group-owner@test.invalid')::text,
    true);
  v_result := public.manage_participant_group(v_group, 'leave', NULL);
  IF v_result->>'outcome' <> 'transfer_required' THEN
    RAISE EXCEPTION 'The group owner left without transferring ownership: %', v_result;
  END IF;
  v_result := public.delete_group_idea(v_ideas[1]);
  IF v_result->>'outcome' <> 'deleted' THEN
    RAISE EXCEPTION 'The group owner could not delete an eligible idea: %', v_result;
  END IF;
  v_result := public.create_group_idea(
    v_group, 'a8010000-0000-4000-8000-000000000004'
  );
  IF v_result->>'outcome' <> 'created' THEN
    RAISE EXCEPTION 'Deleting a group idea did not release a slot: %', v_result;
  END IF;

  FOR v_index IN 1..3 LOOP
    v_result := public.create_idea(
      ('a8040000-0000-4000-8000-' || pg_catalog.lpad(v_index::text, 12, '0'))::uuid
    );
    IF v_result->>'outcome' <> 'created' THEN
      RAISE EXCEPTION 'Group ideas consumed an individual quota slot: %', v_result;
    END IF;
  END LOOP;
  v_result := public.create_idea('a8040000-0000-4000-8000-000000000004');
  IF v_result->>'outcome' <> 'quota_exceeded' THEN
    RAISE EXCEPTION 'Individual quota allowed a fourth personal idea: %', v_result;
  END IF;

  v_result := public.manage_participant_group(
    v_group, 'transfer_ownership', v_member
  );
  IF v_result->>'outcome' <> 'updated' THEN
    RAISE EXCEPTION 'Ownership transfer failed: %', v_result;
  END IF;
  v_result := public.manage_participant_group(v_group, 'leave', NULL);
  IF v_result->>'outcome' <> 'updated' THEN
    RAISE EXCEPTION 'Former owner could not leave after transfer: %', v_result;
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas WHERE id = v_ideas[2];
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'A former owner retained RLS access to a group idea';
  END IF;
  v_result := public.get_participant_published_result(v_ideas[2]);
  IF v_result->>'state' <> 'unpublished' THEN
    RAISE EXCEPTION 'A former owner read a group result through an individual RPC: %', v_result;
  END IF;

  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_member::text, true);
  PERFORM pg_catalog.set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('sub', v_member, 'email', 'group-member@test.invalid')::text,
    true);
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.ideas WHERE group_id = v_group;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'Group idea history or replacement ownership was lost in transfer';
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.participant_groups AS group_row
    WHERE group_row.id = v_group AND group_row.owner_id = v_member;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Transferred owner was not recorded';
  END IF;
END
$group_lifecycle$;

ROLLBACK;
