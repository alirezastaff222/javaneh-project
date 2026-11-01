-- Run only in a fresh disposable database before the pgbench probe race.
BEGIN;

CREATE TABLE public.m9r12_mentor_circuit_probe_outcomes (
  client_id integer PRIMARY KEY,
  outcome text NOT NULL,
  state text NOT NULL
);
GRANT INSERT ON public.m9r12_mentor_circuit_probe_outcomes TO service_role;

INSERT INTO public.ai_mentor_circuit_breakers (
  provider_model, state, failure_count, failure_window_started_at,
  open_count, open_until, last_outcome, updated_at
)
VALUES (
  'vercel-ai-gateway:test/concurrency-model', 'open', 3,
  pg_catalog.clock_timestamp() - INTERVAL '1 minute', 1,
  pg_catalog.clock_timestamp() - INTERVAL '1 second', 'transient_failure',
  pg_catalog.clock_timestamp()
)
ON CONFLICT (provider_model) DO UPDATE
  SET state = 'open',
      failure_count = 3,
      failure_window_started_at =
        pg_catalog.clock_timestamp() - INTERVAL '1 minute',
      open_count = 1,
      open_until = pg_catalog.clock_timestamp() - INTERVAL '1 second',
      probe_token = NULL,
      probe_started_at = NULL,
      last_outcome = 'transient_failure',
      updated_at = pg_catalog.clock_timestamp();

COMMIT;
