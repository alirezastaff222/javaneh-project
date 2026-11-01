-- Run only against the disposable database used by the concurrency fixture.
DROP TABLE public.m9r12_mentor_circuit_probe_outcomes;
DELETE FROM public.ai_mentor_circuit_events
  WHERE provider_model = 'vercel-ai-gateway:test/concurrency-model';
DELETE FROM public.ai_mentor_circuit_breakers
  WHERE provider_model = 'vercel-ai-gateway:test/concurrency-model';
