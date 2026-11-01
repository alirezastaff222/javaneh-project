# Javaneh Development Milestone Evaluation Guide — Version 1.0

## Status and governance

The product owner has approved the policy content in this guide. That content
approval is distinct from the existing Scoring Administrator approval and
activation of a scoring configuration. The database records the guide as
approved content, but this migration does not attribute an approval to an
authenticated database user or create a configuration approval event.

The Version 1.0 scoring configuration and its competition remain **draft**.
The competition is not active, no participant awards can be issued under this
version, and no activation is authorized by this document. The subsequent
M9R7 product decision selects Qualitative validation for all five Stage 4
milestones; this decision does not approve or activate the operational
scoring configuration.

This guide is the canonical approved policy for the 28 development milestones
in Stages 1–6. Stage 7 jury scoring, competition activation, final ranking, and
participant-facing gamification are outside scope.

## Approved score allocation

| Stage | Name | Maximum |
|---|---|---:|
| 1 | Problem Definition | 80 |
| 2 | Identification of Social Capacities | 100 |
| 3 | Idea Development and Expansion | 140 |
| 4 | Implementation Plan Design | 140 |
| 5 | Feasibility and Resilience Assessment | 120 |
| 6 | Final Dossier Preparation | 120 |
| **Development total** | **Stages 1–6** | **700** |
| 7 | Human Review and Judging | 300 |
| **Competition total** |  | **1,000** |

Stage 7 is not a development milestone. It has no participant development
catalog entries and receives no awards from the M9R5 development scoring
operation. Jury scoring is not implemented here.

### Shared evaluation scale

These are shared descriptors for every qualitative criterion. The database
stores them once per configuration version in
`scoring_evaluation_levels`; the catalog does not copy or invent criterion-
specific Level 0–3 descriptions.

| Level | Label | Multiplier | General interpretation |
|---:|---|---:|---|
| 0 | Not achieved | 0.00 | No relevant or assessable content is available. |
| 1 | Very limited | 0.25 | Initial effort exists, but the response is incomplete, unclear, or insufficiently supported. |
| 2 | Developing | 0.50 | A meaningful part of the criterion is addressed, but significant gaps remain. |
| 3 | Satisfactory | 0.75 | The criterion is satisfactorily addressed with appropriate explanation and supporting evidence. |
| 4 | Fully achieved and supported | 1.00 | The criterion is fully addressed in a coherent, accurate, context-sensitive, and sufficiently supported manner. |

Level 4 means the criterion's expectations are met at the current development
stage; it does not mean the idea is perfect. Do not penalize participants for
not providing information that belongs to a later stage. Level 4 indicators
below are contextual guidance, not mandatory checklists. Evidence examples
are illustrative; accept equivalent evidence appropriate to a participant's
context.

For qualitative and hybrid human decisions, the existing M9R5 calculation
remains authoritative:

`Awarded points = floor(configured criterion maximum × configured numeric multiplier)`

The database uses exact PostgreSQL `numeric` arithmetic. The deterministic
floor policy, ledger identity, caps, and idempotency are unchanged.

## Stage 1 — Problem Definition (80 points)

### S1-M1 — Clarity and precision of the problem description (25 points)

**Evaluator focus:** Determine whether the social problem is clearly,
specifically, and understandably described, with a meaningful scope and a
distinction between the problem and a proposed solution.

**Level 4 indicators:** The problem is precise and understandable; its main
dimensions and scope are identifiable; the description avoids vague
generalities and does not confuse the problem with a solution.

**Evidence guidance:** Participant problem description, concrete examples,
contextual information, and distinction between the problem and its symptoms
or consequences.

### S1-M2 — Identification of populations affected by the problem (20 points)

**Evaluator focus:** Determine whether the individuals and groups directly or
indirectly affected by the problem are identified and their relationship to
the problem is explained.

**Level 4 indicators:** Main affected groups are identified; relevant
differences between groups are explained; the nature of their exposure to the
problem is clear; relevant overlooked or vulnerable groups are considered.

**Evidence guidance:** Group descriptions, examples of impact, observations,
lived experiences, and relevant demographic or social data when available.

### S1-M3 — Presentation of relevant observations, experiences, or evidence (20 points)

**Evaluator focus:** Determine whether the problem description is supported by
relevant observations, experiences, data, or evidence rather than unsupported
assumptions.

