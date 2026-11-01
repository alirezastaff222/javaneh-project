BEGIN;

DO $prerequisite_check$
BEGIN
  IF NOT pg_catalog.pg_has_role(
       'postgres', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'anon', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'authenticated', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'service_role', 'javaneh_identity_executor', 'MEMBER'
     )
     OR pg_catalog.pg_has_role(
       'authenticator', 'javaneh_identity_executor', 'MEMBER'
     ) THEN
    RAISE EXCEPTION 'The existing identity executor prerequisite is missing or unsafe'
      USING ERRCODE = '42501';
  END IF;
END
$prerequisite_check$;

ALTER TABLE public.scoring_milestone_catalog
  DROP CONSTRAINT scoring_milestone_catalog_validation_mode_check,
  ADD CONSTRAINT scoring_milestone_catalog_validation_mode_check
    CHECK (validation_mode IS NULL
      OR validation_mode IN (
        'pending', 'qualitative', 'objective', 'hybrid'
      )),
  ADD COLUMN level_4_indicators text,
  ADD COLUMN evaluation_cautions text;

ALTER TABLE public.scoring_evaluation_levels
  ADD COLUMN general_description text;

UPDATE public.scoring_stage_catalog AS stage
  SET display_name = expected.display_name
  FROM (
    VALUES
      (1, 'Problem Definition'),
      (2, 'Identification of Social Capacities'),
      (3, 'Idea Development and Expansion'),
      (4, 'Implementation Plan Design'),
      (5, 'Feasibility and Resilience Assessment'),
      (6, 'Final Dossier Preparation'),
      (7, 'Human Review and Judging')
  ) AS expected(stage_number, display_name)
  WHERE stage.configuration_version_id = (
      SELECT version.id
        FROM public.scoring_configurations AS configuration
        JOIN public.scoring_configuration_versions AS version
          ON version.configuration_id = configuration.id
        WHERE configuration.configuration_key =
          'javaneh-approved-scoring-policy-v1'
          AND version.version_number = 1
          AND version.status = 'draft'
    )
    AND stage.stage_number = expected.stage_number;

UPDATE public.scoring_evaluation_levels AS level
  SET general_description = expected.general_description
  FROM (
    VALUES
      (0::smallint, 'No relevant or assessable content is available.'),
      (1::smallint, 'Initial effort exists, but the response is incomplete, unclear, or insufficiently supported.'),
      (2::smallint, 'A meaningful part of the criterion is addressed, but significant gaps remain.'),
      (3::smallint, 'The criterion is satisfactorily addressed with appropriate explanation and supporting evidence.'),
      (4::smallint, 'The criterion is fully addressed in a coherent, accurate, context-sensitive, and sufficiently supported manner.')
  ) AS expected(evaluation_level, general_description)
  WHERE level.evaluation_level = expected.evaluation_level
    AND EXISTS (
      SELECT 1
        FROM public.scoring_configurations AS configuration
        JOIN public.scoring_configuration_versions AS version
          ON version.configuration_id = configuration.id
        WHERE configuration.configuration_key =
          'javaneh-approved-scoring-policy-v1'
          AND version.id = level.configuration_version_id
          AND version.version_number = 1
          AND version.status = 'draft'
    );

ALTER TABLE public.scoring_evaluation_levels
  ADD CONSTRAINT scoring_evaluation_levels_general_description_nonempty
    CHECK (
      general_description IS NULL
      OR pg_catalog.length(pg_catalog.btrim(general_description)) > 0
    );

