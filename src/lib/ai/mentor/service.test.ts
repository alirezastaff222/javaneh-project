import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import {
  participantMentorRequestSchema,
  type ParticipantMentorRequest,
} from "./contracts";
import type { MentorRequestControls } from "./controls";
import type {
  MentorCircuitAdmission,
  MentorCircuitBreaker,
  MentorCircuitResult,
} from "./circuit-breaker";
import { buildMentorSystemPrompt, buildMentorUserPrompt } from "./prompts/v1";
import {
  createMentorResponse,
  MentorServiceError,
  type MentorServiceDependencies,
} from "./service";
import {
  MentorProviderError,
  getMentorModelConfiguration,
  normalizeProviderError,
  type MentorGenerationResult,
  validateMentorInputBudget,
} from "./provider";

const request: ParticipantMentorRequest = {
  ideaId: "2eb4f522-0e22-4fdc-a9e1-1f63c378ad51",
  requestId: "adcfb81c-89e2-46ed-91a6-33e2ca4938a3",
  stageKey: "develop_ideas",
  message: "How could I compare these two approaches?",
};

function dependencies(
  overrides: Partial<MentorServiceDependencies> = {},
  generated: unknown = {
    message: "What evidence would help you compare them?",
    followUpQuestions: ["Who would each approach involve?"],
    refusal: false,
  },
): MentorServiceDependencies {
  return {
    data: {
      loadOwnedIdea: async () => ({
        id: request.ideaId,
        status: "in_progress",
        currentStep: 3,
      }),
      loadCurrentStage: async () => ({
        stageNumber: 3,
        stageKey: "develop_ideas",
        status: "in_progress",
        confirmedAt: null,
      }),
      loadConfirmedEarlierStages: async () => [
        {
          stageNumber: 1,
          stageKey: "define_problem",
          content: "A participant-confirmed problem statement.",
        },
      ],
    },
    controls: {
      reserve: async () => ({ outcome: "admitted" }),
      finish: async (_requestId, succeeded) => ({
        outcome: "finished",
        state: succeeded ? "completed" : "failed",
      }),
    },
    provider: {
      generate: async (): Promise<MentorGenerationResult> => ({
        output: generated,
        model: "gemini-3.8-flash",
        inputTokens: 120,
        outputTokens: 36,
      }),
    },
    now: () => 1_000,
    sleep: async () => undefined,
    ...overrides,
  };
}

type SharedControlState = {
  reservations: Map<
    string,
    {
      participantId: string;
      createdAt: number;
      state: "processing" | "completed" | "failed";
    }
  >;
};

function sharedControls(
  participantId: string,
  shared: SharedControlState,
  now = 1_000,
): MentorRequestControls {
  return {
    async reserve(requestId) {
      const key = `${participantId}:${requestId}`;
      const existing = shared.reservations.get(key);
      if (existing) return { outcome: "duplicate", state: existing.state };

      const recent = [...shared.reservations.values()].filter(
        (reservation) =>
          reservation.participantId === participantId &&
          now - reservation.createdAt < 60_000,
      );
      if (recent.length >= 5) {
        return { outcome: "rate_limited", retryAfterSeconds: 60 };
      }

      shared.reservations.set(key, {
        participantId,
        createdAt: now,
        state: "processing",
      });
      return { outcome: "admitted" };
    },
    async finish(requestId, succeeded) {
      const reservation = shared.reservations.get(`${participantId}:${requestId}`);
      if (!reservation) throw new Error("missing reservation");
      if (reservation.state !== "processing") {
        return { outcome: "already_finished", state: reservation.state };
      }
      reservation.state = succeeded ? "completed" : "failed";
      return { outcome: "finished", state: reservation.state };
    },
  };
}

test("request schema rejects extra fields and oversized/empty messages", () => {
  assert.equal(participantMentorRequestSchema.safeParse(request).success, true);
  assert.equal(
    participantMentorRequestSchema.safeParse({ ...request, ownerId: "forged" })
      .success,
    false,
  );
  assert.equal(
    participantMentorRequestSchema.safeParse({ ...request, message: " " }).success,
    false,
  );
  assert.equal(
    participantMentorRequestSchema.safeParse({ ...request, message: "x".repeat(4_001) })
      .success,
    false,
  );
});

