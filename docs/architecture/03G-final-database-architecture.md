# Javaneh --- Final Database Architecture Specification (03G)

**Document ID:** JAVANEH-DB-03G\
**Status:** Approved architecture baseline; implementation and
live-environment validation pending\
**Version:** Reconstructed reference specification\
**Scope:** Initial durable idea lifecycle, authorization, transactional
persistence, idempotency, confirmed-stage snapshots, and participant
deletion\
**Related document:** `03H-deletion-audit-specification.md`

> **Provenance:** This is a reconstructed reference copy based on
> architecture decisions approved during the Javaneh design process. It
> is not a byte-for-byte copy of an earlier source file. Decisions
> identified as unresolved or unverified must not be treated as
> implemented or validated.

## 1. Purpose and boundaries

This document defines the approved initial database architecture for
Javaneh. It is the baseline for migrations, PostgreSQL functions,
authorization policies, and database tests.

Priorities: - secure ownership enforcement at the database boundary; -
transaction-safe limit of three active ideas per user; - idempotent
creation and saving; - optimistic concurrency control; - preservation of
previously confirmed stage content when edited; - permanent participant
deletion with content-free audit; - narrow, auditable privileged
execution; - minimal initial schema without premature future features.

The database is authoritative for durable product state. Client-side
checks are not sufficient for authorization, quota enforcement,
lifecycle transitions, or competitive scoring.

### 1.1 Explicitly out of scope

Do not add these in the initial package: - `idea_sessions` or a separate
session-only draft system; - AI mentor conversations/messages; -
official gamification points ledger or milestone scoring; - group
accounts, group-owned ideas, group membership, representatives,
invitations, or group-level permissions. These are permanently outside
the supported product scope; every idea has exactly one individual
authenticated account owner, while real-world collaboration outside the
platform remains permitted; - taxonomy tables or activation of the six
thematic axes; - evaluator/reviewer workflow; - final dossier storage
and 168-hour dossier revision snapshots; - Storage buckets or
asynchronous storage-cleanup workers; - appeals, ranking, tie-breaking,
or competition administration; - new product statuses or submission
workflows not approved separately.

## 2. Product rules

### 2.1 Three-active-ideas quota

A user may have at most three active ideas: - A durable `ideas` row
counts immediately, including a draft. - All non-deleted ideas count,
including `draft`, `in_progress`, and `submitted`. - Permanent deletion
releases the slot. - Enforcement is transactional in PostgreSQL, not a
client-side count followed by insert. - Creation is serialized per
owner. - Participant deletion uses the same per-owner quota
serialization to prevent create/delete races.

The quota counts durable ideas, not browser sessions.

### 2.2 Seven-stage model

1.  Problem definition
2.  Identification of social capacities
3.  Idea development and expansion
4.  Implementation plan design
5.  Initial feasibility and resilience assessment
6.  Idea dossier preparation
7.  Human review and evaluation

Stages 1--6 are participant-facing development stages. Stage 7 is human
review and judging. Stage 7 remains locked, empty, and unconfirmed in
this initial package. Do not infer an evaluator workflow or participant
confirmation behavior for Stage 7.

### 2.3 AI boundary

AI is a mentor, not a lifecycle authority. AI must not choose the final
idea, decide for the participant, confirm a stage, award official
competitive points, or perform final human evaluation. Database
functions must not grant AI calls authority to bypass participant
confirmation or human review.

### 2.4 Confirmation and editing

-   Stage confirmation is participant-controlled.
-   A confirmation request moves an eligible stage to
    `pending_confirmation`.
-   The confirmation function confirms only a pending stage and checks
    the expected idea revision.
-   Editing a currently confirmed stage first preserves its confirmed
    content as an immutable snapshot, then demotes the live stage to
    `in_progress` and clears its live `confirmed_at`.
-   Unconfirmed draft edits do not create historical snapshots.
-   Reconfirmation establishes a new current confirmation timestamp.
-   Editing an earlier confirmed stage does not automatically invalidate
    later-stage confirmations under the approved current policy. Do not
    change this without a new product decision.

### 2.5 Idea status

Initial `ideas.status` values: - `draft` - `in_progress` - `submitted`

Creation begins at `draft`. A successful content-changing save may move
it to `in_progress`. No submission function or eligibility rule is
approved in this package. The presence of `submitted` does not authorize
implementing submission.

