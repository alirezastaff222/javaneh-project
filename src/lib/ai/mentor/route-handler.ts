import { NextResponse } from "next/server";
import {
  mentorAvailabilityResponseSchema,
  mentorFailureResponseSchema,
  participantMentorRequestSchema,
} from "./contracts";
import { MentorServiceError } from "./service";

const failureMessages = {
  invalid_request: "The mentor request is invalid.",
  unauthenticated: "Authentication is required.",
  idea_unavailable: "The idea is unavailable.",
  stage_forbidden: "The requested stage is not available for mentoring.",
  rate_limited: "Too many mentor requests. Please try again later.",
  duplicate_in_progress: "This mentor request is already processing.",
  duplicate_request: "This mentor request ID has already been used.",
  control_unavailable: "Request protection is temporarily unavailable.",
  not_configured: "The AI mentor is not configured.",
  input_too_large: "The mentor request and context exceed the input limit.",
  provider_timeout: "The AI mentor did not respond in time.",
  provider_rate_limited: "The AI mentor is temporarily rate limited.",
  provider_budget_exceeded: "The AI mentor usage budget is exhausted.",
  provider_unavailable: "The AI mentor is temporarily unavailable.",
  circuit_open: "AI assistance is temporarily paused while the service recovers.",
  circuit_control_unavailable: "AI availability could not be checked safely.",
  invalid_provider_response: "The AI mentor returned an invalid response.",
  context_unavailable: "Idea context could not be loaded.",
  internal_error: "The mentor request could not be completed.",
} as const;

const statusForCode = {
  invalid_request: 400,
  unauthenticated: 401,
  idea_unavailable: 404,
  stage_forbidden: 403,
  rate_limited: 429,
  duplicate_in_progress: 409,
  duplicate_request: 409,
  control_unavailable: 503,
  not_configured: 503,
  input_too_large: 413,
  provider_timeout: 504,
  provider_rate_limited: 503,
  provider_budget_exceeded: 503,
  provider_unavailable: 503,
  circuit_open: 503,
  circuit_control_unavailable: 503,
  invalid_provider_response: 502,
  context_unavailable: 503,
  internal_error: 500,
} as const;

function failure(code: keyof typeof failureMessages, status?: number) {
  const body = mentorFailureResponseSchema.parse({
    ok: false,
    error: { code, message: failureMessages[code] },
  });
  return NextResponse.json(body, { status: status ?? statusForCode[code] });
}

export function createMentorPostHandler<TContext>(dependencies: {
  authenticate(): Promise<
    { participantId: string; context: TContext } | null
  >;
  execute(
    request: ReturnType<typeof participantMentorRequestSchema.parse>,
    participantId: string,
    context: TContext,
  ): Promise<unknown>;
}) {
  return async function handleMentorPost(request: Request) {
    let authenticated: Awaited<ReturnType<typeof dependencies.authenticate>>;
    try {
      authenticated = await dependencies.authenticate();
    } catch {
      return failure("internal_error");
    }

    if (!authenticated) return failure("unauthenticated");

    const contentLength = Number(request.headers.get("content-length") ?? 0);
    if (contentLength > 16_000) return failure("invalid_request");

    let rawBody: string;
    try {
      rawBody = await request.text();
    } catch {
      return failure("invalid_request");
    }
    if (Buffer.byteLength(rawBody, "utf8") > 16_000) {
      return failure("invalid_request");
    }

    let body: unknown;
    try {
      body = JSON.parse(rawBody);
    } catch {
      return failure("invalid_request");
    }

    const parsedRequest = participantMentorRequestSchema.safeParse(body);
    if (!parsedRequest.success) return failure("invalid_request");

    try {
      const result = await dependencies.execute(
        parsedRequest.data,
        authenticated.participantId,
        authenticated.context,
      );
      return NextResponse.json(result);
    } catch (error) {
      if (error instanceof MentorServiceError) {
        const response = failure(error.code);
        if (error.retryAfterSeconds) {
          response.headers.set("Retry-After", String(error.retryAfterSeconds));
        }
        return response;
      }
      console.error(
        JSON.stringify({
          event: "mentor.request",
          status: "error",
          errorCategory: "internal_error",
        }),
      );
      return failure("internal_error");
    }
  };
}

export function createMentorAvailabilityHandler<TContext>(dependencies: {
  authenticate(): Promise<
    { participantId: string; context: TContext } | null
  >;
  getAvailability(context: TContext): Promise<unknown>;
}) {
  return async function handleMentorAvailability() {
    let authenticated: Awaited<ReturnType<typeof dependencies.authenticate>>;
    try {
      authenticated = await dependencies.authenticate();
    } catch {
      console.warn(
        JSON.stringify({
          event: "mentor.availability",
          status: "error",
          errorCategory: "authentication_check_failed",
        }),
      );
      return NextResponse.json(
        { status: "temporarily_unavailable" },
        { status: 503, headers: { "Cache-Control": "no-store" } },
      );
    }
    if (!authenticated) {
      return NextResponse.json(
        { error: "unauthenticated" },
        { status: 401, headers: { "Cache-Control": "no-store" } },
      );
    }
    try {
      const body = mentorAvailabilityResponseSchema.parse(
        await dependencies.getAvailability(authenticated.context),
      );
      return NextResponse.json(body, {
        headers: { "Cache-Control": "no-store" },
      });
    } catch {
      console.warn(
        JSON.stringify({
          event: "mentor.availability",
          status: "error",
          errorCategory: "availability_check_failed",
        }),
      );
      return NextResponse.json(
        { status: "temporarily_unavailable" },
        { status: 503, headers: { "Cache-Control": "no-store" } },
      );
    }
  };
}