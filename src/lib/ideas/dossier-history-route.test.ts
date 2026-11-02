import assert from "node:assert/strict";
import test from "node:test";
import {
  createDossierHistoryHandler,
  DossierHistoryUnavailableError,
} from "./dossier-history-route";

const ideaId = "a9a10000-0000-4000-8000-000000000001";

function historyResponse(revision = 2) {
  return [
    {
      revision,
      created_at: "2026-11-01T10:00:00Z",
      dossier: {
        stages: Array.from({ length: 6 }, (_, index) => ({
          stage_number: index + 1,
          stage_key: `stage_${index + 1}`,
          data: { content: `Stage ${index + 1}` },
          confirmed_at: "2026-11-01T09:00:00Z",
        })),
      },
      actor_id: "internal-actor",
      request_id: "internal-request",
    },
  ];
}

function get(url: string) {
  return new Request(`https://example.test/api/ideas/history${url}`);
}

test("requires an authenticated session and never calls history for anonymous users", async () => {
  let queries = 0;
  const handler = createDossierHistoryHandler({
    authenticate: async () => null,
    fetchHistory: async () => {
      queries += 1;
      return [];
    },
  });

  const response = await handler(get(`?ideaId=${ideaId}`));
  assert.equal(response.status, 401);
  assert.equal(response.headers.get("cache-control"), "private, no-store");
  assert.equal(queries, 0);
});

test("maps a missing auth session to 401 without querying history", async () => {
  let queries = 0;
  const handler = createDossierHistoryHandler({
    authenticate: async () => {
      throw { name: "AuthSessionMissingError", status: 400 };
    },
    fetchHistory: async () => {
      queries += 1;
      return [];
    },
  });

  const response = await handler(get(`?ideaId=${ideaId}`));
  assert.equal(response.status, 401);
  assert.equal(queries, 0);
});

test("preserves authentication backend failures as 503", async () => {
  const handler = createDossierHistoryHandler({
    authenticate: async () => {
      throw new Error("auth backend unavailable");
    },
    fetchHistory: async () => [],
  });

  const response = await handler(get(`?ideaId=${ideaId}`));
  assert.equal(response.status, 503);
});

test("accepts only an idea ID and passes the server session context to the RPC path", async () => {
  const context = { session: "trusted" };
  let receivedIdeaId: string | undefined;
  let receivedContext: typeof context | undefined;
  const handler = createDossierHistoryHandler({
    authenticate: async () => ({ context }),
    fetchHistory: async (requestedIdeaId, session) => {
      receivedIdeaId = requestedIdeaId;
      receivedContext = session;
      return historyResponse();
    },
  });

  const response = await handler(get(`?ideaId=${ideaId}&ownerId=victim`));
  assert.equal(response.status, 400);
  assert.equal(receivedIdeaId, undefined);

  const success = await handler(get(`?ideaId=${ideaId}`));
  assert.equal(success.status, 200);
  assert.equal(receivedIdeaId, ideaId);
  assert.equal(receivedContext, context);
  const payload = await success.json();
  assert.deepEqual(Object.keys(payload.history[0]).sort(), [
    "created_at",
    "dossier",
    "revision",
  ]);
});

test("supports empty history and hides internal failures behind a retryable response", async () => {
  let attempts = 0;
  const handler = createDossierHistoryHandler({
    authenticate: async () => ({ context: {} }),
    fetchHistory: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error("database internals");
      return [];
    },
  });

  const failed = await handler(get(`?ideaId=${ideaId}`));
  assert.equal(failed.status, 500);
  assert.deepEqual(await failed.json(), { error: "History could not be loaded." });
  const retry = await handler(get(`?ideaId=${ideaId}`));
  assert.equal(retry.status, 200);
  assert.deepEqual(await retry.json(), { history: [] });
  assert.equal(attempts, 2);
});

test("uniformly rejects unavailable ideas without disclosing their existence", async () => {
  const handler = createDossierHistoryHandler({
    authenticate: async () => ({ context: {} }),
    fetchHistory: async () => {
      throw new DossierHistoryUnavailableError();
    },
  });

  const response = await handler(get(`?ideaId=${ideaId}`));
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: "History is unavailable." });
});