## 3. Approved initial relational model

Exactly five initial tables:

1.  `public.ideas`
2.  `public.idea_stages`
3.  `public.idea_stage_confirmed_versions`
4.  `public.idea_deletion_audit`
5.  `public.idea_save_requests`

No `idea_sessions` table is included. A durable `ideas` row represents a
draft from creation. Reconsider a separate session table only if
independent session-only behavior is formally specified.

### 3.1 `public.ideas`

Purpose: durable idea root, ownership, and quota anchor.

  -----------------------------------------------------------------------
  Field                   Type / constraint       Purpose
  ----------------------- ----------------------- -----------------------
  `id`                    UUID primary key        Idea identifier

  `owner_id`              UUID FK to              Owner
                          `auth.users(id)` with
                          `ON DELETE CASCADE`

  `status`                Text check              `draft`, `in_progress`,
                                                  `submitted`

  `revision`              Positive integer,       Optimistic concurrency
                          starts at 1             version

  `creation_request_id`   Required UUID           Creation idempotency
                                                  key

  `created_at`            `timestamptz`           Creation time

  `updated_at`            `timestamptz`           Last successful update
  -----------------------------------------------------------------------

Required: - PK `id`; - unique `(owner_id, creation_request_id)`; -
unique `(id, owner_id)` for composite ownership references; - index
supporting owner-scoped listing/quota queries, including
`(owner_id, created_at DESC)`; - FK to `auth.users(id)` with
`ON DELETE CASCADE`; - status check restricted to the three approved
values.

Every non-deleted row counts toward the owner's quota.

### 3.2 `public.idea_stages`

Purpose: current live data and state for each stage.

  -----------------------------------------------------------------------
  Field                   Type / constraint       Purpose
  ----------------------- ----------------------- -----------------------
  `idea_id`               UUID FK to `ideas(id)`  Parent idea
                          with cascade

  `stage_number`          Smallint 1--7           Stage identifier

  `data`                  JSONB object, not null  Current stage payload

  `status`                Text check              Stage state

  `created_at`            `timestamptz`           Row creation

  `updated_at`            `timestamptz`           Last change

  `confirmed_at`          Nullable `timestamptz`  Current live
                                                  confirmation time
  -----------------------------------------------------------------------

Primary key `(idea_id, stage_number)`.

Allowed statuses: `not_started`, `in_progress`, `pending_confirmation`,
`confirmed`, `needs_revision`, `locked`.

Integrity: - `confirmed_at` is non-null iff `status = 'confirmed'`. -
`data` must be a JSON object. - Every idea has exactly seven stage
rows. - Stage 1 begins `in_progress`; stages 2--7 begin `locked`. -
Stage 7 remains locked, empty, and unconfirmed in this package. - No
partial unique index may restrict an idea to one active/unlocked
stage. - Ownership is derived through parent `ideas`; do not duplicate
`owner_id` here without a separately reviewed reason. - Ordinary
participant save operations reject Stage 7.

### 3.3 `public.idea_stage_confirmed_versions`

Purpose: immutable snapshots created only when a participant edits a
stage that is currently confirmed.

  -----------------------------------------------------------------------
  Field                   Type / constraint       Purpose
  ----------------------- ----------------------- -----------------------
  `id`                    UUID primary key        Snapshot ID

  `idea_id`               UUID                    Parent idea

  `stage_number`          Smallint 1--6           Stage

  `version_number`        Positive integer        Version within
                                                  idea/stage

  `data`                  JSONB object            Previously confirmed
                                                  payload

  `confirmed_at`          `timestamptz`           Original confirmation
                                                  time

  `superseded_at`         `timestamptz`           Time editing began

  `superseded_by`         Actor UUID or           Editing actor, subject
                          equivalent              to approved
                                                  identity/retention
                                                  semantics
  -----------------------------------------------------------------------

Required: - FK to the corresponding `idea_stages` row, cascading on
permanent idea deletion; - unique
`(idea_id, stage_number, version_number)`; - immutable after insertion;
no client-facing update/delete path; - only confirmed stages 1--6 are
eligible; - no snapshot at confirmation time; - no snapshot for
unconfirmed draft edits; - on editing a currently confirmed stage,
insert prior data and original `confirmed_at` before changing live
data; - in the same transaction demote live stage to `in_progress` and
clear live `confirmed_at`; - rollback must remove both snapshot and live
change; - reconfirmation establishes a new live confirmation; a later
edit creates the next snapshot.

