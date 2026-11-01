# Phase 7 — Official weighted three-axis classification

## Taxonomy and result contract

Migration
`supabase/migrations/20261101140000_javaneh_thematic_classification.sql`
seeds the six official Persian axes as database-backed taxonomy version
`phase7.v1`. Stable axis IDs are `resource_efficiency`,
`domestic_production`, `economic_mutual_aid`, `social_resilience`,
`social_mobilization`, and `vulnerable_empowerment`. The database is the sole
source for names and definitions; the prompt and participant display load the
active rows rather than maintaining copies.

Every successful result has one primary and two distinct secondary axes, an
integer percentage for each, and a rationale for each selected axis. Database
constraints and server validation enforce three known active axes, a total of
100, a strictly larger primary percentage, and nonempty rationales. Optional
model confidence is stored separately from thematic percentages. The prompt is
versioned as `phase7.classification.v1`; the routed model ID and taxonomy
version are retained with each result.

## Confirmation, source revisions, and history

Stage confirmation remains the existing authenticated
`confirm_idea_stage` operation. A database trigger runs after a successful
Stage 1 or Stage 2 update. It queues classification only when both stages are
confirmed. It does not invoke AI or alter the confirmation transaction based
on provider availability. The idea workspace invokes
`POST /api/classification` after successful Stage 2 confirmation, and after a
confirmed Stage 1/2 revision is reconfirmed.

Autosaves do not invoke classification. A changed Stage 1/2 source marks the
current state stale immediately; re-confirmation queues the latest pair.
Changes to unrelated stages do not affect classification state. The browser
loads persisted work on page load. Pending work is dispatched through the same
authenticated route after a refresh; active leases are observed until expiry,
then safely reclaimed through the atomic claim RPC. Unrelated or unconfirmed
content is never dispatched.

Each Stage 1/2 confirmation receives a UUID revision reference. Existing
confirmed-stage snapshots retain the reference when the confirmed content is
superseded, allowing a result to be traced to historical source revisions
without copying idea content into classification records. Results are
append-only through application permissions. A unique logical-operation key
prevents duplicate successful results for the same idea, source revision pair,
taxonomy version, and prompt version. A separate state row identifies pending,
processing, current, stale, and failed work; stale or pending results are never
exposed as current.

## AI integration and retry behavior

Classification uses the existing server-only Vercel AI Gateway provider,
configured model routing, structured generation, input limits, and shared
provider/model circuit breaker. It does not add a provider client, health
probe, mentor quota reservation, or participant conversation record.
Classification calls use only owner-authorized persisted confirmed Stage 1 and
Stage 2 text and active database taxonomy rows. Stage 7, profile information,
draft state, and jury data are excluded.

An atomic database claim and bounded lease serialize concurrent requests. A
successful result is idempotent. Provider, schema, or database failures leave
the stage confirmation intact and persist a content-free failure category when
database controls are available. Retryable failures use server-enforced
30-second then 2-minute backoff with at most three claims for a source revision;
permanent failures are not automatically retried. Expired processing leases
can be reclaimed through the atomic claim, which replaces the attempt token so
an abandoned worker cannot complete afterward. All retries use the
authenticated endpoint and cannot accept participant-supplied axes,
percentages, rationales, or an alternative result.
Completion and failure also lock the state row and reject the attempt as stale
when its lease is at or before the database clock, even before a reclaim changes
the token.
Network failures and HTTP 408, 429, and 5xx responses also use a bounded
client-side retry to recover when a transient response occurs before a claim is
persisted. The panel makes at most three additional HTTP retries after the
initial request (four HTTP requests total per source revision during one
mount); this is separate from the database limit of three provider claims.

## Access and presentation

Participants can read the active result for their own idea and obtain a
minimal classification status through the owner-checked
`get_own_idea_classification_status` RPC. The RPC derives active/expired lease
and retry-wait status using database time; it never returns lease deadlines,
attempt counts, failure categories, or claim tokens. Participants and
`service_role` have no direct classification-state access or write privileges;
narrow security-definer RPCs owned by `javaneh_identity_executor` are callable
only by their designated roles. The current-result RLS policy uses the same
owner-checked projection, so participants do not need direct state-table
privileges to read their current result. The taxonomy is readable but not
participant-editable.

The idea workspace presents a Persian RTL, read-only section with current,
pending, stale, and unavailable states; the primary axis; both secondary axes;
percent bars; and the rationale for each. It explicitly says percentages
represent thematic relevance, not competition or gamification points. No
approval, rejection, axis editing, or percentage controls are present.
Classification has no effect on stage progression, scoring, eligibility,
submission, idea quotas, or dossier editing.

## Verification

`src/lib/ai/mentor/classification.test.ts` exercises structured output
validation and percentage distributions. The rollback-only
`supabase/tests/thematic_classification.sql` checks the exact seeded taxonomy,
idempotent seeding, stage-2 trigger boundary, constrained persistence,
idempotent/concurrent claims, retry, owner isolation, stale transitions,
unrelated-stage isolation, revision traceability, and immutable history.
Run it only as `supabase_admin` against an isolated local or dedicated test
database after applying the ordered migrations. This repository does not have
a roadmap document; the seven-stage progression and Phase 6 architecture
documents are the relevant existing baselines.
