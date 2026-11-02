import { z } from "zod";

const uuid = z.string().uuid();
const status = z.enum([
  "not_submitted",
  "pending_validation",
  "validated",
  "needs_revision",
  "rejected",
]);

export const participantMilestoneEvaluationSchema = z.object({
  milestone_key: z.string().min(1),
  stage_number: z.number().int().min(1).max(6),
  name: z.string().min(1),
  criteria: z.string().min(1),
  validation_mode: z.enum(["objective", "qualitative", "hybrid"]),
  status,
  request_id: uuid.nullable(),
  objective_passed: z.boolean().nullable(),
  objective_result: z.record(z.string(), z.unknown()).nullable(),
  feedback: z.string().nullable(),
  evaluation_level: z.number().int().min(0).max(4).nullable(),
  submitted_at: z.string().nullable(),
  updated_at: z.string().nullable(),
});

export const participantMilestoneEvaluationsSchema = z.discriminatedUnion("state", [
  z.object({
    state: z.literal("unavailable"),
    reason: z.string(),
  }),
  z.object({
    state: z.literal("available"),
    idea_revision: z.number().int().positive(),
    configuration_version_id: uuid,
    catalog_version: z.string().min(1),
    milestones: z.array(participantMilestoneEvaluationSchema).length(28),
  }),
]);

export type ParticipantMilestoneEvaluations = z.infer<
  typeof participantMilestoneEvaluationsSchema
>;

export type RpcClient = {
  rpc: (
    name: string,
    args?: Record<string, unknown>,
  ) => PromiseLike<{ data: unknown; error: { code?: string; message?: string } | null }>;
};

export async function getParticipantMilestoneEvaluations(
  supabase: RpcClient,
  ideaId: string,
) {
  return supabase.rpc("get_participant_milestone_evaluations", {
    p_idea_id: ideaId,
  });
}

export async function submitMilestoneForValidation(
  supabase: RpcClient,
  input: {
    ideaId: string;
    configurationVersionId: string;
    milestoneKey: string;
    expectedRevision: number;
  },
) {
  return supabase.rpc("submit_milestone_for_validation", {
    p_idea_id: input.ideaId,
    p_configuration_version_id: input.configurationVersionId,
    p_milestone_key: input.milestoneKey,
    p_expected_revision: input.expectedRevision,
  });
}

export async function getMilestoneValidationQueue(supabase: RpcClient) {
  return supabase.rpc("get_milestone_validation_queue", {});
}

export async function validateMilestoneRequest(
  supabase: RpcClient,
  input: {
    requestId: string;
    outcome: "validated" | "needs_revision" | "rejected";
    evaluationLevel: number;
    reason: string;
  },
) {
  return supabase.rpc("validate_milestone_request", {
    p_request_id: input.requestId,
    p_outcome: input.outcome,
    p_evaluation_level: input.evaluationLevel,
    p_reason: input.reason,
  });
}
