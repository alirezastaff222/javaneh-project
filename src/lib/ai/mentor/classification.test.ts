import assert from "node:assert/strict";
import { test } from "node:test";
import {
  InvalidClassificationOutputError,
  validateClassificationOutput,
  type ActiveClassificationAxis,
} from "./classification-contracts";
import {
  ClassificationDispatchGate,
  getClassificationDispatchDecision,
  shouldDispatchAfterConfirmation,
} from "./classification-dispatch";
import {
  classifyIdea,
  type ClassificationPersistence,
  type ClassificationSource,
} from "./classification-service";
import type { MentorCircuitBreaker } from "./circuit-breaker";
import { MentorProviderError } from "./provider";

const axes: ActiveClassificationAxis[] = [
  { axis_id: "resource_efficiency", official_name: "a", official_definition: "a", active: true },
  { axis_id: "domestic_production", official_name: "b", official_definition: "b", active: true },
  { axis_id: "economic_mutual_aid", official_name: "c", official_definition: "c", active: true },
  { axis_id: "social_resilience", official_name: "d", official_definition: "d", active: true },
  { axis_id: "social_mobilization", official_name: "e", official_definition: "e", active: true },
  { axis_id: "vulnerable_empowerment", official_name: "f", official_definition: "f", active: true },
];

const source: ClassificationSource = {
  ideaId: "2eb4f522-0e22-4fdc-a9e1-1f63c378ad51",
  participantId: "adcfb81c-89e2-46ed-91a6-33e2ca4938a3",
  stage1: {
    revisionId: "a9940000-0000-4000-8000-000000000001",
    content: "Confirmed problem text.",
  },
  stage2: {
    revisionId: "a9940000-0000-4000-8000-000000000002",
    content: "Confirmed capacity text.",
  },
  taxonomyVersion: "phase7.v1",
  axes,
};

test("pending state dispatches on initial panel load", () => {
  assert.deepEqual(
    getClassificationDispatchDecision(
      {
        status: "pending",
        attempt_count: 0,
        last_failure_category: null,
        retry_after: null,
        lease_expires_at: null,
      },
      Date.now(),
    ),
    { kind: "dispatch" },
  );
});

test("current, active processing, and permanent failures do not dispatch", () => {
  const now = Date.now();
  for (const state of [
    {
      status: "current" as const,
      attempt_count: 0,
      last_failure_category: null,
      retry_after: null,
      lease_expires_at: null,
    },
    {
      status: "processing" as const,
      attempt_count: 1,
      last_failure_category: null,
      retry_after: null,
      lease_expires_at: new Date(now + 60_000).toISOString(),
    },
    {
      status: "failed" as const,
      attempt_count: 1,
      last_failure_category: "not_configured",
      retry_after: null,
      lease_expires_at: null,
    },
  ]) {
    assert.notEqual(
      getClassificationDispatchDecision(state, now).kind,
      "dispatch",
    );
  }
});

test("repeated renders cannot dispatch the same state key repeatedly", () => {
  const gate = new ClassificationDispatchGate();
  assert.equal(gate.begin("idea:pending:source-a:source-b"), true);
  gate.finish();
  assert.equal(gate.begin("idea:pending:source-a:source-b"), false);
  assert.equal(gate.begin("idea:processing:attempt-2"), true);
});

test("only qualifying Stage 1/2 confirmations dispatch classification", () => {
  assert.equal(
    shouldDispatchAfterConfirmation({
      stageNumber: 2,
      outcome: "confirmed",
      otherStageConfirmed: false,
    }),
    true,
  );
  assert.equal(
    shouldDispatchAfterConfirmation({
      stageNumber: 1,
      outcome: "confirmed",
      otherStageConfirmed: true,
    }),
    true,
  );
  assert.equal(
    shouldDispatchAfterConfirmation({
      stageNumber: 1,
      outcome: "confirmed",
      otherStageConfirmed: false,
    }),
    false,
  );
  assert.equal(
    shouldDispatchAfterConfirmation({
      stageNumber: 3,
      outcome: "confirmed",
      otherStageConfirmed: true,
    }),
    false,
  );
  assert.equal(
    shouldDispatchAfterConfirmation({
      stageNumber: 2,
      outcome: "already_confirmed",
      otherStageConfirmed: true,
    }),
    false,
  );
});

test("retryable failures wait for the bounded retry time and exhausted failures stop", () => {
  const now = Date.now();
  const retryState = {
    status: "failed" as const,
    attempt_count: 1,
    last_failure_category: "timeout",
    retry_after: new Date(now + 30_000).toISOString(),
    lease_expires_at: null,
  };
  assert.deepEqual(
    getClassificationDispatchDecision(retryState, now),
    { kind: "wait", delayMs: 30_000 },
  );
  assert.deepEqual(
    getClassificationDispatchDecision(retryState, now + 31_000),
    { kind: "dispatch" },
  );
  assert.deepEqual(
    getClassificationDispatchDecision(
      { ...retryState, attempt_count: 3 },
      now + 31_000,
    ),
    { kind: "none" },
  );
});