test("Google API configuration is detected without requiring a live provider call", () => {
  assert.deepEqual(
    getMentorModelConfiguration({ AI_MENTOR_MODEL: "gemini-3.8-flash" }),
    { model: "gemini-3.8-flash", configured: false },
  );
  assert.equal(
    getMentorModelConfiguration({
      GOOGLE_GENERATIVE_AI_API_KEY: "test-key",
      AI_MENTOR_MODEL: "gemini-3.8-flash",
    }).configured,
    true,
  );
});

test("provider input is capped by a UTF-8 byte budget", () => {
  assert.doesNotThrow(() => validateMentorInputBudget({ system: "mentor", prompt: "short" }));
  assert.throws(
    () => validateMentorInputBudget({ system: "x".repeat(16_001), prompt: "" }),
    (error: unknown) =>
      error instanceof MentorProviderError && error.category === "input_too_large",
  );
});

test("runtime invalid model and provider config errors are treated as configuration failures", () => {
  let error = normalizeProviderError({
    status: 404,
    message: "Model not found: gemini-3.8-flash",
  });
  assert.equal(error.category, "not_configured");
  assert.equal(error.retryable, false);

  error = normalizeProviderError(new Error("Unknown model: no-such-model"));
  assert.equal(error.category, "not_configured");
  assert.equal(error.retryable, false);

  error = normalizeProviderError({ status: 422, message: "missing API key" });
  assert.equal(error.category, "not_configured");
  assert.equal(error.retryable, false);
});

test("provider configuration/auth failures are excluded without masking request errors", () => {
  const invalidKey = normalizeProviderError({
    status: 401,
    message: "Invalid API key",
  });
  assert.equal(invalidKey.category, "authentication");
  assert.equal(invalidKey.retryable, false);

  const unsupportedModel = normalizeProviderError({
    status: 404,
    code: "model_not_found",
  });
  assert.equal(unsupportedModel.category, "not_configured");

  for (const error of [
    { status: 400, code: "invalid_request", message: "Malformed request" },
    { status: 404, code: "resource_not_found", message: "Unknown resource" },
    { status: 422, code: "validation_error", message: "Invalid request fields" },
  ]) {
    assert.equal(normalizeProviderError(error).category, "unknown");
  }

  assert.equal(
    normalizeProviderError({ status: 408 }).category,
    "timeout",
  );
  assert.equal(
    normalizeProviderError({ status: 503 }).category,
    "unavailable",
  );
  assert.equal(
    normalizeProviderError({ status: 429 }).category,
    "rate_limited",
  );
  assert.equal(
    normalizeProviderError(new TypeError("fetch failed")).category,
    "network",
  );
});

test("valid provider output returns a separately labeled suggestion and metadata", async () => {
  const result = await createMentorResponse(request, { id: "participant" }, dependencies());
  assert.equal(result.ok, true);
  assert.equal(result.suggestion.message, "What evidence would help you compare them?");
  assert.equal(result.metadata.promptVersion, "m9r11.v1");
  assert.equal(result.metadata.inputTokens, 120);
});

test("malformed and empty provider outputs are rejected", async () => {
  for (const output of [null, {}, { message: "", followUpQuestions: [], refusal: false }]) {
    await assert.rejects(
      createMentorResponse(request, { id: "participant" }, dependencies({}, output)),
      (error: unknown) =>
        error instanceof MentorServiceError &&
        error.code === "invalid_provider_response",
    );
  }
});

test("missing ownership and non-current or locked stages are rejected before generation", async () => {
  let queriedParticipantId: string | undefined;
  const missingIdea = dependencies({
    data: {
      ...dependencies().data,
      loadOwnedIdea: async (_ideaId, participantId) => {
        queriedParticipantId = participantId;
        return null;
      },
    },
  });
  await assert.rejects(
    createMentorResponse(request, { id: "participant" }, missingIdea),
    (error: unknown) => error instanceof MentorServiceError && error.code === "idea_unavailable",
  );
  assert.equal(queriedParticipantId, "participant");

  const wrongStage = dependencies({
    data: {
      ...dependencies().data,
      loadOwnedIdea: async () => ({ id: request.ideaId, status: "in_progress", currentStep: 2 }),
    },
  });
  await assert.rejects(
    createMentorResponse(request, { id: "participant" }, wrongStage),
    (error: unknown) => error instanceof MentorServiceError && error.code === "stage_forbidden",
  );

  const lockedStage = dependencies({
    data: {
      ...dependencies().data,
      loadCurrentStage: async () => ({
        stageNumber: 3,
        stageKey: "develop_ideas",
        status: "locked",
        confirmedAt: null,
      }),
    },
  });
  await assert.rejects(
    createMentorResponse(request, { id: "participant" }, lockedStage),
    (error: unknown) => error instanceof MentorServiceError && error.code === "stage_forbidden",
  );
});

