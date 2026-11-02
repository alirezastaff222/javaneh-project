import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import type {
  MentorCircuitAdmission,
  MentorCircuitBreaker,
  MentorCircuitResult,
} from "./circuit-breaker";
import {
  classifyCircuitFailure,
} from "./circuit-breaker";
import {
  MentorProviderError,
  normalizeProviderError,
} from "./provider";

type CircuitState = {
  state: "closed" | "open" | "half_open";
  failures: number;
  windowStartedAt: number | null;
  openUntil: number | null;
  probeToken: string | null;
  probeStartedAt: number | null;
  openCount: number;
};

function sharedCircuit(now: () => number) {
  const states = new Map<string, CircuitState>();
  const events: Array<{ model: string; from: string; to: string }> = [];
  function circuit(): MentorCircuitBreaker {
    return {
      async status(model) {
        const state = states.get(model);
        if (!state || state.state === "closed") {
          return { state: "closed", recoveryEligible: false };
        }
        if (state.state === "open") {
          return {
            state: "open",
            recoveryEligible: state.openUntil! <= now(),
            retryAfterSeconds: Math.max(0, Math.ceil((state.openUntil! - now()) / 1000)),
          };
        }
        return {
          state: "half_open",
          recoveryEligible: false,
          retryAfterSeconds: Math.max(
            1,
            Math.ceil((state.probeStartedAt! + 30_000 - now()) / 1_000),
          ),
        };
      },
      async admit(model) {
        const state = states.get(model) ?? {
          state: "closed" as const,
          failures: 0,
          windowStartedAt: null,
          openUntil: null,
          probeToken: null,
          probeStartedAt: null,
          openCount: 0,
        };
        states.set(model, state);
        if (state.state === "closed") {
          return { outcome: "admitted", state: "closed" };
        }
        if (state.state === "open" && state.openUntil! <= now()) {
          const from = state.state;
          state.state = "half_open";
          state.openUntil = null;
          state.probeToken = randomUUID();
          state.probeStartedAt = now();
          events.push({ model, from, to: state.state });
          return {
            outcome: "probe",
            state: "half_open",
            probeToken: state.probeToken,
          };
        }
        if (
          state.state === "half_open" &&
          state.probeStartedAt! + 30_000 <= now()
        ) {
          const from = state.state;
          state.state = "open";
          state.openCount += 1;
          state.openUntil = now() + 60_000;
          state.probeToken = null;
          state.probeStartedAt = null;
          events.push({ model, from, to: state.state });
          return {
            outcome: "blocked",
            state: "open",
            retryAfterSeconds: 60,
          };
        }
        return {
          outcome: "blocked",
          state: state.state,
          retryAfterSeconds:
            state.state === "open"
              ? Math.max(1, Math.ceil((state.openUntil! - now()) / 1_000))
              : Math.max(1, Math.ceil((state.probeStartedAt! + 30_000 - now()) / 1_000)),
        };
      },
      async record(model, admission, result, correlationId) {
        assert.match(correlationId, /^[0-9a-f-]{36}$/i);
        const state = states.get(model);
        assert.ok(state);
        const from = state.state;
        if (admission.outcome === "probe") {
          assert.equal(state.probeToken, admission.probeToken);
          state.probeToken = null;
          state.probeStartedAt = null;
          if (result.outcome === "transient_failure") {
            state.state = "open";
            state.openCount += 1;
            state.openUntil =
              now() +
              (state.openCount === 2
                ? 120_000
                : state.openCount === 3
                  ? 240_000
                  : 300_000);
          } else {
            state.state = "closed";
            state.openUntil = null;
            state.failures = 0;
            state.windowStartedAt = null;
            state.openCount = 0;
          }
        } else if (state.state === "closed") {
          if (result.outcome === "success") {
            state.failures = 0;
            state.windowStartedAt = null;
          } else if (result.outcome === "transient_failure") {
            if (
              state.windowStartedAt === null ||
              state.windowStartedAt < now() - 300_000
            ) {
              state.windowStartedAt = now();
              state.failures = 1;
            } else {
              state.failures += 1;
            }
            if (state.failures >= 3) {
              state.state = "open";
              state.openUntil = now() + 60_000;
              state.openCount = 1;
            }
          }
        }
        if (state.state !== from) {
          events.push({ model, from, to: state.state });
        }
      },
    };
  }
  return { circuit, states, events };
}

const transientFailure: MentorCircuitResult = {
  outcome: "transient_failure",
  failureCategory: "provider_5xx",
};

