import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { ProviderFailureCategory } from "./provider";

const stateSchema = z.enum(["closed", "open", "half_open"]);
const admissionSchema = z.discriminatedUnion("outcome", [
  z
    .object({ outcome: z.literal("admitted"), state: z.literal("closed") })
    .strict(),
  z
    .object({
      outcome: z.literal("probe"),
      state: z.literal("half_open"),
      probe_token: z.string().uuid(),
    })
    .strict(),
  z
    .object({
      outcome: z.literal("blocked"),
      state: z.enum(["open", "half_open"]),
      retry_after_seconds: z.number().int().positive(),
    })
    .strict(),
]);
const statusSchema = z
  .object({
    state: stateSchema,
    recovery_eligible: z.boolean(),
    retry_after_seconds: z.number().int().nonnegative().optional(),
  })
  .strict();
const resultSchema = z
  .object({
    state: stateSchema,
    failure_count: z.number().int().nonnegative(),
    open_until: z.string().nullable(),
  })
  .strict();

export type MentorCircuitStatus =
  | { state: "closed"; recoveryEligible: false }
  | {
      state: "open";
      recoveryEligible: boolean;
      retryAfterSeconds: number;
    }
  | { state: "half_open"; recoveryEligible: false; retryAfterSeconds: number };

export type MentorCircuitAdmission =
  | { outcome: "admitted"; state: "closed" }
  | { outcome: "probe"; state: "half_open"; probeToken: string }
  | {
      outcome: "blocked";
      state: "open" | "half_open";
      retryAfterSeconds: number;
    };

export type MentorCircuitResult =
  | { outcome: "success" }
  | {
      outcome: "transient_failure";
      failureCategory:
        | "timeout"
        | "network"
        | "provider_5xx"
        | "rate_limited";
    }
  | {
      outcome: "ignored_failure";
      failureCategory:
        | "not_configured"
        | "authentication"
        | "invalid_response"
        | "unknown";
    };

export type MentorCircuitBreaker = {
  status(providerModel: string): Promise<MentorCircuitStatus>;
  admit(providerModel: string): Promise<MentorCircuitAdmission>;
  record(
    providerModel: string,
    admission: MentorCircuitAdmission,
    result: MentorCircuitResult,
    correlationId: string,
  ): Promise<void>;
};

export class MentorCircuitControlError extends Error {
  constructor() {
    super("Mentor provider availability controls are unavailable.");
    this.name = "MentorCircuitControlError";
  }
}

function providerFailureCategory(
  category: ProviderFailureCategory,
): Exclude<MentorCircuitResult, { outcome: "success" }>["failureCategory"] {
  switch (category) {
    case "timeout":
      return "timeout";
    case "network":
      return "network";
    case "rate_limited":
      return "rate_limited";
    case "unavailable":
      return "provider_5xx";
    case "authentication":
      return "authentication";
    case "not_configured":
      return "not_configured";
    case "invalid_response":
      return "invalid_response";
    case "input_too_large":
    case "budget_exceeded":
    case "unknown":
      return "unknown";
  }
}

export function classifyCircuitFailure(
  category: ProviderFailureCategory,
): MentorCircuitResult {
  const failureCategory = providerFailureCategory(category);
  if (
    failureCategory === "timeout" ||
    failureCategory === "network" ||
    failureCategory === "provider_5xx" ||
    failureCategory === "rate_limited"
  ) {
    return { outcome: "transient_failure", failureCategory };
  }
  return { outcome: "ignored_failure", failureCategory };
}

export function createSupabaseMentorCircuitBreaker(
  getClient: () => SupabaseClient,
): MentorCircuitBreaker {
  return {
    async status(providerModel) {
      try {
        const { data, error } = await getClient().rpc(
          "get_mentor_circuit_status",
          { p_provider_model: providerModel },
        );
        if (error) throw error;
        const parsed = statusSchema.safeParse(data);
        if (!parsed.success) throw new Error("Invalid circuit status response");
        if (parsed.data.state === "closed") {
          return { state: "closed", recoveryEligible: false };
        }
        if (parsed.data.state === "open") {
          return {
            state: "open",
            recoveryEligible: parsed.data.recovery_eligible,
            retryAfterSeconds: parsed.data.retry_after_seconds ?? 0,
          };
        }
        return {
          state: "half_open",
          recoveryEligible: false,
          retryAfterSeconds: parsed.data.retry_after_seconds ?? 1,
        };
      } catch {
        throw new MentorCircuitControlError();
      }
    },
    async admit(providerModel) {
      try {
        const probeToken = randomUUID();
        const { data, error } = await getClient().rpc(
          "admit_mentor_provider_call",
          {
            p_provider_model: providerModel,
            p_probe_token: probeToken,
          },
        );
        if (error) throw error;
        const parsed = admissionSchema.safeParse(data);
        if (!parsed.success) throw new Error("Invalid circuit admission response");
        if (parsed.data.outcome === "probe") {
          return {
            outcome: "probe",
            state: "half_open",
            probeToken: parsed.data.probe_token,
          };
        }
        if (parsed.data.outcome === "blocked") {
          return {
            outcome: "blocked",
            state: parsed.data.state,
            retryAfterSeconds: parsed.data.retry_after_seconds,
          };
        }
        return parsed.data;
      } catch {
        throw new MentorCircuitControlError();
      }
    },
    async record(providerModel, admission, result, correlationId) {
      try {
        const { data, error } = await getClient().rpc(
          "record_mentor_provider_result",
          {
            p_provider_model: providerModel,
            p_probe_token:
              admission.outcome === "probe" ? admission.probeToken : null,
            p_outcome: result.outcome,
            p_failure_category:
              result.outcome === "success" ? null : result.failureCategory,
            p_correlation_id: correlationId,
          },
        );
        if (error) throw error;
        if (!resultSchema.safeParse(data).success) {
          throw new Error("Invalid circuit result response");
        }
      } catch {
        throw new MentorCircuitControlError();
      }
    },
  };
}
