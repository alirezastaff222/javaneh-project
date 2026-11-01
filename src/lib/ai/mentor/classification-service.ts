import "server-only";

import { randomUUID } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import {
  InvalidClassificationOutputError,
  classificationModelOutputSchema,
  classificationPromptVersion,
  validateClassificationOutput,
  type ActiveClassificationAxis,
} from "./classification-contracts";
import {
  classifyCircuitFailure,
  MentorCircuitControlError,
  type MentorCircuitAdmission,
  type MentorCircuitBreaker,
} from "./circuit-breaker";
import {
  MentorProviderError,
  normalizeProviderError,
  type MentorModelProvider,
  validateMentorInputBudget,
} from "./provider";
import {
  buildClassificationSystemPrompt,
  buildClassificationUserPrompt,
} from "./prompts/classification-v1";

const claimResultSchema = z.discriminatedUnion("outcome", [
  z.object({ outcome: z.literal("claimed"), attempt_token: z.string().uuid() }).strict(),
  z.object({ outcome: z.literal("already_current") }).strict(),
  z.object({ outcome: z.literal("in_progress") }).strict(),
  z
    .object({
      outcome: z.literal("retry_wait"),
      retry_after: z.string().min(1),
    })
    .strict(),
  z.object({ outcome: z.literal("retry_exhausted") }).strict(),
  z.object({ outcome: z.literal("stale_source") }).strict(),
  z.object({ outcome: z.literal("not_found_or_not_owned") }).strict(),
  z.object({ outcome: z.literal("invalid_input") }).strict(),
]);

const operationResultSchema = z
  .object({
    outcome: z.string(),
    classification_id: z.string().uuid().optional(),
  })
  .strict();

const failResultSchema = z
  .object({ outcome: z.enum(["failed", "stale_attempt", "invalid_input"]) })
  .strict();

export type ClassificationSource = {
  ideaId: string;
  participantId: string;
  stage1: { revisionId: string; content: string };
  stage2: { revisionId: string; content: string };
  taxonomyVersion: string;
  axes: readonly ActiveClassificationAxis[];
};

export type ClassificationPersistence = {
  claim(input: {
    ideaId: string;
    participantId: string;
    stage1RevisionId: string;
    stage2RevisionId: string;
    taxonomyVersion: string;
    promptVersion: string;
    attemptToken: string;
  }): Promise<z.infer<typeof claimResultSchema>>;
  complete(input: {
    ideaId: string;
    attemptToken: string;
    taxonomyVersion: string;
    stage1RevisionId: string;
    stage2RevisionId: string;
    modelId: string;
    validated: ReturnType<typeof validateClassificationOutput>;
  }): Promise<z.infer<typeof operationResultSchema>>;
  fail(input: {
    ideaId: string;
    attemptToken: string;
    category: string;
  }): Promise<z.infer<typeof failResultSchema>>;
};

export type ClassificationServiceDependencies = {
  persistence: ClassificationPersistence;
  provider: MentorModelProvider;
  circuit: MentorCircuitBreaker;
  now?: () => number;
  sleep?: (milliseconds: number) => Promise<void>;
  timeoutMs?: number;
};

export type ClassificationServiceStatus =
  | "current"
  | "pending"
  | "processing"
  | "stale"
  | "failed";

class ClassificationServiceError extends Error {
  constructor(
    readonly category: string,
    readonly providerFailure?: ProviderFailureCategory,
  ) {
    super(category);
    this.name = "ClassificationServiceError";
  }
}

type ProviderFailureCategory =
  | "not_configured"
  | "input_too_large"
  | "timeout"
  | "network"
  | "rate_limited"
  | "budget_exceeded"
  | "authentication"
  | "invalid_response"
  | "unavailable"
  | "unknown";

function providerCategory(error: unknown): ProviderFailureCategory {
  if (error instanceof MentorProviderError) return error.category;
  return "unknown";
}

function classificationFailureCategory(error: unknown): string {
  if (error instanceof ClassificationServiceError) return error.category;
  if (error instanceof InvalidClassificationOutputError) return "invalid_response";
  if (error instanceof MentorCircuitControlError) {
    return "circuit_control_unavailable";
  }
  if (error instanceof MentorProviderError) return error.category;
  return "unknown";
}

