import "server-only";

import { randomUUID } from "node:crypto";
import type { SupabaseClient, User } from "@supabase/supabase-js";
import { z } from "zod";
import {
  authorizedMentorContextSchema,
  mentorProviderResponseSchema,
  type MentorFailureCode,
  type MentorProviderResponse,
  type ParticipantMentorRequest,
} from "./contracts";
import {
  buildMentorSystemPrompt,
  buildMentorUserPrompt,
  MENTOR_PROMPT_VERSION,
} from "./prompts/v1";
import {
  MentorProviderError,
  normalizeProviderError,
  type MentorGenerationInput,
  type MentorGenerationResult,
  type MentorModelProvider,
  validateMentorInputBudget,
} from "./provider";
import type { MentorRequestControls } from "./controls";
import {
  classifyCircuitFailure,
  MentorCircuitControlError,
  type MentorCircuitAdmission,
  type MentorCircuitBreaker,
  type MentorCircuitStatus,
} from "./circuit-breaker";

const ideaStageKeys = [
  "define_problem",
  "identify_social_capacities",
  "develop_ideas",
  "implementation_plan",
  "feasibility_resilience",
  "idea_dossier",
  "human_review",
] as const;

const ideaStatusSchema = z.enum(["draft", "in_progress", "submitted"]);
const ideaRowSchema = z
  .object({
    id: z.string().uuid(),
    status: ideaStatusSchema,
    current_step: z.number().int().min(1).max(7),
  })
  .strict();
const currentStageRowSchema = z
  .object({
    stage_number: z.number().int().min(1).max(7),
    stage_key: z.enum(ideaStageKeys),
    status: z.enum([
      "not_started",
      "in_progress",
      "pending_confirmation",
      "confirmed",
      "needs_revision",
      "locked",
    ]),
    confirmed_at: z.string().nullable(),
  })
  .strict();
const priorStageRowSchema = z
  .object({
    stage_number: z.number().int().min(1).max(6),
    stage_key: z.enum(ideaStageKeys),
    content: z.string().nullable(),
  })
  .strict();

export class MentorServiceError extends Error {
  constructor(
    readonly code: MentorFailureCode,
    readonly retryAfterSeconds?: number,
    readonly providerFailureCategory?: MentorProviderError["category"],
  ) {
    super(code);
    this.name = "MentorServiceError";
  }
}

export type MentorIdeaRecord = {
  id: string;
  status: "draft" | "in_progress" | "submitted";
  currentStep: number;
};

export type MentorCurrentStageRecord = {
  stageNumber: number;
  stageKey: (typeof ideaStageKeys)[number];
  status:
    | "not_started"
    | "in_progress"
    | "pending_confirmation"
    | "confirmed"
    | "needs_revision"
    | "locked";
  confirmedAt: string | null;
};

export type MentorPriorStageRecord = {
  stageNumber: number;
  stageKey: (typeof ideaStageKeys)[number];
  content: string;
};

export type MentorDataSource = {
  loadOwnedIdea(
    ideaId: string,
    participantId: string,
  ): Promise<MentorIdeaRecord | null>;
  loadCurrentStage(
    ideaId: string,
    stageNumber: number,
  ): Promise<MentorCurrentStageRecord | null>;
  loadConfirmedEarlierStages(
    ideaId: string,
    stageNumber: number,
  ): Promise<MentorPriorStageRecord[]>;
};

export type MentorServiceDependencies = {
  data: MentorDataSource;
  controls: MentorRequestControls;
  provider: MentorModelProvider;
  circuit?: MentorCircuitBreaker;
  now?: () => number;
  sleep?: (milliseconds: number) => Promise<void>;
  timeoutMs?: number;
};

const stageNumberForKey = new Map(
  ideaStageKeys.map((stageKey, index) => [stageKey, index + 1]),
);

function publicProviderError(error: MentorProviderError): MentorServiceError {
  switch (error.category) {
    case "not_configured":
      return new MentorServiceError("not_configured", undefined, error.category);
    case "input_too_large":
      return new MentorServiceError("input_too_large", undefined, error.category);
    case "timeout":
      return new MentorServiceError("provider_timeout", undefined, error.category);
    case "network":
      return new MentorServiceError("provider_unavailable", undefined, error.category);
    case "rate_limited":
      return new MentorServiceError("provider_rate_limited", undefined, error.category);
    case "budget_exceeded":
      return new MentorServiceError(
        "provider_budget_exceeded",
        undefined,
        error.category,
      );
    case "invalid_response":
      return new MentorServiceError(
        "invalid_provider_response",
        undefined,
        error.category,
      );
    case "authentication":
      return new MentorServiceError("not_configured", undefined, error.category);
    case "unavailable":
    case "unknown":
      return new MentorServiceError("provider_unavailable", undefined, error.category);
  }
}