These are not completed-dossier snapshots. The separate 168-hour dossier
revision policy belongs to a later product capability.

The exact actor column type and FK behavior must be finalized
consistently with account deletion. Do not invent an unapproved
retention guarantee.

### 3.4 `public.idea_deletion_audit`

Purpose: content-free evidence of permanent deletion.

  -----------------------------------------------------------------------
  Field                   Type / constraint       Purpose
  ----------------------- ----------------------- -----------------------
  `deleted_idea_id`       UUID primary key, no FK Deleted idea ID
                          to `ideas`

  `owner_id`              UUID, no FK to          Former owner
                          `auth.users`

  `actor_id`              Nullable UUID FK to     Actor if retained
                          `auth.users(id)` with
                          `ON DELETE SET NULL`

  `creation_request_id`   UUID                    Original creation key

  `deleted_at`            `timestamptz`           Deletion time

  `operation`             Check:                  Deletion path
                          `participant_delete` or
                          `account_cascade`

  `reason_code`           Content-free controlled Reason classification
                          value
  -----------------------------------------------------------------------

Required: - unique `(owner_id, creation_request_id)`; - no FK from
deleted idea ID or former owner ID back to deleted business/account
rows; - no title, description, stage content, messages, AI output, file
names, or other substantive content; - no ordinary client-facing RLS
policy or direct client write path; - audit insertion and deletion are
atomic.

Detailed trigger protocol is in 03H.

### 3.5 `public.idea_save_requests`

Purpose: technical idempotency ledger for logical content-save requests.

  -----------------------------------------------------------------------
  Field                   Type / constraint       Purpose
  ----------------------- ----------------------- -----------------------
  `id`                    UUID primary key        Ledger row

  `owner_id`              UUID                    Authenticated owner

  `idea_id`               UUID                    Target idea

  `request_id`            UUID                    Logical request key

  `expected_revision`     Integer                 Caller revision

  `payload_fingerprint`   SHA-256 digest, 32-byte Canonical request
                          or fixed hex            fingerprint
                          representation

  `result_revision`       Integer                 Result revision

  `outcome`               Check: `applied` or     Result
                          `no_op`

  `completed_at`          `timestamptz`           Completion time
  -----------------------------------------------------------------------

Required: - unique `(owner_id, request_id)`; - composite FK
`(idea_id, owner_id)` to `ideas(id, owner_id)`, cascading on idea
deletion; - metadata only; do not store stage payloads; - same key and
same fingerprint replays original result; - same key and different
fingerprint returns `idempotency_key_reuse`; - ledger is deleted with
its idea.

## 4. Role security and RLS

### 4.1 Dedicated executor

Sensitive operations execute through narrowly scoped PostgreSQL
functions owned by a dedicated role:

-   `NOLOGIN`
-   `NOBYPASSRLS`
-   not owner of application tables;
-   not assumable by `anon`, `authenticated`, `service_role`, or
    `authenticator`;
-   no broad administrative privileges;
-   only required grants.

Do not use `postgres`, `supabase_admin`, or another broad administrative
role as the general `SECURITY DEFINER` owner.

If this role cannot be safely provisioned, stop and request an explicit
security decision. Do not silently fall back to a broad role.

### 4.2 RLS requirements

All five application tables must have RLS enabled and
`FORCE ROW LEVEL SECURITY`.

Policies and grants must be narrow. Ownership must be derived through
`auth.uid()` and the parent idea relationship.

Client writes must not bypass quota, revision checks, idempotency, stage
transitions, snapshots, or deletion audit.

`idea_deletion_audit` must not expose ordinary client read/write access.
Any later administrative access requires a separate least-privilege
design.

### 4.3 SECURITY DEFINER hardening

Every privileged function must: - use `SECURITY DEFINER` only when
required; - set `search_path = pg_catalog`; - fully qualify non-catalog
objects; - verify `auth.uid()` explicitly; - reject missing/invalid
authenticated identity; - revoke execution from `PUBLIC`; - grant
execution only to intended roles; - avoid unsafe dynamic SQL; - return
controlled outcomes without leaking another user's data.