**Level 4 indicators:** Relevant evidence is clearly presented; its connection
to the problem is explained; the source and limitations of evidence are not
concealed.

**Evidence guidance:** Field observations, direct experiences, interviews,
conversations, credible statistics, reports, documents, and real examples.

### S1-M4 — Explanation of the social significance of the problem (15 points)

**Evaluator focus:** Determine whether the participant explains why the
problem matters socially and identifies its relevant consequences.

**Level 4 indicators:** Social significance is clearly explained;
consequences for people or society are identified; the connection to quality
of life, social relations, opportunities, welfare, or participation is
supported by reasoning or evidence.

**Evidence guidance:** Explanation of consequences, real examples, relevant
data, and the connection to a specific social need.

## Stage 2 — Identification of Social Capacities (100 points)

### S2-M1 — Identification of relevant people, groups, and actors (25 points)

**Evaluator focus:** Determine whether relevant individuals, groups,
institutions, and actors connected to the problem or potentially involved in
addressing it are identified.

**Level 4 indicators:** Relevant actors are identified; their roles and
relationships to the problem are explained; stakeholders and potential
contributors are distinguishable; significant actors are not overlooked.

**Evidence guidance:** Actor lists, role descriptions, stakeholder maps,
interaction experiences, and evidence of actual or potential relationships.

### S2-M2 — Identification of local assets and resources (25 points)

**Evaluator focus:** Determine whether relevant local assets and resources
that may help address the problem are identified.

**Level 4 indicators:** Relevant resources are identified; their potential
functions are explained; material and non-material capacities are considered
where relevant; access limitations are acknowledged.

**Evidence guidance:** Human skills, local facilities, indigenous knowledge,
institutional capacities, financial or technical resources, infrastructure,
and voluntary networks.

### S2-M3 — Identification of relationships, networks, and collaboration capacities (25 points)

**Evaluator focus:** Determine whether the participant understands social
relationships and networks that may enable collaboration and collective
action.

**Level 4 indicators:** Relevant networks are identified; their potential
contribution to collaboration is explained; trust, participation, and
coordination are considered where relevant; barriers to collaboration are
not ignored.

**Evidence guidance:** Existing collaborations, formal and informal networks,
inter-group relationships, collective participation experiences, and
explanations of trust or coordination capacities.

### S2-M4 — Explanation of how identified capacities relate to the problem (25 points)

**Evaluator focus:** Determine whether the participant meaningfully connects
identified social capacities to the previously defined problem.

**Level 4 indicators:** The relationship between the problem and identified
capacities is clear; the potential role of each relevant capacity is
explained; limitations are acknowledged; relationships between actors,
resources, and needs are coherent.

**Evidence guidance:** Capacity-to-problem explanations, examples of local
capacity use, actor/resource/problem maps, and collaboration opportunities.

## Stage 3 — Idea Development and Expansion (140 points)

### S3-M1 — Exploration of alternative solutions and approaches (30 points)

**Evaluator focus:** Determine whether the participant has meaningfully
explored alternative approaches before selecting the proposed direction.

**Level 4 indicators:** Relevant alternatives are considered where
appropriate; differences, advantages, and limitations are explained; the
rationale for selecting the final approach is clear.

**Evidence guidance:** Alternative approaches, comparisons, prior examples,
advantages, limitations, and selection rationale.

### S3-M2 — Alignment of the idea with the identified problem (35 points)

**Evaluator focus:** Determine whether the selected idea directly addresses
the previously identified problem and affected population.

**Level 4 indicators:** The idea responds directly to the problem; its
mechanism of impact is explained; its relationship to affected groups is
clear; it remains aligned with identified social capacities.

**Evidence guidance:** Problem-solution explanation, mechanism of change,
target-group alignment, and references to findings from earlier stages.

### S3-M3 — Innovation and added value (35 points)

**Evaluator focus:** Determine the meaningful added value of the idea
compared with existing approaches or experiences.

**Level 4 indicators:** The distinctive aspect is clear; added value is
explained in context; innovation is connected to a real social need; the
comparison with existing approaches is sufficiently grounded.

**Evidence guidance:** Comparisons with existing examples, differences in
methods or collaboration mechanisms, identified gaps, and explanations of
social added value.

### S3-M4 — Coherence and clarity of the selected idea (20 points)

**Evaluator focus:** Determine whether the selected idea has a coherent and
understandable structure.

