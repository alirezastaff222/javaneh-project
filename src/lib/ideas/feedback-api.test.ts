import test from "node:test";
import assert from "node:assert/strict";

import {
  parseCorrectionBody,
  parseDraftCreateBody,
  parseDraftPublicationBody,
  parseDraftUpdateBody,
} from "./feedback-api";

test("feedback draft payload validation accepts valid content", () => {
  const result = parseDraftCreateBody({
    ideaId: "11111111-1111-4111-8111-111111111111",
    content: "Detailed evaluation notes",
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.content, "Detailed evaluation notes");
  }
});

test("feedback correction payload rejects empty content", () => {
  const result = parseCorrectionBody({
    ideaId: "11111111-1111-4111-8111-111111111111",
    content: "   ",
  });

  assert.equal(result.success, false);
});

test("publication payload accepts a valid draft UUID", () => {
  const result = parseDraftPublicationBody({
    draftId: "22222222-2222-4222-8222-222222222222",
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.draftId, "22222222-2222-4222-8222-222222222222");
  }
});

test("draft update payload validates a draft id and content", () => {
  const result = parseDraftUpdateBody({
    draftId: "33333333-3333-4333-8333-333333333333",
    content: "Updated feedback",
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.draftId, "33333333-3333-4333-8333-333333333333");
  }
});