async function runRecoveryProbe(
  provider: MentorModelProvider,
  timeoutMs: number,
): Promise<void> {
  if (!provider.probe) {
    throw new MentorServiceError("circuit_control_unavailable");
  }
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new MentorProviderError("timeout", true));
    }, timeoutMs);
  });
  try {
    await Promise.race([provider.probe({ signal: controller.signal }), timeout]);
  } catch (error) {
    throw publicProviderError(normalizeProviderError(error, controller.signal));
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function circuitResultForError(
  error: unknown,
): ReturnType<typeof classifyCircuitFailure> {
  if (error instanceof MentorServiceError && error.providerFailureCategory) {
    return classifyCircuitFailure(error.providerFailureCategory);
  }
  if (
    error instanceof MentorServiceError &&
    error.code === "invalid_provider_response"
  ) {
    return { outcome: "ignored_failure", failureCategory: "invalid_response" };
  }
  return { outcome: "ignored_failure", failureCategory: "unknown" };
}

async function finishMentorRequest(
  controls: MentorRequestControls,
  requestId: string,
  succeeded: boolean,
): Promise<void> {
  try {
    const completion = await controls.finish(requestId, succeeded);
    const expectedState = succeeded ? "completed" : "failed";
    if (completion.state !== expectedState) {
      throw new Error("Request control state mismatch");
    }
  } catch {
    throw new MentorServiceError("control_unavailable");
  }
}

export async function getMentorAvailability(
  provider: MentorModelProvider,
  circuit: MentorCircuitBreaker,
): Promise<{
  status:
    | "available"
    | "not_configured"
    | "temporarily_unavailable"
    | "recovery_eligible"
    | "recovery_in_progress";
  retryAfterSeconds?: number;
}> {
  try {
    provider.prepare?.();
  } catch (error) {
    const providerError = normalizeProviderError(error);
    console.info(
      JSON.stringify({
        event: "mentor.availability",
        provider: "google.generative-ai",
        status:
          providerError.category === "not_configured" ||
          providerError.category === "authentication"
            ? "not_configured"
            : "temporarily_unavailable",
        errorCategory: providerError.category,
      }),
    );
    if (
      providerError.category === "not_configured" ||
      providerError.category === "authentication"
    ) {
      return { status: "not_configured" };
    }
    return { status: "temporarily_unavailable" };
  }

  const providerModel = provider.circuitKey?.();
  if (!providerModel) throw new MentorServiceError("circuit_control_unavailable");

  let state: MentorCircuitStatus;
  try {
    state = await circuit.status(providerModel);
  } catch (error) {
    if (error instanceof MentorCircuitControlError) {
      throw new MentorServiceError("circuit_control_unavailable");
    }
    throw error;
  }
  if (state.state === "closed") return { status: "available" };
  if (state.state === "open") {
    return {
      status: state.recoveryEligible
        ? "recovery_eligible"
        : "temporarily_unavailable",
      retryAfterSeconds: state.retryAfterSeconds,
    };
  }
  return {
    status: "recovery_in_progress",
    retryAfterSeconds: state.retryAfterSeconds,
  };
}

async function generateWithBoundedRetry(
  provider: MentorModelProvider,
  input: Omit<MentorGenerationInput, "signal">,
  timeoutMs: number,
  sleep: (milliseconds: number) => Promise<void>,
): Promise<MentorGenerationResult> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
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
        provider.generate({ ...input, signal: controller.signal }),
        timeout,
      ]);
    } catch (error) {
      const normalized = normalizeProviderError(error, controller.signal);
      if (!normalized.retryable || attempt === 1) {
        throw publicProviderError(normalized);
      }
    } finally {
      if (timer) clearTimeout(timer);
    }
    await sleep(250);
  }

  throw new MentorServiceError("provider_unavailable");
}

