import "server-only";

import { gateway } from "@ai-sdk/gateway";
import {
  generateText,
  NoObjectGeneratedError,
  Output,
} from "ai";
import { mentorProviderResponseSchema } from "./contracts";

export const DEFAULT_MENTOR_MODEL = "anthropic/claude-haiku-4.5";
export const MENTOR_MAX_INPUT_BYTES = 16_000;
export const MENTOR_MAX_OUTPUT_TOKENS = 600;

export type ProviderFailureCategory =
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

export class MentorProviderError extends Error {
  constructor(
    readonly category: ProviderFailureCategory,
    readonly retryable: boolean,
  ) {
    super(category);
    this.name = "MentorProviderError";
  }
}

export type MentorGenerationInput = {
  system: string;
  prompt: string;
  signal: AbortSignal;
};

export type MentorGenerationResult = {
  output: unknown;
  model: string;
  inputTokens?: number;
  outputTokens?: number;
};

export type MentorModelProvider = {
  prepare?(): void;
  circuitKey?(): string;
  probe?(input: { signal: AbortSignal }): Promise<void>;
  generate(input: MentorGenerationInput): Promise<MentorGenerationResult>;
};

type MentorEnvironment = {
  AI_MENTOR_MODEL?: string;
  AI_GATEWAY_API_KEY?: string;
  VERCEL_OIDC_TOKEN?: string;
  VERCEL?: string;
};

const runtimeMentorEnvironment: MentorEnvironment = {
  AI_MENTOR_MODEL: process.env.AI_MENTOR_MODEL,
  AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY,
  VERCEL_OIDC_TOKEN: process.env.VERCEL_OIDC_TOKEN,
  VERCEL: process.env.VERCEL,
};

export function getMentorModelConfiguration(
  environment: MentorEnvironment = runtimeMentorEnvironment,
): { model: string; configured: boolean } {
  const model = environment.AI_MENTOR_MODEL?.trim() || DEFAULT_MENTOR_MODEL;
  const modelIsValid =
    /^[a-z0-9][a-z0-9._-]{0,80}\/[a-z0-9][a-z0-9._-]{0,120}$/i.test(model);
  const hasAuthentication = Boolean(
    environment.AI_GATEWAY_API_KEY?.trim() ||
      environment.VERCEL_OIDC_TOKEN?.trim() ||
      environment.VERCEL === "1",
  );

  if (!modelIsValid) {
    throw new MentorProviderError("not_configured", false);
  }

  return { model, configured: hasAuthentication };
}

function readStatusCode(error: unknown): number | undefined {
  if (!error || typeof error !== "object") return undefined;
  const record = error as Record<string, unknown>;
  const response = record.response;
  if (response && typeof response === "object") {
    const responseStatus = (response as Record<string, unknown>).status;
    if (typeof responseStatus === "number") return responseStatus;
  }
  const cause = record.cause;
  if (cause && typeof cause === "object") {
    const causeStatus = (cause as Record<string, unknown>).status;
    if (typeof causeStatus === "number") return causeStatus;
  }
  const status = record.statusCode ?? record.status;
  return typeof status === "number" ? status : undefined;
}

function readErrorText(error: unknown): string {
  if (!error || typeof error !== "object") return "";
  const record = error as Record<string, unknown>;
  const nestedError =
    record.error && typeof record.error === "object"
      ? (record.error as Record<string, unknown>)
      : undefined;
  const values = [
    typeof record.message === "string" ? record.message : "",
    typeof record.error === "string" ? record.error : "",
    typeof record.code === "string" ? record.code : "",
    nestedError?.code,
    nestedError?.message,
    typeof record.cause === "string" ? record.cause : "",
    record.cause && typeof record.cause === "object"
      ? (record.cause as Record<string, unknown>).message
      : "",
    record.response && typeof record.response === "object"
      ? (record.response as Record<string, unknown>).statusText
      : "",
  ];
  return values.filter(Boolean).join(" ");
}

