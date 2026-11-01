import { z } from "zod";

const validUuid = z.string().trim().uuid();
const assignmentSchema = z
  .object({
    idea_id: validUuid,
    status: z.enum(["awaiting_review", "in_progress", "completed"]),
    assigned_at: z.string().nullable(),
    started_at: z.string().nullable(),
    completed_at: z.string().nullable(),
    submitted_at: z.string().nullable(),
    current_step: z.number().int().min(1).max(7),
  })
  .strict();

export type EvaluatorAssignment = z.infer<typeof assignmentSchema>;

export type AssignmentLoadState =
  | { kind: "loaded"; items: EvaluatorAssignment[] }
  | { kind: "empty"; items: [] }
  | { kind: "error" };

export function parseAssignedIdeas(
  data: unknown,
  error: unknown,
): AssignmentLoadState {
  if (error || typeof data !== "object" || data === null) {
    return { kind: "error" };
  }
  const parsed = z
    .object({
      outcome: z.literal("available"),
      items: z.array(assignmentSchema),
    })
    .strict()
    .safeParse(data);
  if (!parsed.success) return { kind: "error" };
  return parsed.data.items.length === 0
    ? { kind: "empty", items: [] }
    : { kind: "loaded", items: parsed.data.items };
}

const dossierStageSchema = z
  .object({
    stage_number: z.number().int().min(1).max(6),
    stage_key: z.string(),
    data: z.record(z.string(), z.unknown()),
    confirmed_at: z.string().nullable(),
  })
  .strict();

const assignedDossierSchema = z
  .object({
    outcome: z.literal("available"),
    revision: z.number().int().positive(),
    dossier: z
      .object({
        stages: z.array(dossierStageSchema).length(6),
      })
      .strict(),
  })
  .strict()
  .refine(({ dossier }) =>
    dossier.stages.every((stage, index) => stage.stage_number === index + 1),
  );

export type AssignedDossier = z.infer<typeof assignedDossierSchema>;

export function parseAssignedDossier(value: unknown) {
  return assignedDossierSchema.safeParse(value);
}

export function parseIdeaIdBody(body: unknown) {
  return z
    .object({
      ideaId: validUuid,
    })
    .strict()
    .safeParse(body);
}

type RpcResponse = {
  data: unknown;
  error: { code?: string; message?: string } | null;
};

type RpcClient = {
  rpc: (
    name: string,
    args?: Record<string, unknown>,
  ) => PromiseLike<unknown> | unknown;
};

export async function getAssignedIdeas(supabase: RpcClient) {
  const response = (await supabase.rpc(
    "get_own_assigned_idea_evaluations",
    {},
  )) as RpcResponse;
  return { data: response.data, error: response.error };
}

export async function getAssignedDossier(
  supabase: RpcClient,
  ideaId: string,
) {
  const response = (await supabase.rpc(
    "get_assigned_idea_evaluation_dossier",
    { p_idea_id: ideaId },
  )) as RpcResponse;
  return { data: response.data, error: response.error };
}

export async function startIdeaEvaluation(
  supabase: RpcClient,
  ideaId: string,
) {
  const response = (await supabase.rpc("start_idea_evaluation", {
    p_idea_id: ideaId,
  })) as RpcResponse;
  return { data: response.data, error: response.error };
}

export async function completeIdeaEvaluation(
  supabase: RpcClient,
  ideaId: string,
) {
  const response = (await supabase.rpc("complete_idea_evaluation", {
    p_idea_id: ideaId,
  })) as RpcResponse;
  return { data: response.data, error: response.error };
}

export function mapEvaluationError(error: { code?: string; message?: string } | null) {
  if (!error) return null;
  if (error.code === "42501") return { status: 403, error: "Forbidden." };
  if (error.code === "23514") return { status: 400, error: "Invalid input." };
  return { status: 500, error: "The evaluation action could not be completed." };
}
