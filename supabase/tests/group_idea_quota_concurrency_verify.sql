-- Run after pgbench with two clients against the disposable setup database.
DO $verify_group_quota_race$
DECLARE
  v_group_id uuid;
  v_created integer;
  v_rejected integer;
  v_ideas integer;
BEGIN
  SELECT group_id INTO v_group_id FROM public.group_quota_race_state;
  SELECT count(*) FILTER (WHERE outcome = 'created'),
         count(*) FILTER (WHERE outcome = 'quota_exceeded')
    INTO v_created, v_rejected
    FROM public.group_quota_race_outcomes;
  SELECT count(*)::integer INTO v_ideas
    FROM public.ideas WHERE group_id = v_group_id;
  IF v_created <> 1 OR v_rejected <> 1 OR v_ideas <> 3 THEN
    RAISE EXCEPTION
      'Group quota race violated the three-idea limit: created %, rejected %, total %',
      v_created, v_rejected, v_ideas;
  END IF;
END
$verify_group_quota_race$;