UPDATE public.scoring_milestone_catalog AS milestone
  SET display_name = guidance.display_name,
      definition = guidance.display_name,
      participant_description = guidance.display_name,
      evaluator_description = guidance.evaluator_focus,
      level_4_indicators = guidance.level_4_indicators,
      evidence_guidance = guidance.evidence_guidance,
      evaluation_cautions = guidance.evaluation_cautions,
      evaluator_instructions =
        'Apply the shared five-level evaluation scale. Level 4 means this criterion is fully met at the current stage, not that the idea is perfect. Treat Level 4 indicators as contextual guidance, not a mandatory checklist. Evidence examples are illustrative; accept equivalent evidence appropriate to the participant''s context. Do not penalize missing information that belongs to a later stage.',
      validation_mode = guidance.validation_mode,
      validation_policy = guidance.validation_policy,
      descriptor_status = 'approved'
  FROM (
    VALUES
      (
        'S1-M1', 1, 25, 'Clarity and precision of the problem description',
        'Determine whether the social problem is clearly, specifically, and understandably described, with a meaningful scope and a distinction between the problem and a proposed solution.',
        'The problem is precise and understandable; its main dimensions and scope are identifiable; the description avoids vague generalities and does not confuse the problem with a solution.',
        'Participant problem description, concrete examples, contextual information, and distinction between the problem and its symptoms or consequences.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S1-M2', 1, 20, 'Identification of populations affected by the problem',
        'Determine whether the individuals and groups directly or indirectly affected by the problem are identified and their relationship to the problem is explained.',
        'Main affected groups are identified; relevant differences between groups are explained; the nature of their exposure to the problem is clear; relevant overlooked or vulnerable groups are considered.',
        'Group descriptions, examples of impact, observations, lived experiences, and relevant demographic or social data when available.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S1-M3', 1, 20, 'Presentation of relevant observations, experiences, or evidence',
        'Determine whether the problem description is supported by relevant observations, experiences, data, or evidence rather than unsupported assumptions.',
        'Relevant evidence is clearly presented; its connection to the problem is explained; the source and limitations of evidence are not concealed.',
        'Field observations, direct experiences, interviews, conversations, credible statistics, reports, documents, and real examples.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S1-M4', 1, 15, 'Explanation of the social significance of the problem',
        'Determine whether the participant explains why the problem matters socially and identifies its relevant consequences.',
        'Social significance is clearly explained; consequences for people or society are identified; the connection to quality of life, social relations, opportunities, welfare, or participation is supported by reasoning or evidence.',
        'Explanation of consequences, real examples, relevant data, and the connection to a specific social need.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S2-M1', 2, 25, 'Identification of relevant people, groups, and actors',
        'Determine whether relevant individuals, groups, institutions, and actors connected to the problem or potentially involved in addressing it are identified.',
        'Relevant actors are identified; their roles and relationships to the problem are explained; stakeholders and potential contributors are distinguishable; significant actors are not overlooked.',
        'Actor lists, role descriptions, stakeholder maps, interaction experiences, and evidence of actual or potential relationships.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S2-M2', 2, 25, 'Identification of local assets and resources',
        'Determine whether relevant local assets and resources that may help address the problem are identified.',
        'Relevant resources are identified; their potential functions are explained; material and non-material capacities are considered where relevant; access limitations are acknowledged.',
        'Human skills, local facilities, indigenous knowledge, institutional capacities, financial or technical resources, infrastructure, and voluntary networks.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S2-M3', 2, 25, 'Identification of relationships, networks, and collaboration capacities',
        'Determine whether the participant understands social relationships and networks that may enable collaboration and collective action.',
        'Relevant networks are identified; their potential contribution to collaboration is explained; trust, participation, and coordination are considered where relevant; barriers to collaboration are not ignored.',
        'Existing collaborations, formal and informal networks, inter-group relationships, collective participation experiences, and explanations of trust or coordination capacities.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S2-M4', 2, 25, 'Explanation of how identified capacities relate to the problem',
        'Determine whether the participant meaningfully connects identified social capacities to the previously defined problem.',
        'The relationship between the problem and identified capacities is clear; the potential role of each relevant capacity is explained; limitations are acknowledged; relationships between actors, resources, and needs are coherent.',
        'Capacity-to-problem explanations, examples of local capacity use, actor/resource/problem maps, and collaboration opportunities.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S3-M1', 3, 30, 'Exploration of alternative solutions and approaches',
        'Determine whether the participant has meaningfully explored alternative approaches before selecting the proposed direction.',
        'Relevant alternatives are considered where appropriate; differences, advantages, and limitations are explained; the rationale for selecting the final approach is clear.',
        'Alternative approaches, comparisons, prior examples, advantages, limitations, and selection rationale.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S3-M2', 3, 35, 'Alignment of the idea with the identified problem',
        'Determine whether the selected idea directly addresses the previously identified problem and affected population.',
        'The idea responds directly to the problem; its mechanism of impact is explained; its relationship to affected groups is clear; it remains aligned with identified social capacities.',
        'Problem-solution explanation, mechanism of change, target-group alignment, and references to findings from earlier stages.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S3-M3', 3, 35, 'Innovation and added value',
        'Determine the meaningful added value of the idea compared with existing approaches or experiences.',
        'The distinctive aspect is clear; added value is explained in context; innovation is connected to a real social need; the comparison with existing approaches is sufficiently grounded.',
        'Comparisons with existing examples, differences in methods or collaboration mechanisms, identified gaps, and explanations of social added value.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S3-M4', 3, 20, 'Coherence and clarity of the selected idea',
        'Determine whether the selected idea has a coherent and understandable structure.',
        'The idea is clearly described; the problem, solution, target group, and impact mechanism are mutually consistent; its scope and underlying logic are understandable.',
        'Integrated idea description, relationship between problem and solution, explanation of core components, and conceptual diagrams if available.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S3-M5', 3, 20, 'Participant''s active involvement and ownership of the idea',
        'Determine whether the participant genuinely understands and participates in the development, selection, and refinement of the idea.',
        'The participant can explain the idea''s logic, major decisions, alternative options, and selection rationale; the participant understands their own role and the roles of other contributors.',
        'Explanations of key decisions, selection rationale, meaningful changes, and responses to clarifying questions.',
        'Do not score message count, time online, number of edits, writing sophistication, or AI usage frequency. Use of AI, advisers, or external resources is not inherently disqualifying; assess participant understanding and ownership.',
        'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S4-M1', 4, 25, 'Definition of objectives and expected outcomes',
        'Determine whether objectives and expected outcomes are clear and connected to the problem and proposed solution.',
        'Objectives are directly related to the problem; expected outcomes are clear; activities, outputs, and outcomes are distinguished where appropriate; objectives are realistic and assessable.',
        'Objectives, expected outcomes, proposed indicators, and their relationship to the target group and problem.',
        NULL::text, 'pending',
        '{"type":"unresolved_validation_mode","allowed_modes":["qualitative","hybrid"]}'::jsonb
      ),
      (
        'S4-M2', 4, 35, 'Design of activities and implementation steps',
        'Determine whether the idea has been translated into a coherent set of implementation activities and steps.',
        'Main activities are identified; their sequence and relationships are clear; each activity contributes to an objective or expected result; important dependencies are considered.',
        'Activity lists, process diagrams, implementation steps, output relationships, and pilot plans where relevant.',
        NULL::text, 'pending',
        '{"type":"unresolved_validation_mode","allowed_modes":["qualitative","hybrid"]}'::jsonb
      ),
      (
        'S4-M3', 4, 25, 'Definition of roles and responsibilities',
        'Determine whether the roles and responsibilities of people and groups involved in implementation are sufficiently clear.',
        'Main roles are identified; responsibilities are explained; relationships between roles are clear; essential tasks have accountable owners; significant role conflicts are considered.',
        'Role lists, responsibility descriptions, collaboration structures, responsibility matrices, and partner/contributor explanations.',
        NULL::text, 'pending',
        '{"type":"unresolved_validation_mode","allowed_modes":["qualitative","hybrid"]}'::jsonb
      ),
      (
        'S4-M4', 4, 30, 'Identification of implementation resources and requirements',
        'Determine whether the participant understands the resources and prerequisites required for implementation.',
        'Main resources are identified; their connection to activities is clear; relevant human, financial, technical, spatial, and institutional requirements are considered; important dependencies and access constraints are acknowledged.',
        'Resource lists, preliminary estimates, existing capacities, external resource needs, and relevant legal, technical, or institutional prerequisites.',
        NULL::text, 'pending',
        '{"type":"unresolved_validation_mode","allowed_modes":["qualitative","hybrid"]}'::jsonb
      ),
      (
        'S4-M5', 4, 25, 'Scheduling and sequencing of activities',
        'Determine whether the implementation timeline and activity sequence are realistic and understandable.',
        'Activities have a coherent sequence; approximate timing is identified; dependencies are considered; the schedule is proportionate to the idea''s scale and resources; important milestones or checkpoints are identifiable.',
        'Timelines, phased plans, milestones, dependencies, and pilot/development schedules.',
        NULL::text, 'pending',
        '{"type":"unresolved_validation_mode","allowed_modes":["qualitative","hybrid"]}'::jsonb
      ),
      (
        'S5-M1', 5, 25, 'Identification of assumptions and limitations',
        'Determine whether the participant identifies the assumptions underlying the idea and the limitations that may affect implementation.',
        'Main assumptions are explicit; significant limitations are identified; verified facts are distinguished from untested assumptions; their implications are explained.',
        'Assumption lists, prerequisites, environmental/social/institutional/technical limitations, and unresolved information needs.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S5-M2', 5, 25, 'Assessment of implementation risks and barriers',
        'Determine whether relevant implementation risks and barriers are identified and their implications considered.',
        'Main risks are identified; probability or impact is considered proportionately; relevant barriers are addressed; initial responses are considered for significant risks.',
        'Risk registers, probability/impact analysis, comparable experiences, implementation barriers, and mitigation approaches.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S5-M3', 5, 25, 'Assessment of resource accessibility',
        'Determine whether required resources are realistically accessible rather than merely assumed to exist.',
        'Access to main resources is clear; existing and required resources are distinguished; external dependencies are identified; access limitations and alternatives are considered.',
        'Human, financial, and technical resource status, partner capacities, expressions of commitment, cost estimates, and verifiable access information.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S5-M4', 5, 25, 'Identification of adaptation and resilience strategies',
        'Determine whether the idea can adapt to changing conditions, disruptions, and foreseeable constraints.',
        'Disruptive conditions are identified; adaptation strategies are proportionate to risks; continuation or modification under adverse conditions is considered; fragile dependencies are acknowledged.',
        'Alternative scenarios, continuity plans, reduced-dependency strategies, substitute resources, and comparable adaptation experiences.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S5-M5', 5, 20, 'Revision and improvement based on feasibility analysis',
        'Determine whether feasibility findings and risk analysis have informed meaningful decisions about the idea.',
        'Findings are reflected in design decisions; necessary changes are made or justified; reasons for retaining or changing components are clear; the revised idea is consistent with identified constraints and capacities.',
        'Previous/current idea comparisons, explanations of changes, links to risks and constraints, and reasons for retaining components.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S6-M1', 6, 30, 'Completeness of the dossier',
        'Determine whether the final dossier contains all essential information required to understand and assess the idea.',
        'Essential sections are complete; the problem, social capacities, idea, implementation plan, and feasibility are covered; relevant earlier-stage information is included; no significant gaps or unfinished contradictions remain.',
        'Final dossier, completed stage content, essential attachments, and supporting documents.',
        NULL::text, 'hybrid',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4],"objective_checks":[{"stage_number":6,"operator":"stage_data_present"}]}'::jsonb
      ),
      (
        'S6-M2', 6, 30, 'Coherence across dossier sections',
        'Determine whether the problem, affected groups, social capacities, idea, implementation plan, and feasibility analysis are logically consistent.',
        'Core sections are connected; objectives and activities follow from the problem and idea; resources and timeline match the implementation plan; significant contradictions are absent; relevant revisions are reflected.',
        'Cross-section consistency checks, objective/activity alignment, resource/timeline comparison, and problem-solution coherence.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S6-M3', 6, 20, 'Traceability of claims and evidence',
        'Determine whether important claims and evidence in the dossier can be traced to their sources.',
        'Important claims are linked to relevant sources or evidence; information origins are identifiable; facts, observations, experiences, and assumptions are distinguishable; unverified information is not presented as established fact.',
        'References, attachments, source descriptions, data origins, observations, interviews, and stated assumptions.',
        NULL::text, 'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S6-M4', 6, 20, 'Clarity and quality of presentation',
        'Determine whether the dossier can be understood by a reader who did not participate in its development.',
        'Structure is clear; information is logically organized; ambiguous or contradictory explanations are avoided; tables and diagrams improve comprehension where used; the reader can understand the problem, solution, and implementation plan.',
        'Dossier text, section structure, diagrams, tables, and attachments.',
        'Do not make expensive graphic-design tools or professional visual production a scoring advantage; assess clarity of communication, not design expenditure.',
        'qualitative',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
      ),
      (
        'S6-M5', 6, 20, 'Participant''s final review and confirmation of the dossier',
        'Determine whether the participant has knowingly reviewed the final dossier and takes responsibility for its content.',
        'The participant has reviewed the final content; significant inconsistencies have been resolved or explicitly addressed; the participant can explain major decisions and confirms the dossier with awareness of its content.',
        'Final confirmation, review outcome, final corrections, and explanations of major dossier components.',
        'A button click alone is not sufficient evidence of informed review. Do not score time online, number of reviews, or number of edits.',
        'hybrid',
        '{"type":"human_qualitative_level","levels":[0,1,2,3,4],"objective_checks":[{"stage_number":6,"operator":"stage_data_present"}]}'::jsonb
      )
  ) AS guidance(
    milestone_key, stage_number, point_value, display_name, evaluator_focus,
    level_4_indicators, evidence_guidance, evaluation_cautions,
    validation_mode, validation_policy
  )
  WHERE milestone.configuration_version_id = (
      SELECT version.id
        FROM public.scoring_configurations AS configuration
        JOIN public.scoring_configuration_versions AS version
          ON version.configuration_id = configuration.id
        WHERE configuration.configuration_key =
          'javaneh-approved-scoring-policy-v1'
          AND version.version_number = 1
          AND version.status = 'draft'
    )
    AND milestone.catalog_version = '1.0'
    AND milestone.milestone_key = guidance.milestone_key
    AND milestone.stage_number = guidance.stage_number
    AND milestone.point_value = guidance.point_value;