The executor must not log in or bypass RLS, and must not own the tables.

## 5. Transactions and concurrency

### 5.1 Isolation

Quota-sensitive functions explicitly require `READ COMMITTED`. Check
`current_setting('transaction_isolation')` and reject unsupported
isolation levels.

### 5.2 Quota lock

Use a transaction-scoped per-owner advisory lock derived consistently
from owner UUID, using a versioned namespace such as:

`javaneh:quota:v1:<owner_uuid>`

Create and participant-delete functions use the same lock derivation.
Count after acquiring the lock under `READ COMMITTED`, so a transaction
that waited sees the latest committed count.

### 5.3 Save lock and lock order

Save uses a transaction-scoped advisory lock derived from owner and
request UUID, with a versioned namespace such as:

`javaneh:save-request:v1:<owner_uuid>:<request_uuid>`

Required order: 1. save-request advisory lock; 2. idea row lock; 3.
affected stage rows locked in ascending `stage_number`.

The save function must perform a second ledger lookup after obtaining
the idea row lock to handle concurrent duplicate requests.

### 5.4 Server-side fingerprint

The server computes SHA-256. Never trust a client-provided digest.

Canonical envelope includes: - canonicalization version `1`; -
authenticated owner ID; - idea ID; - request ID; - expected revision; -
full `stage_updates` payload.

Approved conceptual canonicalization:

`extensions.digest(convert_to(canonical_envelope::text, 'UTF8'), 'sha256')`

Build the envelope server-side. JSONB text normalizes object key
order/whitespace; array order remains significant. Verify the exact
digest function/schema before migration execution.

### 5.5 Atomic save

One logical save is all-or-nothing: - validate full request; - verify
owner and idea state; - validate every stage and payload; - snapshot
confirmed stages where required; - update live stages; - increment idea
revision once if content changed; - write idempotency result; - commit
together.

A failure must not leave partial snapshots, stage updates, revision
increments, or successful ledger rows.

A no-op does not increment revision or change content status, but its
idempotency result is recorded.

## 6. Approved function contracts

Exact SQL parameter types and return representation must be specified
consistently in migrations and tests. The logical names and outcomes
below are approved.

### 6.1 `create_idea(p_request_id)`

1.  Resolve owner from `auth.uid()`; reject unauthenticated calls.
2.  Require `READ COMMITTED`.
3.  Acquire per-owner quota advisory lock.
4.  Check `(owner_id, creation_request_id)` for an existing idea.
5.  Check deletion tombstone for same owner/request key.
6.  Count all non-deleted ideas.
7.  Reject when count is already three.
8.  Insert `draft` idea at revision 1.
9.  Insert exactly seven stage rows.
10. Commit root and stages atomically.

Outcomes: `created`, `already_exists`, `already_deleted`,
`quota_exceeded`.

Same request key must not create a duplicate. A tombstone prevents
recreating a deleted idea with the same creation key.

### 6.2 `save_idea_content(p_idea_id, p_request_id, p_expected_revision, p_stage_updates)`

Responsibilities: 1. Resolve authenticated owner. 2. Validate request ID
and expected revision. 3. Require `READ COMMITTED`. 4. Acquire
save-request advisory lock. 5. Compute canonical server-side
fingerprint. 6. Check ledger: same key/same fingerprint replays; same
key/different fingerprint returns `idempotency_key_reuse`. 7. Lock idea
and verify ownership. 8. Perform mandatory second ledger lookup after
idea lock. 9. Reject submitted ideas. 10. Check expected revision. 11.
Require `p_stage_updates` to be a JSON array. 12. Each item has exactly
`stage_number` and `data`. 13. Reject duplicate stage numbers. 14.
Reject Stage 7, locked stages, `needs_revision`, and invalid states. 15.
Lock affected stage rows in ascending order. 16. For each confirmed
stage edited, snapshot old confirmed data/time, demote live state to
`in_progress`, clear live `confirmed_at`. 17. Move eligible
`not_started` or `pending_confirmation` stages to `in_progress`. 18.
Apply all payload changes atomically. 19. Increment idea revision
exactly once if any actual content changes. 20. Do not increment
revision for no-op. 21. Record ledger outcome and result revision. 22.
Return controlled result.

