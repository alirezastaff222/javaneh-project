import test from "node:test";
import assert from "node:assert/strict";

import {
  loadEligiblePublisherDrafts,
  parseEligiblePublisherDrafts,
  publishEligibleFeedbackDraft,
} from "./feedback-publisher";

const actorId = "11111111-1111-4111-8111-111111111111";
const evaluatorId = "22222222-2222-4222-8222-222222222222";
const draftId = "33333333-3333-4333-8333-333333333333";
const ideaId = "44444444-4444-4444-8444-444444444444";
const cycleId = "55555555-5555-4555-8555-555555555555";

function response(payload: unknown, ok = true, status = 200) {
  return {
    ok,
    status,
    json: async () => payload,
  } as Response;
}

function publisherList(evaluatorUserId = evaluatorId) {
  return {
    outcome: "available",
    drafts: [
      {
        draft_id: draftId,
        idea_id: ideaId,
        cycle_id: cycleId,
        feedback_content: "Private evaluator feedback",
        previous_published_version_id: null,
        evaluator_user_id: evaluatorUserId,
        updated_at: "2026-11-01T22:00:00Z",
      },
    ],
  };
}

test("publisher draft parsing omits evaluator identity and prevents self-publication", () => {
  const parsed = parseEligiblePublisherDrafts(publisherList(actorId), actorId);

  assert.deepEqual(parsed, [
    {
      draftId,
      ideaId,
      cycleId,
      content: "Private evaluator feedback",
      previousPublishedVersionId: null,
      updatedAt: "2026-11-01T22:00:00Z",
      canPublish: false,
    },
  ]);
  assert.equal(
    parsed?.some((draft) => "evaluatorUserId" in draft),
    false,
  );
});

test("publisher draft parsing accepts correction context and marks independent publishers", () => {
  const parsed = parseEligiblePublisherDrafts(
    {
      outcome: "available",
      drafts: [
        {
          ...publisherList().drafts[0],
          previous_published_version_id:
            "66666666-6666-4666-8666-666666666666",
        },
      ],
    },
    actorId,
  );

  assert.equal(parsed?.[0]?.canPublish, true);
  assert.equal(
    parsed?.[0]?.previousPublishedVersionId,
    "66666666-6666-4666-8666-666666666666",
  );
});

test("publisher queue loads through the existing private no-store API", async () => {
  let url = "";
  const state = await loadEligiblePublisherDrafts(actorId, async (input, init) => {
    url = String(input);
    assert.equal(init?.cache, "no-store");
    return response(publisherList());
  });

  assert.equal(url, "/api/ideas/feedback/publication");
  assert.equal(state.kind, "loaded");
  if (state.kind === "loaded") assert.equal(state.drafts.length, 1);
});

test("publisher queue preserves unauthorized states", async () => {
  assert.deepEqual(
    await loadEligiblePublisherDrafts(actorId, async () =>
      response({}, false, 403),
    ),
    { kind: "forbidden" },
  );
  assert.deepEqual(
    await loadEligiblePublisherDrafts(actorId, async () =>
      response({}, false, 401),
    ),
    { kind: "unauthenticated" },
  );
});

test("publishes through the existing API and exposes the resulting version", async () => {
  const result = await publishEligibleFeedbackDraft(draftId, async (input, init) => {
    assert.equal(String(input), "/api/ideas/feedback/publication");
    assert.equal(init?.method, "POST");
    assert.deepEqual(JSON.parse(String(init?.body)), { draftId });
    return response({
      outcome: "published",
      version_id: "77777777-7777-4777-8777-777777777777",
      version_number: 2,
      published_at: "2026-11-01T22:10:00Z",
    });
  });

  assert.deepEqual(result, {
    ok: true,
    value: {
      versionId: "77777777-7777-4777-8777-777777777777",
      versionNumber: 2,
      publishedAt: "2026-11-01T22:10:00Z",
    },
  });
});

test("publisher workflow rejects self-publication and stale corrections", async () => {
  assert.deepEqual(
    await publishEligibleFeedbackDraft(draftId, async () =>
      response({ outcome: "same_user" }),
    ),
    {
      ok: false,
      error: "You cannot publish feedback that you evaluated.",
    },
  );
  assert.equal(
    (await publishEligibleFeedbackDraft(draftId, async () =>
      response({ outcome: "stale_draft" }),
    )).ok,
    false,
  );
});