function isPermanentConfigurationError(error: unknown): boolean {
  const text = readErrorText(error).toLowerCase();
  if (!text) return false;
  return /model_not_found|model_not_supported|unsupported_model|invalid_model|unknown_model|invalid_api_key|missing_api_key|authentication_error|invalid_credentials|credentials_missing|provider_not_configured|api_key_invalid|api_key_missing|model.*(not found|unsupported|unknown|invalid)|unknown model|unsupported model|invalid.*model|missing.*model|missing.*api key|invalid.*api key|provider.*not configured|authentication.*required|api key.*(missing|invalid)|credential.*(missing|invalid)/i.test(text);
}

export function normalizeProviderError(
  error: unknown,
  signal?: AbortSignal,
): MentorProviderError {
  if (error instanceof MentorProviderError) return error;
  if (signal?.aborted || (error instanceof Error && error.name === "AbortError")) {
    return new MentorProviderError("timeout", true);
  }
  if (NoObjectGeneratedError.isInstance(error)) {
    return new MentorProviderError("invalid_response", false);
  }

  const status = readStatusCode(error);
  if (status === 429) return new MentorProviderError("rate_limited", true);
  if (status === 402) return new MentorProviderError("budget_exceeded", false);
  if (status === 401 || status === 403) {
    return new MentorProviderError("authentication", false);
  }
  if (isPermanentConfigurationError(error)) {
    return new MentorProviderError("not_configured", false);
  }
  if (status === 408) return new MentorProviderError("timeout", true);
  if (status === 425 || (status !== undefined && status >= 500)) {
    return new MentorProviderError("unavailable", true);
  }

  if (
    error instanceof TypeError ||
    (error instanceof Error && /fetch|network|socket|connection/i.test(error.message))
  ) {
    return new MentorProviderError("network", true);
  }

  return new MentorProviderError("unknown", false);
}

export function validateMentorInputBudget(input: {
  system: string;
  prompt: string;
}): void {
  const inputBytes =
    Buffer.byteLength(input.system, "utf8") +
    Buffer.byteLength(input.prompt, "utf8");
  if (inputBytes > MENTOR_MAX_INPUT_BYTES) {
    throw new MentorProviderError("input_too_large", false);
  }
}

export function createGatewayMentorProvider(): MentorModelProvider {
  function prepare(): void {
    const { configured } = getMentorModelConfiguration();
    if (!configured) throw new MentorProviderError("not_configured", false);
  }

  return {
    prepare,
    circuitKey() {
      return `vercel-ai-gateway:${getMentorModelConfiguration().model}`;
    },
    async probe({ signal }) {
      const { model, configured } = getMentorModelConfiguration();
      if (!configured) {
        throw new MentorProviderError("not_configured", false);
      }

      try {
        const result = await generateText({
          model: gateway(model),
          prompt: "Reply with OK.",
          maxOutputTokens: 2,
          maxRetries: 0,
          abortSignal: signal,
        });
        if (!result.text.trim()) {
          throw new MentorProviderError("invalid_response", false);
        }
      } catch (error) {
        throw normalizeProviderError(error, signal);
      }
    },
    async generate(input) {
      validateMentorInputBudget(input);
      const { model, configured } = getMentorModelConfiguration();
      if (!configured) {
        throw new MentorProviderError("not_configured", false);
      }

      try {
        const result = await generateText({
          model: gateway(model),
          system: input.system,
          prompt: input.prompt,
          output: Output.object({ schema: mentorProviderResponseSchema }),
          maxOutputTokens: MENTOR_MAX_OUTPUT_TOKENS,
          maxRetries: 0,
          abortSignal: input.signal,
        });

        return {
          output: result.output,
          model,
          inputTokens: result.usage.inputTokens ?? undefined,
          outputTokens: result.usage.outputTokens ?? undefined,
        };
      } catch (error) {
        throw normalizeProviderError(error, input.signal);
      }
    },
  };
}