Outcomes: `applied`, `no_op`, `replayed`, `stale_revision`,
`idempotency_key_reuse`, `not_found_or_not_owned`, `invalid_state`,
`invalid_input`.

Error ordering must not reveal whether another user's idea exists.

### 6.3 `request_idea_stage_confirmation(p_idea_id, p_stage_number)`

-   authenticated owner only;
-   stages 1--6 only;
-   verify idea and stage state;
-   eligible `in_progress` -\> `pending_confirmation`;
-   repeated request while pending -\> `already_requested`;
-   no idea content revision increment;
-   AI cannot confirm.

Stage 7 is excluded.

### 6.4 `confirm_idea_stage(p_idea_id, p_stage_number, p_expected_revision)`

-   authenticated owner only;
-   stages 1--6 only;
-   lock idea then stage;
-   enforce expected revision;
-   confirm only `pending_confirmation`;
-   set `confirmed` and `confirmed_at`;
-   stages 1--5 unlock immediate successor;
-   Stage 6 does not unlock Stage 7;
-   no idea content revision increment;
-   retry at same revision may return `already_confirmed`;
-   changed revision returns `stale_revision`.

Outcomes include `confirmed`, `already_confirmed`, `stale_revision`,
`invalid_state`, `not_found_or_not_owned`.

### 6.5 `delete_own_idea(p_idea_id)`

-   authenticated owner only;
-   acquire same per-owner quota lock as creation;
-   lock and verify idea;
-   participant deletion allowed only for `draft` and `in_progress`;
-   submitted deletion is not allowed in this package;
-   establish exact transaction-local deletion context;
-   permanently delete idea and dependent data;
-   03H trigger writes exactly one `participant_delete` audit row;
-   stages, confirmed snapshots, and save ledger cascade;
-   absent, repeated, or non-owned deletion returns generic
    `not_found_or_already_deleted`;
-   audit failure aborts deletion.

### 6.6 Internal deletion trigger

The precise participant and account-cascade protocol is defined in 03H.
Unknown/unmarked deletions must be rejected, never treated as account
deletion.

## 7. Stage transition baseline

  Stage   Initial state   Confirmation                        Successor
  ------- --------------- ----------------------------------- -----------
  1       `in_progress`   Allowed when eligible and pending   2
  2       `locked`        Allowed after unlock and pending    3
  3       `locked`        Allowed after unlock and pending    4
  4       `locked`        Allowed after unlock and pending    5
  5       `locked`        Allowed after unlock and pending    6
  6       `locked`        Allowed after unlock and pending    None
  7       `locked`        Not allowed in this package         None

Previously unlocked stages remain available. Do not impose a
single-active-stage constraint.

Editing a confirmed stage revokes only that stage's live confirmation.
Later confirmations remain unchanged under the current approved policy.

`needs_revision` is part of the status vocabulary, but its actor and
complete transition semantics remain unresolved. Do not invent reviewer
workflows.

## 8. Permanent deletion and data lifecycle

Participant deletion of `draft` and `in_progress` is permanent: - delete
idea root; - cascade stage rows; - cascade confirmed snapshots; -
cascade save-request ledger rows; - retain no substantive content in
audit; - retain only content-free audit event.

Submitted deletion awaits separate policy and authorization.

Account deletion follows 03H. The `ideas.owner_id` FK uses
`ON DELETE CASCADE`, but plain cascade alone is insufficient; audit rows
must be pre-recorded and validated.

Storage objects are not part of this schema. Future file storage
requires a separately designed durable cleanup mechanism.

## 9. Migration and testing

### 9.1 Migration discipline

-   versioned, ordered Supabase SQL migrations;
-   small migrations ordered by dependency;
-   no destructive production operations during development;
-   all initial implementation and destructive tests run against
    isolated local Supabase/PostgreSQL;
-   no secrets or production connection strings in source control.

### 9.2 Required tests

**Schema:** exactly five tables; seven stages per idea; constraints;
FK/cascade; timestamp consistency; immutable snapshots.

**Quota/create:** first three succeed, fourth rejected; deletion
releases slot; concurrent create cannot exceed three; creation
idempotency; tombstone blocks reuse.

**Save:** same-key replay; changed payload key reuse rejected;
concurrent duplicate applies once; stale revision rejected; one revision
increment per changed save; no-op does not increment; failure rolls back
all effects.