**Level 4 indicators:** The idea is clearly described; the problem, solution,
target group, and impact mechanism are mutually consistent; its scope and
underlying logic are understandable.

**Evidence guidance:** Integrated idea description, relationship between
problem and solution, explanation of core components, and conceptual
diagrams if available.

### S3-M5 — Participant's active involvement and ownership of the idea (20 points)

**Evaluator focus:** Determine whether the participant genuinely understands
and participates in the development, selection, and refinement of the idea.

**Level 4 indicators:** The participant can explain the idea's logic, major
decisions, alternative options, and selection rationale; the participant
understands their own role and the roles of other contributors.

**Evidence guidance:** Explanations of key decisions, selection rationale,
meaningful changes, and responses to clarifying questions.

**Evaluation caution:** Do not score message count, time online, number of
edits, writing sophistication, or AI usage frequency. Use of AI, advisers, or
external resources is not inherently disqualifying; assess participant
understanding and ownership.

## Stage 4 — Implementation Plan Design (140 points)

M9R7 records the approved product decision that all five Stage 4 milestones
use Qualitative validation. No objective or structural point-awarding
mechanism is configured for Stage 4. The database still requires a separate
Scoring Administrator approval and activation before scoring can become
operational.

### S4-M1 — Definition of objectives and expected outcomes (25 points)

**Evaluator focus:** Determine whether objectives and expected outcomes are
clear and connected to the problem and proposed solution.

**Level 4 indicators:** Objectives are directly related to the problem;
expected outcomes are clear; activities, outputs, and outcomes are
distinguished where appropriate; objectives are realistic and assessable.

**Evidence guidance:** Objectives, expected outcomes, proposed indicators,
and their relationship to the target group and problem.

### S4-M2 — Design of activities and implementation steps (35 points)

**Evaluator focus:** Determine whether the idea has been translated into a
coherent set of implementation activities and steps.

**Level 4 indicators:** Main activities are identified; their sequence and
relationships are clear; each activity contributes to an objective or
expected result; important dependencies are considered.

**Evidence guidance:** Activity lists, process diagrams, implementation
steps, output relationships, and pilot plans where relevant.

### S4-M3 — Definition of roles and responsibilities (25 points)

**Evaluator focus:** Determine whether the roles and responsibilities of
people and groups involved in implementation are sufficiently clear.

**Level 4 indicators:** Main roles are identified; responsibilities are
explained; relationships between roles are clear; essential tasks have
accountable owners; significant role conflicts are considered.

**Evidence guidance:** Role lists, responsibility descriptions,
collaboration structures, responsibility matrices, and
partner/contributor explanations.

### S4-M4 — Identification of implementation resources and requirements (30 points)

**Evaluator focus:** Determine whether the participant understands the
resources and prerequisites required for implementation.

**Level 4 indicators:** Main resources are identified; their connection to
activities is clear; relevant human, financial, technical, spatial, and
institutional requirements are considered; important dependencies and access
constraints are acknowledged.

**Evidence guidance:** Resource lists, preliminary estimates, existing
capacities, external resource needs, and relevant legal, technical, or
institutional prerequisites.

### S4-M5 — Scheduling and sequencing of activities (25 points)

**Evaluator focus:** Determine whether the implementation timeline and
activity sequence are realistic and understandable.

**Level 4 indicators:** Activities have a coherent sequence; approximate
timing is identified; dependencies are considered; the schedule is
proportionate to the idea's scale and resources; important milestones or
checkpoints are identifiable.

**Evidence guidance:** Timelines, phased plans, milestones, dependencies,
and pilot/development schedules.

## Stage 5 — Feasibility and Resilience Assessment (120 points)

### S5-M1 — Identification of assumptions and limitations (25 points)

**Evaluator focus:** Determine whether the participant identifies the
assumptions underlying the idea and the limitations that may affect
implementation.

**Level 4 indicators:** Main assumptions are explicit; significant
limitations are identified; verified facts are distinguished from untested
assumptions; their implications are explained.

**Evidence guidance:** Assumption lists, prerequisites,
environmental/social/institutional/technical limitations, and unresolved
information needs.

### S5-M2 — Assessment of implementation risks and barriers (25 points)

**Evaluator focus:** Determine whether relevant implementation risks and
barriers are identified and their implications considered.