test("expired processing lease is redispatched but an active lease is not", () => {
  const now = Date.now();
  const processingState = {
    status: "processing" as const,
    attempt_count: 1,
    last_failure_category: null,
    retry_after: null,
    lease_expires_at: new Date(now - 1).toISOString(),
  };
  assert.deepEqual(
    getClassificationDispatchDecision(processingState, now),
    { kind: "dispatch" },
  );
  assert.deepEqual(
    getClassificationDispatchDecision(
      {
        ...processingState,
        lease_expires_at: new Date(now + 1_000).toISOString(),
      },
      now,
    ),
    { kind: "wait", delayMs: 1_250 },
  );
});

function output(
  percentages: [number, number, number] = [60, 25, 15],
): unknown {
  return {
    primary_axis_id: "resource_efficiency",
    secondary_axis_ids: ["domestic_production", "economic_mutual_aid"],
    axes: [
      {
        axis_id: "resource_efficiency",
        percentage: percentages[0],
        rationale: "Primary relevance.",
      },
      {
        axis_id: "domestic_production",
        percentage: percentages[1],
        rationale: "Secondary relevance one.",
      },
      {
        axis_id: "economic_mutual_aid",
        percentage: percentages[2],
        rationale: "Secondary relevance two.",
      },
    ],
    confidence: 0.81,
  };
}

test("validates different integer thematic distributions and separate confidence", () => {
  for (const distribution of [
    [70, 20, 10],
    [60, 25, 15],
    [55, 30, 15],
  ] as const) {
    const result = validateClassificationOutput(output([...distribution]), axes);
    assert.equal(
      result.primaryPercentage +
        result.secondaryPercentages[0] +
        result.secondaryPercentages[1],
      100,
    );
    assert.equal(result.confidence, 0.81);
    assert.notEqual(result.primaryPercentage, result.confidence);
  }
});

test("requires exactly three distinct axes and two secondary axes", () => {
  const duplicate = output();
  assert.throws(() => {
    validateClassificationOutput(
      {
        ...(duplicate as Record<string, unknown>),
        secondary_axis_ids: ["domestic_production", "resource_efficiency"],
      },
      axes,
    );
  }, InvalidClassificationOutputError);

  assert.throws(() => {
    validateClassificationOutput(
      { ...(duplicate as Record<string, unknown>), secondary_axis_ids: ["domestic_production"] },
      axes,
    );
  }, InvalidClassificationOutputError);
});

test("rejects unknown and inactive axes", () => {
  const invalid = output();
  assert.throws(() => {
    validateClassificationOutput(
      {
        ...(invalid as Record<string, unknown>),
        primary_axis_id: "unapproved_axis",
        axes: (invalid as { axes: unknown[] }).axes.map((entry) =>
          (entry as { axis_id: string }).axis_id === "resource_efficiency"
            ? { ...(entry as Record<string, unknown>), axis_id: "unapproved_axis" }
            : entry,
        ),
      },
      axes,
    );
  }, InvalidClassificationOutputError);

  assert.throws(() => {
    validateClassificationOutput(output(), [
      ...axes.slice(0, 5),
      { ...axes[5], active: false },
    ]);
  }, InvalidClassificationOutputError);
});

test("rejects non-integer, non-100, tied, and non-dominant primary percentages", () => {
  for (const distribution of [
    [60.5, 25, 14.5],
    [60, 25, 14],
    [40, 40, 20],
    [30, 35, 35],
  ] as const) {
    assert.throws(
      () => validateClassificationOutput(output([...distribution]), axes),
      InvalidClassificationOutputError,
    );
  }
});

test("requires rationale for each selected axis and keeps confidence separate", () => {
  const invalid = output();
  const entries = (invalid as { axes: Array<Record<string, unknown>> }).axes;
  assert.throws(() => {
    validateClassificationOutput(
      {
        ...(invalid as Record<string, unknown>),
        axes: entries.map((entry) =>
          entry.axis_id === "economic_mutual_aid"
            ? { ...entry, rationale: " " }
            : entry,
        ),
      },
      axes,
    );
  }, InvalidClassificationOutputError);

  assert.throws(() => {
    validateClassificationOutput(
      { ...(invalid as Record<string, unknown>), confidence: 100 },
      axes,
    );
  }, InvalidClassificationOutputError);
});