**Stages:** only stages 1--6 confirm; pending-only confirmation;
expected revision; stages 1--5 unlock successors; Stage 6 does not
unlock 7; confirmed edit snapshots exactly once; unconfirmed edit no
snapshot; snapshots immutable; later confirmation not silently
invalidated.

**Security:** unauthenticated calls fail; cross-user access denied;
direct writes cannot bypass functions; executor `NOLOGIN NOBYPASSRLS`;
executor not table owner; client roles cannot assume executor or
postgres; hardened function grants/search path; no broad audit access.

**Deletion:** only draft/in-progress participant deletion; submitted
rejected; exactly one content-free audit; relational content removed;
generic repeated/absent/non-owner response; audit failure rolls back;
account-cascade tests from 03H pass.

### 9.3 Environment validation

The production project was observed as Active, PostgreSQL 17.11, region
`us-east-1`; inspected session isolation was `READ COMMITTED`; SHA-256
digest and advisory-lock functions were available. These are read-only
observations, not proof that the implementation is validated.

Local Supabase is the first test target. Production must remain
unchanged until local tests pass and managed Supabase Auth behavior is
validated in a separate isolated test project.

### 9.4 Codespaces-only local development network exception

The project owner has approved a narrowly scoped exception for real
HTTP/JWT/RLS verification against the local Supabase development stack
running inside GitHub Codespaces. This approval does not authorize use
of production Supabase, production credentials or data, or any other
environment.

For this development-only test, Kong may retain its Docker wildcard host
binding on IPv4 and IPv6, provided Codespaces port 54321 is Private.
Do not expose any Supabase port as Public or Organization. Do not change
firewall or Docker networking, and do not weaken authentication, grants,
or RLS. If Private visibility cannot be established before a test, do
not create test users or database objects.

This exception distinguishes four separate controls:

- **Docker host binding:** the wildcard binding listens on host
  interfaces; by itself it does not prove that the port is publicly
  reachable.
- **Codespaces port forwarding:** Private visibility protects the
  GitHub-forwarded endpoint by requiring the codespace creator to
  authenticate. It does not change or constrain Docker's wildcard
  binding.
- **Codespaces VM and network isolation:** GitHub documents separate
  VMs and isolated virtual networks for codespaces, with firewalls
  blocking incoming internet connections and communication between
  codespaces. The project owner accepts this documented isolation model
  as the external network boundary for this local-only test.
- **Docker bridge-network reachability:** this is a separate internal
  network boundary. Private port visibility does not prove or change
  which containers can reach one another over Docker networks.

This exception is not a claim that Private visibility alone provides
host-level isolation or that the wildcard-bound port is publicly
reachable. It applies only while the test uses local development
services, remains limited to the approved verification, and cleans up
all temporary users and database objects.

Reference: [Security in GitHub Codespaces — environment isolation and
port forwarding](https://docs.github.com/en/codespaces/reference/security-in-github-codespaces).

## 10. Unresolved decisions

Do not silently decide: 1. field-level validation for each stage; 2.
actor and transition semantics for `needs_revision`; 3. submission
eligibility and transition function; 4. whether Stage 6 is a formal
submission prerequisite; 5. Stage 7 activation and human evaluator
workflow; 6. participant visibility of confirmed-stage snapshots; 7.
submitted/in-review deletion policy; 8. audit retention and
account-deletion retention requirements; 9. final snapshot actor type/FK
semantics; 10. future Storage cleanup/outbox design; 11. future
statuses.

The suggested 700 development / 300 human assessment split out of 1,000
is not approved policy and is not a database requirement. Do not
implement a points ledger here.

The six thematic axes are not formally named/defined. Do not activate
taxonomy values until supplied by the product owner.

## 11. Acceptance gate

Accept the initial database package only when: - the five-table model
matches this specification; - dedicated executor and RLS protections
pass local tests; - quota, idempotency, concurrency, snapshots, and
deletion tests pass; - 03H account-deletion behavior passes in an
isolated Supabase test project; - no deferred product feature is
added; - no production mutation occurs during development; - migrations
and tests are reviewed before production deployment.

**Implementation status:** Not implemented. Architecture baseline
approved; local and managed-environment validation pending.
