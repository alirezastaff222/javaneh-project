# Phase 6 — AI availability and non-AI continuation

## Provider availability and circuit policy

`POST /api/mentor` checks the configured Gateway model and reads the shared
provider/model circuit state before reserving participant request quota. An
open circuit still inside cooldown, or an active half-open probe, blocks before
quota reservation. For an eligible request, the idempotency/quota reservation
happens before the atomic database admission and any model call, so duplicate
requests cannot trigger paid recovery probes. A race that loses half-open
admission is finalized as a failed request. The circuit uses three failures within a
five-minute rolling observation window to open for 60 seconds. After the
cooldown, one caller receives a database-backed half-open lease. Other
serverless instances are blocked until that lease completes or expires after
30 seconds. Successful probes close the circuit; transient failed probes
reopen it with a bounded 120/240/300-second backoff. An expired probe lease is
also recorded as a timeout and uses that same backoff.

Timeouts, network errors, 5xx responses, and 429s count as transient. Provider
authentication, missing credentials, invalid/unsupported model, budget,
input validation, invalid model output, and application authorization errors
do not contribute to the failure count. Rate limits count toward the threshold,
but each mentor request still has at most one bounded retry. A recovery probe
has no retry and uses only the static prompt `Reply with OK.`, two output
tokens, and a 15-second timeout. It contains no participant content. No
periodic or paid availability polling is used.

The `GET /api/mentor` availability response reports only configured/not
configured and circuit readiness; it never exposes credentials or internal
provider errors. The participant UI checks once after authentication and on
explicit request. A probe runs only when a participant explicitly asks for AI help after an
expired cooldown. If the probe succeeds, that same explicit request continues;
failed requests are never automatically replayed.

The circuit-control RPCs are callable only by server-side `service_role`
credentials, use security-definer functions with a fixed search path, and
operate on forced-RLS tables accessible only to the restricted database
executor. Circuit event rows contain provider/model key, state transition,
failure category, server-generated correlation UUID, and timestamp. They
contain no participant identifier or content and are pruned after 90 days.

## Non-AI continuation

Stages 1–6 retain the existing single `idea_stages.data.content` draft, autosave,
revision controls, stage confirmation, and final submission flows. Each
participant stage now has optional stage-specific static prompts based on the
existing stage purpose. These prompts are not required fields and do not write
to the database. Mentor questions and suggestions are held only in client
memory and are not persisted. A participant can continue editing and saving
their own stage content while AI is unavailable. Stage 7 stays a locked,
human-only review.

The UI reports when AI is temporarily unavailable, provides the stage's static
guidance, keeps unsynchronized text in the existing local recovery mechanism,
and does not clear drafts, confirm stages, submit ideas, or reload the page
during recovery. AI availability is not represented in milestone validation
or the points ledger; the existing scoring functions and configured 700/300
point allocation are unchanged.

## Validation and deployment

Set `SUPABASE_SERVICE_ROLE_KEY` as a server-only environment secret for circuit
RPCs. Do not prefix it with `NEXT_PUBLIC_`. Without it, availability controls
fail closed and participants retain the non-AI workflow.

The migration is
`supabase/migrations/20261101130000_javaneh_ai_mentor_circuit_breaker.sql`.
Run its rollback-only regression test and the disposable pgbench concurrency
fixture according to `supabase/README.md`. Automated TypeScript tests cover
state-machine behavior, failure classes, the service's probe gate, and stage
guidance; they do not replace the real database concurrency run.
