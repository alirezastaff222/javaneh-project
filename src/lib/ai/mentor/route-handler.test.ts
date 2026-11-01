import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import { MentorServiceError } from "./service";
import {
  createMentorAvailabilityHandler,
  createMentorPostHandler,
} from "./route-handler";

const validPayload = {
  ideaId: "2eb4f522-0e22-4fdc-a9e1-1f63c378ad51",
  requestId: "adcfb81c-89e2-46ed-91a6-33e2ca4938a3",
  stageKey: "develop_ideas",
  message: "How could I compare these two approaches?",
};

function post(body: string): Request {
  return new Request("https://example.test/api/mentor", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body,
  });
}

test("unauthenticated route requests never invoke mentor orchestration", async () => {
  let executions = 0;
  const handler = createMentorPostHandler({
    authenticate: async () => null,
    execute: async () => {
      executions += 1;
      return {};
    },
  });

  const response = await handler(post(JSON.stringify(validPayload)));
  assert.equal(response.status, 401);
  assert.equal(executions, 0);
});

test("malformed and client-asserted ownership requests fail before orchestration", async () => {
  let executions = 0;
  const handler = createMentorPostHandler({
    authenticate: async () => ({ participantId: "server-user", context: {} }),
    execute: async () => {
      executions += 1;
      return {};
    },
  });

  const malformed = await handler(post("{"));
  assert.equal(malformed.status, 400);
  const forgedOwner = await handler(
    post(JSON.stringify({ ...validPayload, ownerId: "victim-user" })),
  );
  assert.equal(forgedOwner.status, 400);
  assert.equal(executions, 0);
});

test("authenticated requests pass only the server-derived participant to orchestration", async () => {
  let dispatchedParticipantId: string | undefined;
  let dispatchedRequestId: string | undefined;
  const handler = createMentorPostHandler({
    authenticate: async () => ({ participantId: "server-user", context: {} }),
    execute: async (request, participantId) => {
      dispatchedParticipantId = participantId;
      dispatchedRequestId = request.requestId;
      return {
        ok: true,
        suggestion: {
          message: "A suggestion",
          followUpQuestions: [],
          refusal: false,
        },
      };
    },
  });
  const response = await handler(post(JSON.stringify(validPayload)));
  assert.equal(response.status, 200);
  assert.equal(dispatchedParticipantId, "server-user");
  assert.equal(dispatchedRequestId, validPayload.requestId);
  assert.notEqual(dispatchedParticipantId, "victim-user");
});

test("HTTP service errors retain stable status and retry metadata", async () => {
  const handler = createMentorPostHandler({
    authenticate: async () => ({ participantId: "server-user", context: {} }),
    execute: async () => {
      throw new MentorServiceError("rate_limited", 17);
    },
  });
  const response = await handler(
    post(JSON.stringify({ ...validPayload, requestId: randomUUID() })),
  );
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("retry-after"), "17");
});

test("availability is authenticated and reports only the public status without probing", async () => {
  let availabilityCalls = 0;
  const unavailable = createMentorAvailabilityHandler({
    authenticate: async () => null,
    getAvailability: async () => {
      availabilityCalls += 1;
      return { status: "available" };
    },
  });
  const unauthorized = await unavailable();
  assert.equal(unauthorized.status, 401);
  assert.equal(availabilityCalls, 0);

  const handler = createMentorAvailabilityHandler({
    authenticate: async () => ({ participantId: "participant", context: {} }),
    getAvailability: async () => {
      availabilityCalls += 1;
      return { status: "recovery_eligible", retryAfterSeconds: 0 };
    },
  });
  const response = await handler();
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), {
    status: "recovery_eligible",
    retryAfterSeconds: 0,
  });
  assert.equal(availabilityCalls, 1);
});