DO $seed_integrity_check$
DECLARE
  v_version_id uuid;
  v_count integer;
BEGIN
  SELECT version.id INTO v_version_id
    FROM public.scoring_configurations AS configuration
    JOIN public.scoring_configuration_versions AS version
      ON version.configuration_id = configuration.id
    WHERE configuration.configuration_key =
      'javaneh-approved-scoring-policy-v1'
      AND version.version_number = 1
      AND version.status = 'draft';
  IF v_version_id IS NULL THEN
    RAISE EXCEPTION 'Version 1.0 must remain draft while guidance is seeded';
  END IF;
  SELECT pg_catalog.count(*) INTO v_count
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = v_version_id
      AND milestone.catalog_version = '1.0'
      AND milestone.descriptor_status = 'approved'
      AND milestone.level_4_indicators IS NOT NULL
      AND milestone.evidence_guidance IS NOT NULL
      AND milestone.evaluator_instructions IS NOT NULL;
  IF v_count <> 28 THEN
    RAISE EXCEPTION 'Expected 28 approved evaluator guidance records, found %',
      v_count;
  END IF;
END
$seed_integrity_check$;

CREATE OR REPLACE FUNCTION public.scoring_configuration_is_ready(
  p_version_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_version public.scoring_configuration_versions%ROWTYPE;
  v_configuration_key text;
BEGIN
  SELECT version.* INTO v_version
    FROM public.scoring_configuration_versions AS version
    WHERE version.id = p_version_id;
  SELECT configuration.configuration_key INTO v_configuration_key
    FROM public.scoring_configurations AS configuration
    WHERE configuration.id = v_version.configuration_id;
  IF NOT FOUND
     OR v_version.development_max_points IS NULL
     OR v_version.human_jury_max_points IS NULL
     OR v_version.overall_max_points IS NULL
     OR v_version.overall_max_points <>
       v_version.development_max_points + v_version.human_jury_max_points
     OR v_version.rounding_policy IS DISTINCT FROM 'floor' THEN
    RETURN false;
  END IF;

  IF v_configuration_key = 'javaneh-approved-scoring-policy-v1'
     AND v_version.version_number = 1 THEN
    IF v_version.development_max_points <> 700
       OR v_version.human_jury_max_points <> 300
       OR v_version.overall_max_points <> 1000
       OR (SELECT pg_catalog.count(*)
             FROM public.scoring_stage_catalog AS stage
             WHERE stage.configuration_version_id = p_version_id) <> 7
       OR EXISTS (
         SELECT 1
           FROM (VALUES
             (1, 'Problem Definition', 80, 'development'),
             (2, 'Identification of Social Capacities', 100, 'development'),
             (3, 'Idea Development and Expansion', 140, 'development'),
             (4, 'Implementation Plan Design', 140, 'development'),
             (5, 'Feasibility and Resilience Assessment', 120, 'development'),
             (6, 'Final Dossier Preparation', 120, 'development'),
             (7, 'Human Review and Judging', 300, 'human_jury')
           ) AS expected(stage_number, display_name, maximum_points, stage_kind)
           LEFT JOIN public.scoring_stage_catalog AS stage
             ON stage.configuration_version_id = p_version_id
            AND stage.stage_number = expected.stage_number
           WHERE stage.stage_number IS NULL
              OR stage.display_name <> expected.display_name
              OR stage.maximum_points <> expected.maximum_points
              OR stage.stage_kind <> expected.stage_kind
              OR stage.sort_order <> expected.stage_number
       )
       OR (SELECT pg_catalog.count(*)
             FROM public.scoring_evaluation_levels AS level
             WHERE level.configuration_version_id = p_version_id) <> 5
       OR EXISTS (
         SELECT 1
           FROM (VALUES
             (0, 'Not achieved', 0.00::numeric, 'No relevant or assessable content is available.'),
             (1, 'Very limited', 0.25::numeric, 'Initial effort exists, but the response is incomplete, unclear, or insufficiently supported.'),
             (2, 'Developing', 0.50::numeric, 'A meaningful part of the criterion is addressed, but significant gaps remain.'),
             (3, 'Satisfactory', 0.75::numeric, 'The criterion is satisfactorily addressed with appropriate explanation and supporting evidence.'),
             (4, 'Fully achieved and supported', 1.00::numeric, 'The criterion is fully addressed in a coherent, accurate, context-sensitive, and sufficiently supported manner.')
           ) AS expected(evaluation_level, display_label, multiplier, general_description)
           LEFT JOIN public.scoring_evaluation_levels AS level
             ON level.configuration_version_id = p_version_id
            AND level.evaluation_level = expected.evaluation_level
           WHERE level.evaluation_level IS NULL
              OR level.display_label <> expected.display_label
              OR level.multiplier <> expected.multiplier
              OR level.general_description <> expected.general_description
       )
       OR (SELECT pg_catalog.count(*)
             FROM public.scoring_milestone_catalog AS milestone
             WHERE milestone.configuration_version_id = p_version_id) <> 28
       OR EXISTS (
         SELECT 1
           FROM (VALUES
             ('S1-M1', 1, 25, 'qualitative'),
             ('S1-M2', 1, 20, 'qualitative'),
             ('S1-M3', 1, 20, 'qualitative'),
             ('S1-M4', 1, 15, 'qualitative'),
             ('S2-M1', 2, 25, 'qualitative'),
             ('S2-M2', 2, 25, 'qualitative'),
             ('S2-M3', 2, 25, 'qualitative'),
             ('S2-M4', 2, 25, 'qualitative'),
             ('S3-M1', 3, 30, 'qualitative'),
             ('S3-M2', 3, 35, 'qualitative'),
             ('S3-M3', 3, 35, 'qualitative'),
             ('S3-M4', 3, 20, 'qualitative'),
             ('S3-M5', 3, 20, 'qualitative'),
             ('S4-M1', 4, 25, 'pending'),
             ('S4-M2', 4, 35, 'pending'),
             ('S4-M3', 4, 25, 'pending'),
             ('S4-M4', 4, 30, 'pending'),
             ('S4-M5', 4, 25, 'pending'),
             ('S5-M1', 5, 25, 'qualitative'),
             ('S5-M2', 5, 25, 'qualitative'),
             ('S5-M3', 5, 25, 'qualitative'),
             ('S5-M4', 5, 25, 'qualitative'),
             ('S5-M5', 5, 20, 'qualitative'),
             ('S6-M1', 6, 30, 'hybrid'),
             ('S6-M2', 6, 30, 'qualitative'),
             ('S6-M3', 6, 20, 'qualitative'),
             ('S6-M4', 6, 20, 'qualitative'),
             ('S6-M5', 6, 20, 'hybrid')
           ) AS expected(milestone_key, stage_number, point_value, validation_mode)
           LEFT JOIN public.scoring_milestone_catalog AS milestone
             ON milestone.configuration_version_id = p_version_id
            AND milestone.milestone_key = expected.milestone_key
            AND milestone.catalog_version = '1.0'
           WHERE milestone.milestone_key IS NULL
              OR milestone.stage_number <> expected.stage_number
              OR milestone.point_value <> expected.point_value
              OR (
                expected.validation_mode <> 'pending'
                AND milestone.validation_mode <> expected.validation_mode
              )
              OR (
                expected.validation_mode = 'pending'
                AND milestone.validation_mode NOT IN ('qualitative', 'hybrid')
              )
              OR milestone.catalog_status <> 'approved'
              OR milestone.descriptor_status <> 'approved'
              OR milestone.is_active
              OR milestone.evaluator_description IS NULL
              OR pg_catalog.length(pg_catalog.btrim(milestone.evaluator_description)) = 0
              OR milestone.level_4_indicators IS NULL
              OR pg_catalog.length(pg_catalog.btrim(milestone.level_4_indicators)) = 0
              OR milestone.evidence_guidance IS NULL
              OR pg_catalog.length(pg_catalog.btrim(milestone.evidence_guidance)) = 0
              OR milestone.evaluator_instructions IS NULL
              OR pg_catalog.length(pg_catalog.btrim(milestone.evaluator_instructions)) = 0
              OR milestone.level_0_description IS NOT NULL
              OR milestone.level_1_description IS NOT NULL
              OR milestone.level_2_description IS NOT NULL
              OR milestone.level_3_description IS NOT NULL
              OR milestone.level_4_description IS NOT NULL
              OR (
                expected.validation_mode = 'pending'
                AND milestone.validation_mode = 'qualitative'
                AND milestone.validation_policy IS DISTINCT FROM
                  '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
              )
              OR (
                expected.validation_mode = 'qualitative'
                AND milestone.validation_policy IS DISTINCT FROM
                  '{"type":"human_qualitative_level","levels":[0,1,2,3,4]}'::jsonb
              )
              OR (
                expected.validation_mode IN ('pending', 'hybrid')
                AND milestone.validation_mode = 'hybrid'
                AND (
                  milestone.validation_policy->>'type'
                    IS DISTINCT FROM 'human_qualitative_level'
                  OR pg_catalog.jsonb_typeof(
                    milestone.validation_policy->'objective_checks'
                  ) IS DISTINCT FROM 'array'
                  OR pg_catalog.jsonb_array_length(
                    milestone.validation_policy->'objective_checks'
                  ) = 0
                )
              )
       )
       OR EXISTS (
         SELECT 1
           FROM public.scoring_stage_catalog AS stage
           LEFT JOIN (
             SELECT milestone.stage_number,
                    pg_catalog.sum(milestone.point_value) AS points
               FROM public.scoring_milestone_catalog AS milestone
               WHERE milestone.configuration_version_id = p_version_id
               GROUP BY milestone.stage_number
           ) AS total ON total.stage_number = stage.stage_number
           WHERE stage.configuration_version_id = p_version_id
             AND stage.stage_number BETWEEN 1 AND 6
             AND total.points IS DISTINCT FROM stage.maximum_points
       )
       OR EXISTS (
         SELECT 1
           FROM public.scoring_milestone_catalog AS milestone
           WHERE milestone.configuration_version_id = p_version_id
             AND milestone.stage_number = 7
       ) THEN
      RETURN false;
    END IF;
    RETURN true;
  END IF;

  IF (SELECT pg_catalog.count(*)
        FROM public.scoring_stage_catalog AS stage
        WHERE stage.configuration_version_id = p_version_id) <> 7
     OR (SELECT COALESCE(pg_catalog.sum(stage.maximum_points), 0)
           FROM public.scoring_stage_catalog AS stage
           WHERE stage.configuration_version_id = p_version_id
             AND stage.stage_kind = 'development')
       <> v_version.development_max_points
     OR (SELECT stage.maximum_points
           FROM public.scoring_stage_catalog AS stage
           WHERE stage.configuration_version_id = p_version_id
             AND stage.stage_number = 7)
       IS DISTINCT FROM v_version.human_jury_max_points
     OR EXISTS (
       SELECT 1
         FROM public.scoring_stage_catalog AS stage
         LEFT JOIN (
           SELECT milestone.stage_number,
                  pg_catalog.sum(milestone.point_value) AS points
             FROM public.scoring_milestone_catalog AS milestone
             WHERE milestone.configuration_version_id = p_version_id
             GROUP BY milestone.stage_number
         ) AS total ON total.stage_number = stage.stage_number
         WHERE stage.configuration_version_id = p_version_id
           AND (
             (stage.stage_number = 7 AND total.points IS NOT NULL)
             OR (stage.stage_number BETWEEN 1 AND 6
                 AND COALESCE(total.points, 0) <> stage.maximum_points)
           )
     )
     OR EXISTS (
       SELECT 1
         FROM public.scoring_milestone_catalog AS milestone
         WHERE milestone.configuration_version_id = p_version_id
           AND (
             milestone.stage_number NOT BETWEEN 1 AND 6
             OR milestone.validation_mode NOT IN (
               'qualitative', 'objective', 'hybrid'
             )
             OR milestone.validation_policy IS NULL
             OR milestone.catalog_status <> 'approved'
             OR milestone.descriptor_status <> 'approved'
             OR milestone.is_active
             OR milestone.evaluator_instructions IS NULL
             OR (
               milestone.validation_mode = 'qualitative'
               AND (
                 milestone.level_0_description IS NULL
                 OR milestone.level_1_description IS NULL
                 OR milestone.level_2_description IS NULL
                 OR milestone.level_3_description IS NULL
                 OR milestone.level_4_description IS NULL
                 OR milestone.evidence_guidance IS NULL
               )
             )
           )
     ) THEN
    RETURN false;
  END IF;
  RETURN EXISTS (
    SELECT 1
      FROM public.scoring_milestone_catalog AS milestone
      WHERE milestone.configuration_version_id = p_version_id
  );
END
$function$;
ALTER FUNCTION public.scoring_configuration_is_ready(uuid)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.scoring_configuration_is_ready(uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.milestone_validation_is_operational(
  p_configuration_version_id uuid,
  p_milestone_key text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM public.scoring_configuration_versions AS version
      JOIN public.scoring_milestone_catalog AS milestone
        ON milestone.configuration_version_id = version.id
      JOIN public.competitions AS competition
        ON competition.scoring_configuration_version_id = version.id
      WHERE version.id = p_configuration_version_id
        AND version.status = 'active'
        AND version.approved_by IS NOT NULL
        AND version.approved_at IS NOT NULL
        AND version.activated_at IS NOT NULL
        AND competition.status = 'active'
        AND milestone.milestone_key = p_milestone_key
        AND milestone.stage_number BETWEEN 1 AND 6
        AND milestone.is_active
        AND milestone.catalog_status = 'active'
        AND milestone.descriptor_status = 'approved'
        AND milestone.validation_mode IN (
          'qualitative', 'objective', 'hybrid'
        )
        AND milestone.validation_policy IS NOT NULL
        AND milestone.evidence_guidance IS NOT NULL
        AND pg_catalog.length(pg_catalog.btrim(milestone.evidence_guidance)) > 0
        AND milestone.evaluator_description IS NOT NULL
        AND pg_catalog.length(pg_catalog.btrim(milestone.evaluator_description)) > 0
        AND milestone.evaluator_instructions IS NOT NULL
        AND pg_catalog.length(pg_catalog.btrim(milestone.evaluator_instructions)) > 0
        AND (
          (
            milestone.catalog_version = '1.0'
            AND milestone.level_4_indicators IS NOT NULL
            AND pg_catalog.length(
              pg_catalog.btrim(milestone.level_4_indicators)
            ) > 0
            AND milestone.level_0_description IS NULL
            AND milestone.level_1_description IS NULL
            AND milestone.level_2_description IS NULL
            AND milestone.level_3_description IS NULL
            AND milestone.level_4_description IS NULL
            AND (
              SELECT pg_catalog.count(*)
                FROM public.scoring_evaluation_levels AS level
                WHERE level.configuration_version_id = version.id
                  AND level.general_description IS NOT NULL
            ) = 5
          )
          OR (
            milestone.catalog_version IS DISTINCT FROM '1.0'
            AND (
              milestone.validation_mode = 'objective'
              OR (
                milestone.level_0_description IS NOT NULL
                AND milestone.level_1_description IS NOT NULL
                AND milestone.level_2_description IS NOT NULL
                AND milestone.level_3_description IS NOT NULL
                AND milestone.level_4_description IS NOT NULL
                AND (SELECT pg_catalog.count(*)
                       FROM public.scoring_evaluation_levels AS level
                       WHERE level.configuration_version_id = version.id) = 5
              )
            )
          )
        )
        AND (
          milestone.validation_mode = 'qualitative'
          OR (
            pg_catalog.jsonb_typeof(
              milestone.validation_policy->'objective_checks'
            ) = 'array'
            AND pg_catalog.jsonb_array_length(
              milestone.validation_policy->'objective_checks'
            ) > 0
          )
        )
  )
$function$;
ALTER FUNCTION public.milestone_validation_is_operational(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.milestone_validation_is_operational(uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.evaluate_milestone_objective_policy(
  p_idea_id uuid,
  p_configuration_version_id uuid,
  p_milestone_key text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_milestone public.scoring_milestone_catalog%ROWTYPE;
  v_check jsonb;
  v_index bigint;
  v_stage_number smallint;
  v_path text[];
  v_actual jsonb;
  v_passed boolean;
  v_all_passed boolean := true;
  v_results jsonb := '[]'::jsonb;
BEGIN
  SELECT milestone.* INTO v_milestone
    FROM public.scoring_milestone_catalog AS milestone
    WHERE milestone.configuration_version_id = p_configuration_version_id
      AND milestone.milestone_key = p_milestone_key;
  IF NOT FOUND
     OR v_milestone.validation_mode NOT IN ('objective', 'hybrid')
     OR pg_catalog.jsonb_typeof(
       v_milestone.validation_policy->'objective_checks'
     ) IS DISTINCT FROM 'array'
     OR pg_catalog.jsonb_array_length(
       v_milestone.validation_policy->'objective_checks'
     ) = 0 THEN
    RETURN '{"configured":false,"passed":false,"checks":[]}'::jsonb;
  END IF;

  FOR v_check, v_index IN
    SELECT item.value, item.ordinality
      FROM pg_catalog.jsonb_array_elements(
        v_milestone.validation_policy->'objective_checks'
      ) WITH ORDINALITY AS item(value, ordinality)
  LOOP
    IF pg_catalog.jsonb_typeof(v_check) IS DISTINCT FROM 'object'
       OR pg_catalog.jsonb_typeof(v_check->'stage_number') IS DISTINCT FROM 'number'
       OR (v_check->>'stage_number') !~ '^[1-6]$'
       OR pg_catalog.jsonb_typeof(v_check->'operator') IS DISTINCT FROM 'string' THEN
      RETURN '{"configured":false,"passed":false,"checks":[]}'::jsonb;
    END IF;

    v_stage_number := (v_check->>'stage_number')::smallint;
    IF v_check->>'operator' = 'stage_data_present' THEN
      IF v_check ? 'path' OR v_check ? 'value' THEN
        RETURN '{"configured":false,"passed":false,"checks":[]}'::jsonb;
      END IF;
      SELECT stage.data INTO v_actual
        FROM public.idea_stages AS stage
        WHERE stage.idea_id = p_idea_id
          AND stage.stage_number = v_stage_number;
      v_passed := pg_catalog.jsonb_typeof(v_actual) = 'object'
        AND EXISTS (SELECT 1 FROM pg_catalog.jsonb_each(v_actual));
    ELSE
      IF v_check->>'operator' NOT IN ('present', 'equals')
         OR pg_catalog.jsonb_typeof(v_check->'path') IS DISTINCT FROM 'array'
         OR pg_catalog.jsonb_array_length(v_check->'path') = 0
         OR (v_check->>'operator' = 'equals' AND NOT (v_check ? 'value'))
         OR EXISTS (
           SELECT 1
             FROM pg_catalog.jsonb_array_elements(v_check->'path') AS path_item(value)
             WHERE pg_catalog.jsonb_typeof(path_item.value) <> 'string'
         ) THEN
        RETURN '{"configured":false,"passed":false,"checks":[]}'::jsonb;
      END IF;
      SELECT pg_catalog.array_agg(path_item.value #>> '{}')
        INTO v_path
        FROM pg_catalog.jsonb_array_elements(v_check->'path') AS path_item(value);
      SELECT pg_catalog.jsonb_extract_path(stage.data, VARIADIC v_path)
        INTO v_actual
        FROM public.idea_stages AS stage
        WHERE stage.idea_id = p_idea_id
          AND stage.stage_number = v_stage_number;
      IF v_check->>'operator' = 'equals' THEN
        v_passed := v_actual IS NOT DISTINCT FROM v_check->'value';
      ELSE
        v_passed := v_actual IS NOT NULL AND v_actual <> 'null'::jsonb
          AND CASE pg_catalog.jsonb_typeof(v_actual)
            WHEN 'string' THEN pg_catalog.length(pg_catalog.btrim(v_actual #>> '{}')) > 0
            WHEN 'array' THEN pg_catalog.jsonb_array_length(v_actual) > 0
            WHEN 'object' THEN EXISTS (
              SELECT 1 FROM pg_catalog.jsonb_each(v_actual)
            )
            ELSE true
          END;
      END IF;
    END IF;

    v_all_passed := v_all_passed AND v_passed;
    v_results := v_results || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'check', v_index,
        'stage_number', v_stage_number,
        'passed', v_passed
      )
    );
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'configured', true,
    'passed', v_all_passed,
    'checks', v_results
  );
END
$function$;
ALTER FUNCTION public.evaluate_milestone_objective_policy(uuid, uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.evaluate_milestone_objective_policy(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_milestone_evaluation_guide(
  p_configuration_version_id uuid,
  p_milestone_key text
)
RETURNS TABLE (
  milestone_key text,
  catalog_version text,
  display_name text,
  maximum_points integer,
  evaluator_focus text,
  level_4_indicators text,
  evidence_guidance text,
  evaluation_cautions text,
  evaluator_instructions text,
  validation_mode text,
  evaluation_scale jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog
AS $function$
DECLARE
  v_actor_id uuid;
BEGIN
  v_actor_id := javaneh_private.current_uid();
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'javaneh:authorization:v1:' || v_actor_id::text, 0
    )
  );
  IF NOT EXISTS (
    SELECT 1
      FROM public.scoring_role_assignments AS assignment
      WHERE assignment.user_id = v_actor_id
        AND assignment.role_name = 'validator'
  ) THEN
    RAISE EXCEPTION 'Validator authorization required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT milestone.milestone_key, milestone.catalog_version,
    milestone.display_name, milestone.point_value,
    milestone.evaluator_description, milestone.level_4_indicators,
    milestone.evidence_guidance, milestone.evaluation_cautions,
    milestone.evaluator_instructions, milestone.validation_mode,
    (
      SELECT pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'level', level.evaluation_level,
          'label', level.display_label,
          'multiplier', level.multiplier,
          'description', level.general_description
        )
        ORDER BY level.evaluation_level
      )
      FROM public.scoring_evaluation_levels AS level
      WHERE level.configuration_version_id = milestone.configuration_version_id
    )
  FROM public.scoring_milestone_catalog AS milestone
  WHERE milestone.configuration_version_id = p_configuration_version_id
    AND milestone.milestone_key = p_milestone_key
    AND milestone.catalog_version = '1.0'
    AND milestone.descriptor_status = 'approved'
    AND milestone.catalog_status IN ('approved', 'active');
END
$function$;
ALTER FUNCTION public.get_milestone_evaluation_guide(uuid, text)
  OWNER TO javaneh_identity_executor;
REVOKE ALL ON FUNCTION public.get_milestone_evaluation_guide(uuid, text)
  FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_milestone_evaluation_guide(uuid, text)
  TO authenticated;

COMMENT ON COLUMN public.scoring_milestone_catalog.level_4_indicators IS
  'Approved criterion-specific Level 4 indicators; contextual guidance, not a mandatory checklist.';
COMMENT ON COLUMN public.scoring_milestone_catalog.evaluation_cautions IS
  'Approved criterion-specific fairness cautions; NULL when the guide specifies none.';
COMMENT ON COLUMN public.scoring_milestone_catalog.catalog_version IS
  'Immutable catalog and evaluator-guidance version used by validation and awards.';
COMMENT ON COLUMN public.scoring_evaluation_levels.general_description IS
  'Shared approved interpretation for this evaluation level, not a criterion-specific descriptor.';
COMMENT ON COLUMN public.scoring_milestone_catalog.descriptor_status IS
  'Approval state of evaluator guidance content; independent from operational scoring-configuration approval and activation.';

COMMIT;
