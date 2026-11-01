import test from "node:test";
import assert from "node:assert/strict";

import {
  createEvaluatorCorrectionDraft,
  createEvaluatorFeedbackDraft,
  loadEvaluatorFeedbackDraft,
  saveEvaluatorFeedbackDraft,
} from "./evaluator-dashboard-workflow";

const ideaId = "11111111-1111-4111-8111-111111111111";
const draftId = "22222222-2222-4222-8222-222222222222";

function response(payload: unknown, ok = true) {
  return {
    ok,
    json: async () => payload,
  } as Response;
}

test("loads the current private draft through the existing GET contract", async () => {
  let requestUrl = "";
  const result = await loadEvaluatorFeedbackDraft(ideaId, async (input, init) => {
    requestUrl = String(input);
    assert.equal(init?.cache, "no-store");
    return response({
      outcome: "available",
      draft_id: draftId,
      feedback_content: "Private notes",
      previous_published_version_id: null,
    });
  });

  assert.equal(
    requestUrl,
    `/api/ideas/feedback/drafts?ideaId=${ideaId}`,
  );
  assert.deepEqual(result, {
    ok: true,
    value: {
      draftId,
      content: "Private notes",
      previousPublishedVersionId: null,
    },
  });
});

test("creates an initial feedback draft through the existing POST contract", async () => {
  let requestUrl = "";
  const result = await createEvaluatorFeedbackDraft(
    ideaId,
    "Initial private feedback",
    async (input, init) => {
      requestUrl = String(input);
      assert.equal(init?.method, "POST");
      assert.deepEqual(JSON.parse(String(init?.body)), {
        ideaId,
        content: "Initial private feedback",
      });
      return response({
        outcome: "created",
        draft_id: draftId,
        previous_published_version_id: null,
      });
    },
  );

  assert.equal(requestUrl, "/api/ideas/feedback/drafts");
  assert.equal(result.ok, true);
});

test("saves an existing draft without completing evaluation or publishing", async () => {
  const requestedUrls: string[] = [];
  const result = await saveEvaluatorFeedbackDraft(
    draftId,
    "Updated private feedback",
    async (input, init) => {
      requestedUrls.push(String(input));
      assert.equal(init?.method, "PATCH");
      assert.deepEqual(JSON.parse(String(init?.body)), {
        draftId,
        content: "Updated private feedback",
      });
      return response({ outcome: "updated" });
    },
  );

  assert.deepEqual(requestedUrls, ["/api/ideas/feedback/drafts"]);
  assert.equal(result.ok, true);
});

test("creates corrections only through the correction contract", async () => {
  let requestUrl = "";
  const result = await createEvaluatorCorrectionDraft(
    ideaId,
    "Corrected private feedback",
    async (input, init) => {
      requestUrl = String(input);
      assert.equal(init?.method, "POST");
      return response({
        outcome: "created",
        draft_id: draftId,
        previous_published_version_id:
          "33333333-3333-4333-8333-333333333333",
      });
    },
  );

  assert.equal(requestUrl, "/api/ideas/feedback/drafts/correction");
  assert.equal(result.ok, true);

  const rejected = await createEvaluatorCorrectionDraft(
    ideaId,
    "Not eligible",
    async () => response({ outcome: "no_published_version" }),
  );
  assert.deepEqual(rejected, {
    ok: false,
    error: "A correction requires previously published feedback.",
  });
});