async function generateWithBoundedRetry(
  provider: MentorModelProvider,
  input: {
    system: string;
    prompt: string;
    outputSchema: typeof classificationModelOutputSchema;
  },
  timeoutMs: number,
  allowRetry: boolean,
  sleep: (milliseconds: number) => Promise<void>,
) {
  const maxAttempts = allowRetry ? 2 : 1;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => {
        controller.abort();
        reject(new MentorProviderError("timeout", true));
      }, timeoutMs);
    });

    try {
      return await Promise.race([
        provider.generate({
          ...input,
          signal: controller.signal,
        }),
        timeout,
      ]);
    } catch (error) {
      const normalized = normalizeProviderError(error, controller.signal);
      if (!normalized.retryable || attempt + 1 === maxAttempts) {
        throw normalized;
      }
    } finally {
      if (timer) clearTimeout(timer);
    }

    await sleep(250);
  }

  throw new MentorProviderError("unavailable", true);
}

export async function classifyIdea(
  source: ClassificationSource,
  dependencies: ClassificationServiceDependencies,
): Promise<ClassificationServiceStatus> {
  if (
    source.axes.length !== 6 ||
    source.axes.some((axis) => !axis.active) ||
    !source.stage1.content.trim() ||
    !source.stage2.content.trim()
  ) {
    return "stale";
  }

  const attemptToken = randomUUID();
  let claimed = false;
  let admission: MentorCircuitAdmission | null = null;
  let circuitRecordAttempted = false;

  try {
    const claim = await dependencies.persistence.claim({
      ideaId: source.ideaId,
      participantId: source.participantId,
      stage1RevisionId: source.stage1.revisionId,
      stage2RevisionId: source.stage2.revisionId,
      taxonomyVersion: source.taxonomyVersion,
      promptVersion: classificationPromptVersion,
      attemptToken,
    });
    if (claim.outcome === "already_current") return "current";
    if (claim.outcome === "in_progress") return "processing";
    if (
      claim.outcome === "retry_wait" ||
      claim.outcome === "retry_exhausted"
    ) {
      return "failed";
    }
    if (claim.outcome === "stale_source") return "stale";
    if (claim.outcome !== "claimed") {
      throw new ClassificationServiceError("context_unavailable");
    }
    claimed = true;

    try {
      dependencies.provider.prepare?.();
    } catch (error) {
      throw new ClassificationServiceError(
        providerCategory(error),
        providerCategory(error),
      );
    }

    const providerModel =
      dependencies.provider.circuitKey?.() ?? "test:classification-provider";
    const circuitStatus = await dependencies.circuit.status(providerModel);
    if (
      circuitStatus.state === "half_open" ||
      (circuitStatus.state === "open" && !circuitStatus.recoveryEligible)
    ) {
      throw new ClassificationServiceError("circuit_open");
    }

    admission = await dependencies.circuit.admit(providerModel);
    if (admission.outcome === "blocked") {
      throw new ClassificationServiceError("circuit_open");
    }

    const generationInput = {
      system: buildClassificationSystemPrompt(),
      prompt: buildClassificationUserPrompt({
        axes: source.axes,
        stage1Content: source.stage1.content.slice(0, 1_800),
        stage2Content: source.stage2.content.slice(0, 1_800),
      }),
    };
    try {
      validateMentorInputBudget(generationInput);
    } catch (error) {
      throw new ClassificationServiceError(
        providerCategory(error),
        providerCategory(error),
      );
    }
    const generation = await generateWithBoundedRetry(
      dependencies.provider,
      {
        ...generationInput,
        outputSchema: classificationModelOutputSchema,
      },
      dependencies.timeoutMs ?? 15_000,
      admission.outcome !== "probe",
      dependencies.sleep ??
        ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))),
    );
    const validated = validateClassificationOutput(
      generation.output,
      source.axes,
    );

    circuitRecordAttempted = true;
    await dependencies.circuit.record(
      providerModel,
      admission,
      { outcome: "success" },
      attemptToken,
    );

    const completed = await dependencies.persistence.complete({
      ideaId: source.ideaId,
      attemptToken,
      taxonomyVersion: source.taxonomyVersion,
      stage1RevisionId: source.stage1.revisionId,
      stage2RevisionId: source.stage2.revisionId,
      modelId: generation.model,
      validated,
    });
    if (completed.outcome === "completed") return "current";
    if (
      completed.outcome === "stale_source" ||
      completed.outcome === "stale_attempt"
    ) {
      return "stale";
    }
    throw new ClassificationServiceError("persistence_unavailable");
  } catch (error) {
    const category = classificationFailureCategory(error);
    if (admission && !circuitRecordAttempted) {
      circuitRecordAttempted = true;
      try {
        const providerModel =
          dependencies.provider.circuitKey?.() ?? "test:classification-provider";
        const failureResult =
          error instanceof InvalidClassificationOutputError
            ? {
                outcome: "ignored_failure" as const,
                failureCategory: "invalid_response" as const,
              }
            : classifyCircuitFailure(
                error instanceof ClassificationServiceError &&
                  error.providerFailure
                  ? error.providerFailure
                  : providerCategory(error),
              );
        await dependencies.circuit.record(
          providerModel,
          admission,
          failureResult,
          attemptToken,
        );
      } catch {
        console.warn(
          JSON.stringify({
            event: "classification.circuit",
            status: "error",
            errorCategory: "circuit_control_unavailable",
          }),
        );
      }
    }

    if (claimed) {
      try {
        await dependencies.persistence.fail({
          ideaId: source.ideaId,
          attemptToken,
          category,
        });
      } catch {
        console.error(
          JSON.stringify({
            event: "classification.persistence",
            status: "error",
            errorCategory: "persistence_unavailable",
          }),
        );
      }
    }

    console.info(
      JSON.stringify({
        event: "classification.generation",
        status: "failed",
        promptVersion: classificationPromptVersion,
        errorCategory: category,
      }),
    );
    return "failed";
  }
}