function recordOperation(
  status: "success" | "error",
  metadata: {
    model?: string;
    correlationId?: string;
    latencyMs: number;
    inputTokens?: number;
    outputTokens?: number;
    errorCategory?: string;
  },
): void {
  console.info(
    JSON.stringify({
      event: "mentor.request",
      provider: "google.generative-ai",
      promptVersion: MENTOR_PROMPT_VERSION,
      status,
      ...metadata,
    }),
  );
}

export async function createMentorResponse(
  request: ParticipantMentorRequest,
  participant: Pick<User, "id">,
  dependencies: MentorServiceDependencies,
) {
  const startedAt = (dependencies.now ?? Date.now)();
  const correlationId = randomUUID();
  const requestedStageNumber = stageNumberForKey.get(request.stageKey);
  if (!requestedStageNumber || requestedStageNumber === 7) {
    throw new MentorServiceError("stage_forbidden");
  }

  let idea: MentorIdeaRecord | null;
  let currentStage: MentorCurrentStageRecord | null;
  let priorStages: MentorPriorStageRecord[];
  try {
    idea = await dependencies.data.loadOwnedIdea(request.ideaId, participant.id);
    if (!idea) throw new MentorServiceError("idea_unavailable");
    if (idea.status === "submitted" || idea.currentStep !== requestedStageNumber) {
      throw new MentorServiceError("stage_forbidden");
    }

    currentStage = await dependencies.data.loadCurrentStage(
      idea.id,
      requestedStageNumber,
    );
    if (
      !currentStage ||
      currentStage.stageKey !== request.stageKey ||
      currentStage.stageNumber !== requestedStageNumber ||
      currentStage.status === "locked"
    ) {
      throw new MentorServiceError("stage_forbidden");
    }

    priorStages = await dependencies.data.loadConfirmedEarlierStages(
      idea.id,
      requestedStageNumber,
    );
  } catch (error) {
    if (error instanceof MentorServiceError) throw error;
    throw new MentorServiceError("context_unavailable");
  }

  const context = authorizedMentorContextSchema.safeParse({
    ideaId: idea.id,
    currentStep: requestedStageNumber,
    stageKey: request.stageKey,
    stageStatus: currentStage.status,
    confirmedEarlierStages: priorStages.map((stage) => ({
      stageNumber: stage.stageNumber,
      stageKey: stage.stageKey,
      content: stage.content.slice(0, 1_800),
    })),
    participantMessage: request.message,
  });
  if (!context.success) throw new MentorServiceError("context_unavailable");

  const generationInput = {
    system: buildMentorSystemPrompt(context.data.stageKey),
    prompt: buildMentorUserPrompt({
      stageKey: context.data.stageKey,
      participantMessage: context.data.participantMessage,
      confirmedEarlierStages: context.data.confirmedEarlierStages,
    }),
  };

  try {
    dependencies.provider.prepare?.();
    validateMentorInputBudget(generationInput);
  } catch (error) {
    const serviceError = publicProviderError(normalizeProviderError(error));
    if (serviceError.code === "not_configured") {
      console.info(
        JSON.stringify({
          event: "mentor.fallback",
          provider: "google.generative-ai",
          errorCategory: serviceError.code,
          correlationId,
        }),
      );
    }
    recordOperation("error", {
      latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
      errorCategory: serviceError.code,
    });
    throw serviceError;
  }

  const providerModel =
    dependencies.provider.circuitKey?.() ?? "test:mentor-provider";
  if (dependencies.circuit) {
    let status: MentorCircuitStatus;
    try {
      status = await dependencies.circuit.status(providerModel);
    } catch (error) {
      if (error instanceof MentorCircuitControlError) {
        console.info(
          JSON.stringify({
            event: "mentor.fallback",
            providerModel,
            errorCategory: "circuit_control_unavailable",
            correlationId,
          }),
        );
        throw new MentorServiceError("circuit_control_unavailable");
      }
      throw error;
    }

    if (
      status.state === "half_open" ||
      (status.state === "open" && !status.recoveryEligible)
    ) {
      console.info(
        JSON.stringify({
          event: "mentor.fallback",
          providerModel,
          state: status.state,
          correlationId,
        }),
      );
      throw new MentorServiceError(
        "circuit_open",
        status.retryAfterSeconds,
      );
    }
  }

  let reservation;
  try {
    reservation = await dependencies.controls.reserve(request.requestId);
  } catch {
    recordOperation("error", {
      correlationId,
      latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
      errorCategory: "control_unavailable",
    });
    throw new MentorServiceError("control_unavailable");
  }
  if (reservation.outcome === "rate_limited") {
    throw new MentorServiceError(
      "rate_limited",
      reservation.retryAfterSeconds,
    );
  }
  if (reservation.outcome === "duplicate") {
    throw new MentorServiceError(
      reservation.state === "processing"
        ? "duplicate_in_progress"
        : "duplicate_request",
    );
  }

  let circuitAdmission: MentorCircuitAdmission = {
    outcome: "admitted",
    state: "closed",
  };
  if (dependencies.circuit) {
    try {
      circuitAdmission = await dependencies.circuit.admit(providerModel);
    } catch (error) {
      recordOperation("error", {
        correlationId,
        latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
        errorCategory: "circuit_control_unavailable",
      });
      await finishMentorRequest(
        dependencies.controls,
        request.requestId,
        false,
      );
      if (error instanceof MentorCircuitControlError) {
        console.info(
          JSON.stringify({
            event: "mentor.fallback",
            providerModel,
            errorCategory: "circuit_control_unavailable",
            correlationId,
          }),
        );
        throw new MentorServiceError("circuit_control_unavailable");
      }
      throw error;
    }

    if (circuitAdmission.outcome === "blocked") {
      await finishMentorRequest(
        dependencies.controls,
        request.requestId,
        false,
      );
      recordOperation("error", {
        correlationId,
        latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
        errorCategory: "circuit_open",
      });
      console.info(
        JSON.stringify({
          event: "mentor.fallback",
          providerModel,
          state: circuitAdmission.state,
          correlationId,
        }),
      );
      throw new MentorServiceError(
        "circuit_open",
        circuitAdmission.retryAfterSeconds,
      );
    }

    if (circuitAdmission.outcome === "probe") {
      try {
        await runRecoveryProbe(
          dependencies.provider,
          dependencies.timeoutMs ?? 15_000,
        );
        await dependencies.circuit.record(
          providerModel,
          circuitAdmission,
          { outcome: "success" },
          correlationId,
        );
        console.info(
          JSON.stringify({
            event: "mentor.circuit",
            providerModel,
            state: "closed",
            outcome: "probe_succeeded",
            correlationId,
          }),
        );
        circuitAdmission = { outcome: "admitted", state: "closed" };
      } catch (error) {
        const probeResult = circuitResultForError(error);
        try {
          await dependencies.circuit.record(
            providerModel,
            circuitAdmission,
            probeResult,
            correlationId,
          );
        } catch {
          await finishMentorRequest(
            dependencies.controls,
            request.requestId,
            false,
          );
          throw new MentorServiceError("circuit_control_unavailable");
        }
        await finishMentorRequest(
          dependencies.controls,
          request.requestId,
          false,
        );
        const serviceError =
          error instanceof MentorServiceError
            ? error
            : new MentorServiceError("provider_unavailable");
        recordOperation("error", {
          model: providerModel,
          correlationId,
          latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
          errorCategory: serviceError.code,
        });
        console.info(
          JSON.stringify({
            event: "mentor.circuit",
            providerModel,
            state:
              probeResult.outcome === "transient_failure" ? "open" : "closed",
            outcome: "probe_failed",
            errorCategory: serviceError.providerFailureCategory ?? "unknown",
            correlationId,
          }),
        );
        console.info(
          JSON.stringify({
            event: "mentor.fallback",
            providerModel,
            state:
              probeResult.outcome === "transient_failure" ? "open" : "closed",
            correlationId,
          }),
        );
        throw serviceError;
      }
    }
  }

  let result: MentorGenerationResult;
  let suggestion: MentorProviderResponse;
  try {
    result = await generateWithBoundedRetry(
      dependencies.provider,
      generationInput,
      dependencies.timeoutMs ?? 15_000,
      dependencies.sleep ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))),
    );
    const parsedOutput = mentorProviderResponseSchema.safeParse(result.output);
    if (!parsedOutput.success) {
      throw new MentorServiceError("invalid_provider_response");
    }
    suggestion = parsedOutput.data.refusal
      ? { ...parsedOutput.data, followUpQuestions: [] }
      : parsedOutput.data;
    if (dependencies.circuit) {
      await dependencies.circuit.record(
        providerModel,
        circuitAdmission,
        { outcome: "success" },
        correlationId,
      );
    }
  } catch (error) {
    const serviceError =
      error instanceof MentorServiceError
        ? error
        : new MentorServiceError("provider_unavailable");
    if (dependencies.circuit) {
      try {
        await dependencies.circuit.record(
          providerModel,
          circuitAdmission,
          circuitResultForError(serviceError),
          correlationId,
        );
      } catch {
        recordOperation("error", {
          correlationId,
          latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
          errorCategory: "circuit_control_unavailable",
        });
        throw new MentorServiceError("circuit_control_unavailable");
      }
    }
    try {
      await finishMentorRequest(
        dependencies.controls,
        request.requestId,
        false,
      );
    } catch {
      recordOperation("error", {
        correlationId,
        latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
        errorCategory: "control_unavailable",
      });
      throw new MentorServiceError("control_unavailable");
    }
    recordOperation("error", {
      correlationId,
      latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
      errorCategory: serviceError.code,
    });
    console.info(
      JSON.stringify({
        event: "mentor.fallback",
        providerModel,
        errorCategory: serviceError.code,
        correlationId,
      }),
    );
    throw serviceError;
  }

  try {
    await finishMentorRequest(
      dependencies.controls,
      request.requestId,
      true,
    );
  } catch {
    recordOperation("error", {
      model: result.model,
      correlationId,
      latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
      inputTokens: result.inputTokens,
      outputTokens: result.outputTokens,
      errorCategory: "control_unavailable",
    });
    throw new MentorServiceError("control_unavailable");
  }

  const response = {
    ok: true as const,
    suggestion,
    metadata: {
      provider: "google.generative-ai" as const,
      model: result.model,
      promptVersion: MENTOR_PROMPT_VERSION,
      latencyMs: Math.max(0, (dependencies.now ?? Date.now)() - startedAt),
      inputTokens: result.inputTokens,
      outputTokens: result.outputTokens,
    },
  };
  recordOperation("success", response.metadata);
  return response;
}

