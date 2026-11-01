-- Run after verifying the two-client pgbench outcomes in the disposable DB.
BEGIN;
DELETE FROM auth.users
  WHERE id IN (
    'a9b21000-0000-4000-8000-000000000001',
    'a9b21000-0000-4000-8000-000000000002'
  );
DROP TABLE public.m9r11_mentor_request_outcomes;
COMMIT;