export function createSupabaseClassificationPersistence(
  supabase: SupabaseClient,
): ClassificationPersistence {
  return {
    async claim(input) {
      const { data, error } = await supabase.rpc(
        "claim_idea_classification",
        {
          p_idea_id: input.ideaId,
          p_participant_id: input.participantId,
          p_stage_1_revision_id: input.stage1RevisionId,
          p_stage_2_revision_id: input.stage2RevisionId,
          p_taxonomy_version: input.taxonomyVersion,
          p_prompt_version: input.promptVersion,
          p_attempt_token: input.attemptToken,
        },
      );
      if (error) throw new ClassificationServiceError("persistence_unavailable");
      const parsed = claimResultSchema.safeParse(data);
      if (!parsed.success) {
        throw new ClassificationServiceError("persistence_unavailable");
      }
      return parsed.data;
    },
    async complete(input) {
      const { data, error } = await supabase.rpc(
        "complete_idea_classification",
        {
          p_idea_id: input.ideaId,
          p_attempt_token: input.attemptToken,
          p_taxonomy_version: input.taxonomyVersion,
          p_primary_axis_id: input.validated.primaryAxisId,
          p_secondary_axis_ids: input.validated.secondaryAxisIds,
          p_primary_percentage: input.validated.primaryPercentage,
          p_secondary_percentages: input.validated.secondaryPercentages,
          p_rationales: input.validated.rationales,
          p_confidence: input.validated.confidence ?? null,
          p_model_id: input.modelId,
          p_prompt_version: classificationPromptVersion,
          p_stage_1_revision_id: input.stage1RevisionId,
          p_stage_2_revision_id: input.stage2RevisionId,
        },
      );
      if (error) throw new ClassificationServiceError("persistence_unavailable");
      const parsed = operationResultSchema.safeParse(data);
      if (!parsed.success) {
        throw new ClassificationServiceError("persistence_unavailable");
      }
      return parsed.data;
    },
    async fail(input) {
      const { data, error } = await supabase.rpc(
        "fail_idea_classification",
        {
          p_idea_id: input.ideaId,
          p_attempt_token: input.attemptToken,
          p_failure_category: input.category,
        },
      );
      if (error) throw new ClassificationServiceError("persistence_unavailable");
      const parsed = failResultSchema.safeParse(data);
      if (!parsed.success) {
        throw new ClassificationServiceError("persistence_unavailable");
      }
      return parsed.data;
    },
  };
}