export function createSupabaseMentorDataSource(
  supabase: SupabaseClient,
): MentorDataSource {
  return {
    async loadOwnedIdea(ideaId, participantId) {
      const { data, error } = await supabase
        .from("ideas")
        .select("id,status,current_step")
        .eq("id", ideaId)
        .eq("owner_id", participantId)
        .maybeSingle();
      if (error) throw error;
      if (!data) return null;
      const parsed = ideaRowSchema.safeParse(data);
      if (!parsed.success) throw new Error("Invalid idea context");
      return {
        id: parsed.data.id,
        status: parsed.data.status,
        currentStep: parsed.data.current_step,
      };
    },

    async loadCurrentStage(ideaId, stageNumber) {
      const { data, error } = await supabase
        .from("idea_stages")
        .select("stage_number,stage_key,status,confirmed_at")
        .eq("idea_id", ideaId)
        .eq("stage_number", stageNumber)
        .maybeSingle();
      if (error) throw error;
      if (!data) return null;
      const parsed = currentStageRowSchema.safeParse(data);
      if (!parsed.success) throw new Error("Invalid stage context");
      return {
        stageNumber: parsed.data.stage_number,
        stageKey: parsed.data.stage_key,
        status: parsed.data.status,
        confirmedAt: parsed.data.confirmed_at,
      };
    },

    async loadConfirmedEarlierStages(ideaId, stageNumber) {
      const { data, error } = await supabase
        .from("idea_stages")
        .select("stage_number,stage_key,content:data->>content")
        .eq("idea_id", ideaId)
        .lt("stage_number", stageNumber)
        .eq("status", "confirmed")
        .order("stage_number", { ascending: true });
      if (error) throw error;
      if (!Array.isArray(data)) throw new Error("Invalid confirmed-stage context");

      return data.flatMap((row) => {
        const parsed = priorStageRowSchema.safeParse(row);
        if (!parsed.success || !parsed.data.content?.trim()) return [];
        return [
          {
            stageNumber: parsed.data.stage_number,
            stageKey: parsed.data.stage_key,
            content: parsed.data.content.slice(0, 1_800),
          },
        ];
      });
    },
  };
}