test("human review requests never reach the provider", async () => {
  let called = false;
  const reviewRequest = { ...request, stageKey: "human_review" as const };
  const deps = dependencies({
    provider: {
      generate: async () => {
        called = true;
        throw new Error("must not run");
      },
    },
  });
  await assert.rejects(
    createMentorResponse(reviewRequest, { id: "participant" }, deps),
    (error: unknown) => error instanceof MentorServiceError && error.code === "stage_forbidden",
  );
  assert.equal(called, false);
});

test("only bounded earlier confirmed text and the participant message enter the prompt", async () => {
  let prompt = "";
  const deps = dependencies({
    data: {
      ...dependencies().data,
      loadConfirmedEarlierStages: async () => [
        {
          stageNumber: 1,
          stageKey: "define_problem",
          content: "confirmed".repeat(500),
        },
      ],
    },
    provider: {
      generate: async (input) => {
        prompt = input.prompt;
        return {
          output: {
            message: "A bounded response.",
            followUpQuestions: [],
            refusal: false,
          },
          model: "test/model",
        };
      },
    },
  });
  await createMentorResponse(request, { id: "participant" }, deps);
  assert.match(prompt, /Participant's current message/);
  assert.match(prompt, /confirmed/);
  assert.equal(prompt.includes("unconfirmed"), false);
  assert.ok(prompt.length < 5_000);
});

test("retryable timeouts retry once; provider rate limits and outages are classified", async () => {
  let attempts = 0;
  const providerRetries = dependencies({
    provider: {
      generate: async () => {
        attempts += 1;
        if (attempts === 1) throw new MentorProviderError("timeout", true);
        return {
          output: {
            message: "Retry succeeded.",
            followUpQuestions: [],
            refusal: false,
          },
          model: "test/model",
        };
      },
    },
  });

  test("open circuit blocks provider calls before consuming participant request quota", async () => {
    let providerCalls = 0;
    let reservations = 0;
    const deps = dependencies({
      controls: {
        reserve: async () => {
          reservations += 1;
          return { outcome: "admitted" };
        },
        finish: async () => ({ outcome: "finished", state: "failed" }),
      },
      provider: {
        generate: async () => {
          providerCalls += 1;
          throw new Error("must not be called");
        },
      },
      circuit: {
        status: async () => ({
          state: "open",
          recoveryEligible: false,
          retryAfterSeconds: 30,
        }),
        admit: async () => ({
          outcome: "blocked",
          state: "open",
          retryAfterSeconds: 30,
        }),
        record: async () => undefined,
      },
    });

    await assert.rejects(
      createMentorResponse(request, { id: "participant-a" }, deps),
      (error: unknown) =>
        error instanceof MentorServiceError &&
        error.code === "circuit_open" &&
        error.retryAfterSeconds === 30,
    );
    assert.equal(providerCalls, 0);
    assert.equal(reservations, 0);
  });

  test("half-open recovery uses a minimal probe without participant content and then serves the request", async () => {
    const records: MentorCircuitResult[] = [];
    let probeCalls = 0;
    let generationCalls = 0;
    let reservationCalls = 0;
    const probeAdmission: MentorCircuitAdmission = {
      outcome: "probe",
      state: "half_open",
      probeToken: randomUUID(),
    };
    const circuit: MentorCircuitBreaker = {
      status: async () => ({
        state: "open",
        recoveryEligible: true,
        retryAfterSeconds: 0,
      }),
      admit: async () => probeAdmission,
      record: async (_model, admission, result) => {
        if (admission.outcome === "probe") records.push(result);
        else records.push(result);
      },
    };
    const deps = dependencies({
      circuit,
      controls: {
        reserve: async () => {
          reservationCalls += 1;
          return { outcome: "admitted" };
        },
        finish: async (_requestId, succeeded) => ({
          outcome: "finished",
          state: succeeded ? "completed" : "failed",
        }),
      },
      provider: {
        circuitKey: () => "google.generative-ai:test/model",
        probe: async (input) => {
          probeCalls += 1;
          assert.ok(input.signal instanceof AbortSignal);
          assert.equal("prompt" in input, false);
          assert.equal("system" in input, false);
        },
        generate: async (input) => {
          generationCalls += 1;
          assert.match(input.prompt, /Participant's current message/);
          return {
            output: {
              message: "Recovery succeeded.",
              followUpQuestions: [],
              refusal: false,
            },
            model: "test/model",
          };
        },
      },
    });

    const result = await createMentorResponse(request, { id: "participant-a" }, deps);
    assert.equal(result.suggestion.message, "Recovery succeeded.");
    assert.equal(probeCalls, 1);
    assert.equal(generationCalls, 1);
    assert.equal(reservationCalls, 1);
    assert.deepEqual(records, [{ outcome: "success" }, { outcome: "success" }]);
  });

  test("duplicate recovery requests are rejected before admitting or paying for a probe", async () => {
    let admissions = 0;
    let probes = 0;
    const deps = dependencies({
      circuit: {
        status: async () => ({
          state: "open",
          recoveryEligible: true,
          retryAfterSeconds: 0,
        }),
        admit: async () => {
          admissions += 1;
          return {
            outcome: "probe",
            state: "half_open",
            probeToken: randomUUID(),
          };
        },
        record: async () => undefined,
      },
      controls: {
        reserve: async () => ({ outcome: "duplicate", state: "completed" }),
        finish: async () => ({ outcome: "already_finished", state: "completed" }),
      },
      provider: {
        probe: async () => {
          probes += 1;
        },
        generate: async () => {
          throw new Error("must not be called");
        },
      },
    });

    await assert.rejects(
      createMentorResponse(request, { id: "participant-a" }, deps),
      (error: unknown) =>
        error instanceof MentorServiceError && error.code === "duplicate_request",
    );
    assert.equal(admissions, 0);
    assert.equal(probes, 0);
  });

  test("failed half-open recovery reopens the circuit and finalizes participant work", async () => {
    let providerCalls = 0;
    let reservations = 0;
    let finishedState: "completed" | "failed" | undefined;
    let circuitResult: MentorCircuitResult | undefined;
    const admission: MentorCircuitAdmission = {
      outcome: "probe",
      state: "half_open",
      probeToken: randomUUID(),
    };
    const deps = dependencies({
      circuit: {
        status: async () => ({
          state: "open",
          recoveryEligible: true,
          retryAfterSeconds: 0,
        }),
        admit: async () => admission,
        record: async (_model, _admission, result) => {
          circuitResult = result;
        },
      },
      controls: {
        reserve: async () => {
          reservations += 1;
          return { outcome: "admitted" };
        },
        finish: async (_requestId, succeeded) => {
          finishedState = succeeded ? "completed" : "failed";
          return { outcome: "finished", state: finishedState };
        },
      },
      provider: {
        probe: async () => {
          providerCalls += 1;
          throw new MentorProviderError("timeout", true);
        },
        generate: async () => {
          providerCalls += 1;
          throw new Error("participant generation must not run");
        },
      },
    });

    await assert.rejects(
      createMentorResponse(request, { id: "participant-a" }, deps),
      (error: unknown) =>
        error instanceof MentorServiceError && error.code === "provider_timeout",
    );
    assert.equal(providerCalls, 1);
    assert.equal(reservations, 1);
    assert.equal(finishedState, "failed");
    assert.deepEqual(circuitResult, {
      outcome: "transient_failure",
      failureCategory: "timeout",
    });
  });
  const result = await createMentorResponse(request, { id: "participant" }, providerRetries);
  assert.equal(result.suggestion.message, "Retry succeeded.");
  assert.equal(attempts, 2);

  for (const category of ["rate_limited", "unavailable"] as const) {
    let failureAttempts = 0;
    const failed = dependencies({
      provider: {
        generate: async () => {
          failureAttempts += 1;
          throw new MentorProviderError(category, true);
        },
      },
    });
    await assert.rejects(
      createMentorResponse(request, { id: "participant" }, failed),
      (error: unknown) =>
        error instanceof MentorServiceError &&
        error.code ===
          (category === "rate_limited" ? "provider_rate_limited" : "provider_unavailable"),
    );
    assert.equal(failureAttempts, 2);
  }

  let invalidAttempts = 0;
  await assert.rejects(
    createMentorResponse(
      request,
      { id: "participant" },
      dependencies({
        provider: {
          generate: async () => {
            invalidAttempts += 1;
            throw new MentorProviderError("invalid_response", false);
          },
        },
      }),
    ),
    (error: unknown) =>
      error instanceof MentorServiceError &&
      error.code === "invalid_provider_response",
  );
  assert.equal(invalidAttempts, 1);
});

test("provider timeout is enforced even when the provider ignores abort", async () => {
  let attempts = 0;
  const shared: SharedControlState = { reservations: new Map() };
  const deps = dependencies({
    timeoutMs: 2,
    controls: sharedControls("participant-a", shared),
    provider: {
      generate: async () => {
        attempts += 1;
        return new Promise<MentorGenerationResult>(() => undefined);
      },
    },
  });
  await assert.rejects(
    createMentorResponse(request, { id: "participant" }, deps),
    (error: unknown) =>
      error instanceof MentorServiceError && error.code === "provider_timeout",
  );
  assert.equal(attempts, 2);
  assert.equal(
    shared.reservations.get(`participant-a:${request.requestId}`)?.state,
    "failed",
  );
  await assert.rejects(
    createMentorResponse(request, { id: "participant-a" }, deps),
    (error: unknown) =>
      error instanceof MentorServiceError && error.code === "duplicate_request",
  );
  assert.equal(attempts, 2);
});

test("published prompt selection is stage-specific and Stage 7 guidance is human-only", () => {
  assert.match(buildMentorSystemPrompt("define_problem"), /describe the social problem/);
  assert.match(buildMentorSystemPrompt("implementation_plan"), /activities, roles, resources/);
  assert.match(buildMentorSystemPrompt("human_review"), /Do not evaluate, score, rank/);
  const prompt = buildMentorUserPrompt({
    stageKey: "develop_ideas",
    participantMessage: "Compare these options.",
    confirmedEarlierStages: [],
  });
  assert.match(prompt, /no earlier confirmed participant text/);
});

test("shared controls reject concurrent same-user duplicate IDs across service instances", async () => {
  const shared: SharedControlState = { reservations: new Map() };
  let providerCalls = 0;
  const makeInstance = () =>
    dependencies({
      controls: sharedControls("participant-a", shared),
      provider: {
        generate: async () => {
          providerCalls += 1;
          return {
            output: {
              message: "One provider call only.",
              followUpQuestions: [],
              refusal: false,
            },
            model: "test/model",
          };
        },
      },
    });

  const results = await Promise.allSettled([
    createMentorResponse(request, { id: "participant-a" }, makeInstance()),
    createMentorResponse(request, { id: "participant-a" }, makeInstance()),
  ]);
  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  const rejected = results.find((result) => result.status === "rejected");
  assert.equal(
    rejected?.status === "rejected" &&
      rejected.reason instanceof MentorServiceError &&
      rejected.reason.code === "duplicate_in_progress",
    true,
  );
  assert.equal(providerCalls, 1);

  await assert.rejects(
    createMentorResponse(request, { id: "participant-a" }, makeInstance()),
    (error: unknown) =>
      error instanceof MentorServiceError && error.code === "duplicate_request",
  );
  assert.equal(providerCalls, 1);
});

test("same request ID is isolated per authenticated user", async () => {
  const shared: SharedControlState = { reservations: new Map() };
  let providerCalls = 0;
  const makeInstance = (participantId: string) =>
    dependencies({
      controls: sharedControls(participantId, shared),
      provider: {
        generate: async () => {
          providerCalls += 1;
          return {
            output: { message: "Allowed.", followUpQuestions: [], refusal: false },
            model: "test/model",
          };
        },
      },
    });

  const results = await Promise.all([
    createMentorResponse(request, { id: "participant-a" }, makeInstance("participant-a")),
    createMentorResponse(request, { id: "participant-b" }, makeInstance("participant-b")),
  ]);
  assert.equal(results.length, 2);
  assert.equal(providerCalls, 2);
});

test("concurrent new IDs enforce the five-request rolling boundary", async () => {
  const shared: SharedControlState = { reservations: new Map() };
  let providerCalls = 0;
  const controls = sharedControls("participant-a", shared);
  const results = await Promise.allSettled(
    Array.from({ length: 8 }, () =>
      createMentorResponse(
        { ...request, requestId: randomUUID() },
        { id: "participant-a" },
        dependencies({
          controls,
          provider: {
            generate: async () => {
              providerCalls += 1;
              return {
                output: { message: "Allowed.", followUpQuestions: [], refusal: false },
                model: "test/model",
              };
            },
          },
        }),
      ),
    ),
  );
  assert.equal(results.filter((result) => result.status === "fulfilled").length, 5);
  assert.equal(providerCalls, 5);
  assert.equal(
    results.filter(
      (result) =>
        result.status === "rejected" &&
        result.reason instanceof MentorServiceError &&
        result.reason.code === "rate_limited",
    ).length,
    3,
  );
});

test("authorization and configuration failures happen before reservation", async () => {
  let reservations = 0;
  let providerCalls = 0;
  const controls: MentorRequestControls = {
    reserve: async () => {
      reservations += 1;
      return { outcome: "admitted" };
    },
    finish: async () => ({ outcome: "finished", state: "completed" }),
  };
  const unauthorized = dependencies({
    controls,
    data: {
      ...dependencies().data,
      loadOwnedIdea: async () => null,
    },
  });
  await assert.rejects(
    createMentorResponse(request, { id: "participant-a" }, unauthorized),
    (error: unknown) => error instanceof MentorServiceError && error.code === "idea_unavailable",
  );

  const unconfigured = dependencies({
    controls,
    provider: {
      prepare: () => {
        throw new MentorProviderError("not_configured", false);
      },
      generate: async () => {
        providerCalls += 1;
        throw new Error("must not run");
      },
    },
  });
  await assert.rejects(
    createMentorResponse(request, { id: "participant-a" }, unconfigured),
    (error: unknown) => error instanceof MentorServiceError && error.code === "not_configured",
  );
  assert.equal(reservations, 0);
  assert.equal(providerCalls, 0);
});

test("provider failures finalize the ID and same-ID retry never calls the provider again", async () => {
  const shared: SharedControlState = { reservations: new Map() };
  const controls = sharedControls("participant-a", shared);
  let providerCalls = 0;
  const failedProvider = dependencies({
    controls,
    provider: {
      generate: async () => {
        providerCalls += 1;
        throw new MentorProviderError("unavailable", false);
      },
    },
  });
  await assert.rejects(
    createMentorResponse(request, { id: "participant-a" }, failedProvider),
    (error: unknown) => error instanceof MentorServiceError && error.code === "provider_unavailable",
  );
  assert.equal(
    shared.reservations.get(`participant-a:${request.requestId}`)?.state,
    "failed",
  );

  await assert.rejects(
    createMentorResponse(request, { id: "participant-a" }, failedProvider),
    (error: unknown) => error instanceof MentorServiceError && error.code === "duplicate_request",
  );
  assert.equal(providerCalls, 1);
});

test("control database failures fail closed before provider calls", async () => {
  let providerCalls = 0;
  const deps = dependencies({
    controls: {
      reserve: async () => {
        throw new Error("database unavailable");
      },
      finish: async () => ({ outcome: "finished", state: "completed" }),
    },
    provider: {
      generate: async () => {
        providerCalls += 1;
        throw new Error("must not run");
      },
    },
  });
  await assert.rejects(
    createMentorResponse(request, { id: "participant-a" }, deps),
    (error: unknown) => error instanceof MentorServiceError && error.code === "control_unavailable",
  );
  assert.equal(providerCalls, 0);
});

test("failed finalization leaves the reservation blocking same-ID provider retries", async () => {
  const shared: SharedControlState = { reservations: new Map() };
  const reserveOnly: MentorRequestControls = {
    reserve: sharedControls("participant-a", shared).reserve,
    finish: async () => {
      throw new Error("database unavailable");
    },
  };
  let providerCalls = 0;
  const deps = dependencies({
    controls: reserveOnly,
    provider: {
      generate: async () => {
        providerCalls += 1;
        return {
          output: { message: "Generated once.", followUpQuestions: [], refusal: false },
          model: "test/model",
        };
      },
    },
  });
  await assert.rejects(
    createMentorResponse(request, { id: "participant-a" }, deps),
    (error: unknown) => error instanceof MentorServiceError && error.code === "control_unavailable",
  );
  await assert.rejects(
    createMentorResponse(request, { id: "participant-a" }, deps),
    (error: unknown) =>
      error instanceof MentorServiceError && error.code === "duplicate_in_progress",
  );
  assert.equal(providerCalls, 1);
});