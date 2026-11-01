# M9R11 — AI Mentor Foundation

## Architecture and boundaries

The optional mentor endpoint is `POST /api/mentor`. It uses the authenticated
Supabase SSR client and forced-RLS reads for `ideas` and `idea_stages`; the
browser cannot provide owner identity, current step, stage status, or confirmed
context. The service reads only the requested idea summary, the current stage's
status/key, and earlier confirmed stages' `data.content`. It does not read the
account record, current-stage draft data, scoring tables, or unrelated ideas.

Only stages 1–6 are eligible. The request stage key must match the database
`current_step` and generated `stage_key`; Stage 7 (`human_review`) is rejected
before provider invocation. AI output is returned as a suggestion with prompt
metadata. No AI data is saved, and the service has no write operation or access
to stage confirmation, dossier submission/edit, milestone validation, or the
official points ledger. Only content-free request-control metadata is stored;
no conversation store is added.

Stage-specific instructions are versioned as `m9r11.v1` in
`src/lib/ai/mentor/prompts/v1.ts`. Earlier participant context includes only
confirmed text, with each stage bounded to 1,800 characters and at most five
stages. The current participant message is bounded to 4,000 characters. The
prompt treats participant text as untrusted and keeps the participant's
decision-making authority explicit. Published scoring catalog rows currently
have executor-only access, so the mentor does not read or paraphrase those
criteria; it uses only the existing stage purposes and participant-provided
evidence.

## Vercel Gateway, model, and costs

The application uses the Vercel AI SDK 7 and its Gateway provider. Model ids
are Gateway-routed and configurable with `AI_MENTOR_MODEL`; the default is
`anthropic/claude-haiku-4.5`, whose live Gateway catalog entry supports
structured outputs. The catalog price checked on 2026-11-01 is $0.000001 per
input token and $0.000005 per output token ($1/M input, $5/M output). Prices and
provider availability can change; check the current [Gateway model list](https://vercel.com/ai-gateway/models).

Vercel documents AI Gateway as available on all plans with zero platform fee
and no token markup. Every team account has access to a free tier, but it covers
only a subset of models and applies per-model rate limits; Vercel's current
pricing page does not state a fixed free-credit amount. Paid-tier usage requires
AI Gateway Credits and is charged at provider list prices. Buying credits moves
the team to the paid tier and removes the monthly free credit. No credits were
purchased and no live generation was made for this implementation.

The combined system and user input is capped at 16,000 UTF-8 bytes, a
tokenizer-independent upper bound on model input size; output is capped at 600
tokens. PostgreSQL atomically limits each authenticated user to five admitted
requests in a rolling minute and reserves each `(participant_id, request_id)`
before provider invocation. A per-user transaction advisory lock serializes
concurrent reservations across serverless instances. The provider timeout is
15 seconds with at most one retry for retryable failures.

Request IDs move from `processing` to `completed` or `failed`. A duplicate
while processing returns `duplicate_in_progress`; a duplicate after success or
provider failure returns `duplicate_request`. Neither outcome calls the
provider. Failures before reservation (invalid request, failed authorization or
stage validation, missing provider configuration, or oversized input) do not
consume quota and may be retried with that ID. A provider failure after
reservation consumes quota and rejects that ID until the record expires; use a
new ID for a deliberate new attempt. If finalization fails after reservation,
the endpoint fails closed and leaves the record `processing`, so the ID remains
blocked.

The migration `supabase/migrations/20261101120000_javaneh_ai_mentor_request_controls.sql`
stores only participant ID, request UUID, timestamps, and state. It has a
composite uniqueness key, forced RLS, no direct client/service-role table
grants, and security-definer RPCs owned by `javaneh_identity_executor`. An
indexed, opportunistic cleanup runs under a separate try-advisory lock and
removes records older than 24 hours. The dedupe guarantee lasts for this
retention period; after expiry the same UUID can be admitted again. No message,
prompt, or model response is stored.

If the reservation RPC fails or returns an invalid result, the service returns
`control_unavailable` without calling the provider. If finalization fails after
a provider call, the service also returns `control_unavailable`. The same ID
remains blocked: it is still `processing` if the finish transaction did not
commit, or terminal if the transaction committed but its response was lost.
Gateway request logs provide routed provider, latency, token usage, status, and
cost. Application logs contain only provider/model, prompt version, latency,
token counts, status, and error category; they never contain participant text.
Vercel Gateway budgets are optional soft caps and are not configured by this
package.

## Configuration and deployment

- `AI_MENTOR_MODEL` is optional; when absent the default above is used.
- For local development, set `AI_GATEWAY_API_KEY` in ignored `.env.local`, or
  link the project with Vercel CLI and use `vercel env pull` for the OIDC token.
  Vercel documents local OIDC tokens as valid for 12 hours. Never prefix a
  Gateway credential with `NEXT_PUBLIC_`.
- For linked Vercel deployments, AI SDK 7 can use Vercel OIDC automatically
  when `AI_GATEWAY_API_KEY` is absent. OIDC is project-associated and avoids a
  long-lived API key. A team API key can be configured as a server-only
  alternative, but its spend is not attributed to an individual project.
- To enable the optional endpoint, configure one authentication method and
  deploy. Without credentials, mentor calls return `not_configured`; existing
  participant workflows are unaffected.
- Set any Gateway team/project/key budgets in the Vercel dashboard only after
  authorized review. This implementation does not change billing or budgets.

Database controls use the request's authenticated Supabase session. Client
supplied user IDs are never accepted; the functions derive identity from
`javaneh_private.current_uid()`. Same-ID requests from different users are
independent. Duplicate and rate-limit rejections are returned as HTTP 409 and
429 respectively; rate-limit responses include `Retry-After`.

## Validation

`npm test` exercises request/output validation, ownership and current-stage
checks, Stage 7 refusal, prompt versioning, bounded context, provider retry,
mocked cross-instance admission races, request-ID state transitions, user
isolation, rate boundaries, pre-provider failures, and database failure
behavior. `supabase/tests/ai_mentor_request_controls.sql` is rollback-only.
For real multi-session checks, use the disposable setup, two pgbench scripts,
assertions, and cleanup instructions in `supabase/README.md`. Existing M9R1–M9R10
SQL suites remain unchanged.