**Level 4 indicators:** Main risks are identified; probability or impact is
considered proportionately; relevant barriers are addressed; initial
responses are considered for significant risks.

**Evidence guidance:** Risk registers, probability/impact analysis,
comparable experiences, implementation barriers, and mitigation approaches.

### S5-M3 — Assessment of resource accessibility (25 points)

**Evaluator focus:** Determine whether required resources are realistically
accessible rather than merely assumed to exist.

**Level 4 indicators:** Access to main resources is clear; existing and
required resources are distinguished; external dependencies are identified;
access limitations and alternatives are considered.

**Evidence guidance:** Human, financial, and technical resource status,
partner capacities, expressions of commitment, cost estimates, and
verifiable access information.

### S5-M4 — Identification of adaptation and resilience strategies (25 points)

**Evaluator focus:** Determine whether the idea can adapt to changing
conditions, disruptions, and foreseeable constraints.

**Level 4 indicators:** Disruptive conditions are identified; adaptation
strategies are proportionate to risks; continuation or modification under
adverse conditions is considered; fragile dependencies are acknowledged.

**Evidence guidance:** Alternative scenarios, continuity plans,
reduced-dependency strategies, substitute resources, and comparable
adaptation experiences.

### S5-M5 — Revision and improvement based on feasibility analysis (20 points)

**Evaluator focus:** Determine whether feasibility findings and risk
analysis have informed meaningful decisions about the idea.

**Level 4 indicators:** Findings are reflected in design decisions;
necessary changes are made or justified; reasons for retaining or changing
components are clear; the revised idea is consistent with identified
constraints and capacities.

**Evidence guidance:** Previous/current idea comparisons, explanations of
changes, links to risks and constraints, and reasons for retaining
components.

## Stage 6 — Final Dossier Preparation (120 points)

### S6-M1 — Completeness of the dossier (30 points)

**Evaluator focus:** Determine whether the final dossier contains all
essential information required to understand and assess the idea.

**Level 4 indicators:** Essential sections are complete; the problem, social
capacities, idea, implementation plan, and feasibility are covered; relevant
earlier-stage information is included; no significant gaps or unfinished
contradictions remain.

**Evidence guidance:** Final dossier, completed stage content, essential
attachments, and supporting documents.

### S6-M2 — Coherence across dossier sections (30 points)

**Evaluator focus:** Determine whether the problem, affected groups, social
capacities, idea, implementation plan, and feasibility analysis are
logically consistent.

**Level 4 indicators:** Core sections are connected; objectives and
activities follow from the problem and idea; resources and timeline match
the implementation plan; significant contradictions are absent; relevant
revisions are reflected.

**Evidence guidance:** Cross-section consistency checks, objective/activity
alignment, resource/timeline comparison, and problem-solution coherence.

### S6-M3 — Traceability of claims and evidence (20 points)

**Evaluator focus:** Determine whether important claims and evidence in the
dossier can be traced to their sources.

**Level 4 indicators:** Important claims are linked to relevant sources or
evidence; information origins are identifiable; facts, observations,
experiences, and assumptions are distinguishable; unverified information
is not presented as established fact.

**Evidence guidance:** References, attachments, source descriptions, data
origins, observations, interviews, and stated assumptions.

### S6-M4 — Clarity and quality of presentation (20 points)

**Evaluator focus:** Determine whether the dossier can be understood by a
reader who did not participate in its development.

**Level 4 indicators:** Structure is clear; information is logically
organized; ambiguous or contradictory explanations are avoided; tables and
diagrams improve comprehension where used; the reader can understand the
problem, solution, and implementation plan.

**Evidence guidance:** Dossier text, section structure, diagrams, tables,
and attachments.

**Evaluation caution:** Do not make expensive graphic-design tools or
professional visual production a scoring advantage. Assess clarity of
communication, not design expenditure.

### S6-M5 — Participant's final review and confirmation of the dossier (20 points)

**Evaluator focus:** Determine whether the participant has knowingly
reviewed the final dossier and takes responsibility for its content.

**Level 4 indicators:** The participant has reviewed the final content;
significant inconsistencies have been resolved or explicitly addressed; the
participant can explain major decisions and confirms the dossier with
awareness of its content.

**Evidence guidance:** Final confirmation, review outcome, final
corrections, and explanations of major dossier components.

**Evaluation caution:** A button click alone is not sufficient evidence of
informed review. Do not score time online, number of reviews, or number of
edits.