test("rejects malformed or extra structured fields", () => {
  const invalid = output();
  assert.throws(() => {
    validateClassificationOutput(
      { ...(invalid as Record<string, unknown>), participant_id: "private" },
      axes,
    );
  }, InvalidClassificationOutputError);
  assert.throws(
    () => validateClassificationOutput(output(), axes.slice(0, 5)),
    InvalidClassificationOutputError,
  );
});

test("a successful classification validates output and persists a current result", async () => {
  let completed = false;
  const persistence: ClassificationPersistence = {
    claim: async ({ attemptToken }) => ({
      outcome: "claimed",
      attempt_token: attemptToken,
    }),
    complete: async () => {
      completed = true;
      return {
        outcome: "completed",
        classification_id: "a9980000-0000-4000-8000-000000000001",
      };
    },
    fail: async () => ({ outcome: "failed" }),
  };
  const circuit: MentorCircuitBreaker = {
    status: async () => ({ state: "closed", recoveryEligible: false }),
    admit: async () => ({ outcome: "admitted", state: "closed" }),
    record: async () => undefined,
  };

  const status = await classifyIdea(source, {
    persistence,
    circuit,
    provider: {
      circuitKey: () => "vercel-ai-gateway:test/model",
      generate: async () => ({
        output: output(),
        model: "test/model",
      }),
    },
    sleep: async () => undefined,
  });

  assert.equal(status, "current");
  assert.equal(completed, true);
});

test("provider outages are bounded, persisted as retryable failures, and use the shared circuit", async () => {
  let calls = 0;
  let failureCategory = "";
  let recordedFailure = false;
  const persistence: ClassificationPersistence = {
    claim: async ({ attemptToken }) => ({
      outcome: "claimed",
      attempt_token: attemptToken,
    }),
    complete: async () => ({ outcome: "completed", classification_id: "a9980000-0000-4000-8000-000000000001" }),
    fail: async ({ category }) => {
      failureCategory = category;
      return { outcome: "failed" };
    },
  };
  const circuit: MentorCircuitBreaker = {
    status: async () => ({ state: "closed", recoveryEligible: false }),
    admit: async () => ({ outcome: "admitted", state: "closed" }),
    record: async (_providerModel, _admission, result) => {
      recordedFailure = result.outcome === "transient_failure";
    },
  };

  const status = await classifyIdea(source, {
    persistence,
    circuit,
    provider: {
      circuitKey: () => "vercel-ai-gateway:test/model",
      generate: async () => {
        calls += 1;
        throw new MentorProviderError("unavailable", true);
      },
    },
    sleep: async () => undefined,
  });

  assert.equal(status, "failed");
  assert.equal(calls, 2);
  assert.equal(failureCategory, "unavailable");
  assert.equal(recordedFailure, true);
});

test("an active logical classification is not sent to the provider again", async () => {
  let providerCalls = 0;
  const persistence: ClassificationPersistence = {
    claim: async () => ({ outcome: "in_progress" }),
    complete: async () => ({ outcome: "completed", classification_id: "a9980000-0000-4000-8000-000000000001" }),
    fail: async () => ({ outcome: "failed" }),
  };
  const circuit: MentorCircuitBreaker = {
    status: async () => ({ state: "closed", recoveryEligible: false }),
    admit: async () => ({ outcome: "admitted", state: "closed" }),
    record: async () => undefined,
  };
  const status = await classifyIdea(source, {
    persistence,
    circuit,
    provider: {
      generate: async () => {
        providerCalls += 1;
        return { output: output(), model: "test/model" };
      },
    },
  });

  assert.equal(status, "processing");
  assert.equal(providerCalls, 0);
});

test("retry-wait and exhausted claims never reach the provider", async () => {
  const circuit: MentorCircuitBreaker = {
    status: async () => ({ state: "closed", recoveryEligible: false }),
    admit: async () => ({ outcome: "admitted", state: "closed" }),
    record: async () => undefined,
  };
  for (const claim of [
    {
      outcome: "retry_wait" as const,
      retry_after: new Date(Date.now() + 30_000).toISOString(),
    },
    { outcome: "retry_exhausted" as const },
  ]) {
    let providerCalls = 0;
    const persistence: ClassificationPersistence = {
      claim: async () => claim,
      complete: async () => ({
        outcome: "completed",
        classification_id: "a9980000-0000-4000-8000-000000000001",
      }),
      fail: async () => ({ outcome: "failed" }),
    };
    const status = await classifyIdea(source, {
      persistence,
      circuit,
      provider: {
        generate: async () => {
          providerCalls += 1;
          return { output: output(), model: "test/model" };
        },
      },
    });

    assert.equal(status, "failed");
    assert.equal(providerCalls, 0);
  }
});
