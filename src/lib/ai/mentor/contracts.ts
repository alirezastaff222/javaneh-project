import { z } from "zod";

export const mentorStageKeySchema = z.enum([
  "define_problem",
  "identify_social_capacities",
  "develop_ideas",
  "implementation_plan",
  "feasibility_resilience",
  "idea_dossier",
  "human_review",
]);

export const participantMentorRequestSchema = z
  .object({
    ideaId: z.string().uuid(),
    requestId: z.string().uuid(),
    stageKey: mentorStageKeySchema,
    message: z.string().trim().min(1).max(4_000),
  })
  .strict();

export const confirmedStageContextSchema = z
  .object({
    stageNumber: z.number().int().min(1).max(6),
    stageKey: mentorStageKeySchema,
    content: z.string().max(1_800),
  })
  .strict();

export const authorizedMentorContextSchema = z
  .object({
    ideaId: z.string().uuid(),
    currentStep: z.number().int().min(1).max(6),
    stageKey: mentorStageKeySchema,
    stageStatus: z.enum([
      "not_started",
      "in_progress",
      "pending_confirmation",
      "confirmed",
      "needs_revision",
    ]),
    confirmedEarlierStages: z.array(confirmedStageContextSchema).max(5),
    participantMessage: z.string().min(1).max(4_000),
  })
  .strict();

export const mentorProviderResponseSchema = z
  .object({
    message: z.string().trim().min(1).max(4_000),
    followUpQuestions: z.array(z.string().trim().min(1).max(240)).max(3),
    refusal: z.boolean(),
  })
  .strict();

export const mentorSuccessResponseSchema = z
  .object({
    ok: z.literal(true),
    suggestion: mentorProviderResponseSchema,
    metadata: z
      .object({
        provider: z.literal("google.generative-ai"),
        model: z.string().min(1).max(180),
        promptVersion: z.string().min(1).max(80),
        latencyMs: z.number().int().nonnegative(),
        inputTokens: z.number().int().nonnegative().optional(),
        outputTokens: z.number().int().nonnegative().optional(),
      })
      .strict(),
  })
  .strict();

export const mentorFailureCodeSchema = z.enum([
  "invalid_request",
  "unauthenticated",
  "idea_unavailable",
  "stage_forbidden",
  "rate_limited",
  "duplicate_in_progress",
  "duplicate_request",
  "control_unavailable",
  "not_configured",
  "input_too_large",
  "provider_timeout",
  "provider_rate_limited",
  "provider_budget_exceeded",
  "provider_unavailable",
  "circuit_open",
  "circuit_control_unavailable",
  "invalid_provider_response",
  "context_unavailable",
  "internal_error",
]);

export const mentorAvailabilityResponseSchema = z
  .object({
    status: z.enum([
      "available",
      "not_configured",
      "temporarily_unavailable",
      "recovery_eligible",
      "recovery_in_progress",
    ]),
    retryAfterSeconds: z.number().int().nonnegative().optional(),
  })
  .strict();

export type MentorAvailabilityResponse = z.infer<
  typeof mentorAvailabilityResponseSchema
>;

export const mentorFailureResponseSchema = z
  .object({
    ok: z.literal(false),
    error: z
      .object({
        code: mentorFailureCodeSchema,
        message: z.string().min(1).max(240),
      })
      .strict(),
  })
  .strict();

export type MentorStageKey = z.infer<typeof mentorStageKeySchema>;
export type ParticipantMentorRequest = z.infer<
  typeof participantMentorRequestSchema
>;
export type ConfirmedStageContext = z.infer<
  typeof confirmedStageContextSchema
>;
export type AuthorizedMentorContext = z.infer<
  typeof authorizedMentorContextSchema
>;
export type MentorProviderResponse = z.infer<
  typeof mentorProviderResponseSchema
>;
export type MentorFailureCode = z.infer<typeof mentorFailureCodeSchema>;
export type MentorSuccessResponse = z.infer<
  typeof mentorSuccessResponseSchema
>;
export type MentorFailureResponse = z.infer<
  typeof mentorFailureResponseSchema
>;