## Validation-mode mapping

| Milestone group | Mode |
|---|---|
| S1-M1 through S1-M4 | Qualitative |
| S2-M1 through S2-M4 | Qualitative |
| S3-M1 through S3-M5 | Qualitative |
| S4-M1 through S4-M5 | **Pending decision: Qualitative or Hybrid** |
| S5-M1 through S5-M5 | Qualitative |
| S6-M1 | Hybrid |
| S6-M2 through S6-M4 | Qualitative |
| S6-M5 | Hybrid |

Hybrid means structural/completeness checks may be evaluated by the server
and qualitative judgment remains with an authorized human Validator. Passing
an objective check alone does not award qualitative points. For the Stage 6
hybrid criteria the configured structural check only confirms that Stage 6
data is present; the Validator still makes the human evaluation decision.
AI output is not an official evaluator and cannot create awards.

## Database representation and governance

M9R6 extends the existing `scoring_milestone_catalog` rows for the stable
Version 1.0 milestone keys. It adds `level_4_indicators` and
`evaluation_cautions`; the existing `evaluator_description`,
`evidence_guidance`, and `evaluator_instructions` columns carry the approved
focus, illustrative evidence, and shared evaluator rules. Criterion-specific
level 0–3 descriptions are not populated. Shared level labels, multipliers,
and interpretations live once in `scoring_evaluation_levels`.

The existing `catalog_version` and configuration-version references identify
the exact guide used by validation requests and awards. A later policy change
must use a new governed configuration/catalog version; it must not rewrite
historical validations, ledger rows, or the guide used for a past decision.
Guidance rows are immutable once their scoring configuration leaves draft,
under the existing catalog guard.

The guide is marked approved content using the existing descriptor status.
This expresses the product-owner approval supplied for this package; it does
not fabricate a database-user identity, approval timestamp, or
`scoring_configuration_events` row. Operational approval remains the
existing Scoring Administrator RPC and records the real authenticated actor,
time, and reason. Activation remains a separate existing governed operation.

The M9R5 award path still requires active competition/configuration,
operationally complete guidance, an active milestone, M9R4 validation
eligibility, approved human evaluation where applicable, and existing
identity/budget constraints. Guide insertion alone never awards points.
`scoring_configuration_is_ready` rejects missing or incomplete guidance and
any pending or unsupported validation mode. The M9R7 decision makes the
complete guide ready, while the Version 1.0 configuration and competition
remain draft and M9R4 continues to require operationally active scoring.
The existing immutable ledger, exact numeric floor formula, caps, award
idempotency, and compensating-entry operation remain authoritative.

No client has direct write grants to the catalog or scoring scale. Catalog
RLS remains forced and the existing restricted
`javaneh_identity_executor` performs privileged operations with fixed search
paths. The `get_milestone_evaluation_guide` RPC returns approved guidance
only to an authenticated Validator; participants and other non-Validator
users are denied. Existing RLS, ledger privacy, role boundaries, and
service-role isolation are preserved.

## Regression tests

Run the M9R6 and M9R7 rollback-only suites with the rest of the SQL regressions as
`supabase_admin` against an isolated local or dedicated test database:

```sh
psql -v ON_ERROR_STOP=1 -f supabase/tests/gamification_evaluator_guidance.sql
psql -v ON_ERROR_STOP=1 -f supabase/tests/core_database.sql
psql -v ON_ERROR_STOP=1 -f supabase/tests/gamification_foundation.sql
psql -v ON_ERROR_STOP=1 -f supabase/tests/gamification_operations.sql
psql -v ON_ERROR_STOP=1 -f supabase/tests/gamification_catalog.sql
psql -v ON_ERROR_STOP=1 -f supabase/tests/gamification_validation.sql
psql -v ON_ERROR_STOP=1 -f supabase/tests/gamification_scoring.sql
psql -v ON_ERROR_STOP=1 -f supabase/tests/gamification_stage4_qualitative_decision.sql
```

The M9R6 suite checks the exact 28 milestone identities/names/maxima,
stage/development/jury totals, shared scale, guidance completeness and
cautions, final validation modes, evaluator authorization, incomplete
guidance readiness, and unchanged draft status. The M9R7 suite checks the
approved Stage 4 modes, readiness, preserved hybrid review requirements,
allocations, guidance, and lifecycle state. Both suites roll back temporary
test changes.
