BEGIN;

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

CREATE FUNCTION public.award_validated_milestone_request()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
BEGIN
  IF OLD.status IS DISTINCT FROM 'validated'
     AND NEW.status = 'validated' THEN
    PERFORM public.award_validated_milestone(NEW.request_id);
  END IF;
  RETURN NEW;
END
$function$;

ALTER FUNCTION public.award_validated_milestone_request()
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.award_validated_milestone_request()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER milestone_validation_request_award
  AFTER UPDATE OF status ON public.milestone_validation_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.award_validated_milestone_request();

COMMENT ON FUNCTION public.award_validated_milestone_request() IS
  'Connects successful milestone validation transitions to the authoritative idempotent points award RPC.';

REVOKE CREATE ON SCHEMA public FROM javaneh_identity_executor;

COMMIT;