test("three transient failures open the circuit and requests are blocked through cooldown", async () => {
  let time = 10_000;
  const shared = sharedCircuit(() => time);
  const circuit = shared.circuit();
  const model = "google.generative-ai:test/model";

  for (let index = 0; index < 3; index += 1) {
    const admission = await circuit.admit(model);
    await circuit.record(model, admission, transientFailure, randomUUID());
  }
  assert.equal((await circuit.status(model)).state, "open");
  assert.deepEqual(await circuit.admit(model), {
    outcome: "blocked",
    state: "open",
    retryAfterSeconds: 60,
  });

  time += 60_000;
  const probe = await circuit.admit(model);
  assert.equal(probe.outcome, "probe");
  assert.equal((await circuit.status(model)).state, "half_open");
});

test("successful recovery closes the circuit; transient probe failure reopens with backoff", async () => {
  let time = 1_000;
  const shared = sharedCircuit(() => time);
  const circuit = shared.circuit();
  const model = "google.generative-ai:test/model";
  for (let index = 0; index < 3; index += 1) {
    const admission = await circuit.admit(model);
    await circuit.record(model, admission, transientFailure, randomUUID());
  }
  time += 60_000;
  const recovery = await circuit.admit(model);
  await circuit.record(model, recovery, { outcome: "success" }, randomUUID());
  assert.equal((await circuit.status(model)).state, "closed");

  for (let index = 0; index < 3; index += 1) {
    const admission = await circuit.admit(model);
    await circuit.record(model, admission, transientFailure, randomUUID());
  }
  time += 60_000;
  const failedProbe = await circuit.admit(model);
  await circuit.record(model, failedProbe, transientFailure, randomUUID());
  assert.deepEqual(await circuit.status(model), {
    state: "open",
    recoveryEligible: false,
    retryAfterSeconds: 120,
  });
});

test("independent service instances share one half-open probe admission", async () => {
  let time = 5_000;
  const shared = sharedCircuit(() => time);
  const firstInstance = shared.circuit();
  const secondInstance = shared.circuit();
  const model = "google.generative-ai:test/model";
  for (let index = 0; index < 3; index += 1) {
    const admission = await firstInstance.admit(model);
    await firstInstance.record(model, admission, transientFailure, randomUUID());
  }
  time += 60_000;

  const admissions = await Promise.all([
    firstInstance.admit(model),
    secondInstance.admit(model),
  ]);
  assert.equal(admissions.filter((entry) => entry.outcome === "probe").length, 1);
  assert.equal(admissions.filter((entry) => entry.outcome === "blocked").length, 1);
});

test("a stale recovery lease expires safely without admitting another concurrent probe", async () => {
  let time = 20_000;
  const shared = sharedCircuit(() => time);
  const circuit = shared.circuit();
  const model = "google.generative-ai:test/model";
  for (let index = 0; index < 3; index += 1) {
    const admission = await circuit.admit(model);
    await circuit.record(model, admission, transientFailure, randomUUID());
  }
  time += 60_000;
  const probe: MentorCircuitAdmission = await circuit.admit(model);
  assert.equal(probe.outcome, "probe");
  time += 31_000;
  assert.deepEqual(await circuit.admit(model), {
    outcome: "blocked",
    state: "open",
    retryAfterSeconds: 60,
  });
  assert.equal((await circuit.status(model)).state, "open");
});

test("only transient provider failures contribute to the circuit", () => {
  const cases = [
    [normalizeProviderError(new Error("network connection failed")), "network", true],
    [normalizeProviderError({ status: 503 }), "unavailable", true],
    [normalizeProviderError({ status: 429 }), "rate_limited", true],
    [normalizeProviderError({ status: 401, code: "invalid_api_key" }), "authentication", false],
    [
      normalizeProviderError({ status: 404, code: "model_not_found" }),
      "not_configured",
      false,
    ],
    [
      normalizeProviderError({ status: 400, code: "invalid_argument" }),
      "unknown",
      false,
    ],
    [
      normalizeProviderError({ status: 422, message: "Invalid request schema" }),
      "unknown",
      false,
    ],
  ] as const;

  for (const [providerError, expectedCategory, retryable] of cases) {
    assert.equal(providerError.category, expectedCategory);
    assert.equal(providerError.retryable, retryable);
    const result = classifyCircuitFailure(providerError.category);
    assert.equal(
      result.outcome,
      retryable ? "transient_failure" : "ignored_failure",
    );
  }
  assert.equal(
    classifyCircuitFailure(
      new MentorProviderError("not_configured", false).category,
    ).outcome,
    "ignored_failure",
  );
});
