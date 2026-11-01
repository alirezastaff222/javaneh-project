import test from "node:test";
import assert from "node:assert/strict";

import {
  parseAssignedIdeas,
  mapEvaluationError,
  parseAssignedDossier,
  parseIdeaIdBody,
} from "./evaluator-api";

test("evaluator idea selection accepts a valid UUID", () => {
  const result = parseIdeaIdBody({
    ideaId: "11111111-1111-4111-8111-111111111111",
  });

  assert.equal(result.success, true);
  if (result.success) {
    assert.equal(result.data.ideaId, "11111111-1111-4111-8111-111111111111");
  }
});

test("evaluator idea selection rejects empty input", () => {
  const result = parseIdeaIdBody({ ideaId: "   " });

  assert.equal(result.success, false);
});

test("evaluator mapping reports forbidden access for RBAC denial", () => {
  const mapped = mapEvaluationError({ code: "42501", message: "Forbidden" });

  assert.deepEqual(mapped, { status: 403, error: "Forbidden." });
});

test("assigned dossier validation accepts exactly six ordered stages", () => {
  const result = parseAssignedDossier({
    outcome: "available",
    revision: 4,
    dossier: {
      stages: Array.from({ length: 6 }, (_, index) => ({
        stage_number: index + 1,
        stage_key: `stage_${index + 1}`,
        data: { content: `Submitted stage ${index + 1}` },
        confirmed_at: "2026-11-01T10:00:00Z",
      })),
    },
  });

  assert.equal(result.success, true);
});

test("assigned dossier validation rejects incomplete or extra stage history", () => {
  const stages = Array.from({ length: 6 }, (_, index) => ({
    stage_number: index + 1,
    stage_key: `stage_${index + 1}`,
    data: { content: `Submitted stage ${index + 1}` },
    confirmed_at: "2026-11-01T10:00:00Z",
  }));
  const incomplete = parseAssignedDossier({
    outcome: "available",
    revision: 4,
    dossier: { stages: stages.slice(0, 5) },
  });
  const privateHistory = parseAssignedDossier({
    outcome: "available",
    revision: 4,
    dossier: { stages },
    history: [{ revision: 3 }],
  });

  assert.equal(incomplete.success, false);
  assert.equal(privateHistory.success, false);
});

test("assignment loading distinguishes empty, populated, and failed results", () => {
  const assignment = {
    idea_id: "11111111-1111-4111-8111-111111111111",
    status: "completed",
    assigned_at: "2026-11-01T10:00:00Z",
    started_at: "2026-11-01T11:00:00Z",
    completed_at: "2026-11-01T12:00:00Z",
    submitted_at: "2026-10-25T10:00:00Z",
    current_step: 7,
  };
  assert.deepEqual(
    parseAssignedIdeas({ outcome: "available", items: [] }, null),
    { kind: "empty", items: [] },
  );
  assert.equal(
    parseAssignedIdeas({ outcome: "available", items: [assignment] }, null).kind,
    "loaded",
  );
  assert.deepEqual(parseAssignedIdeas(null, new Error("database detail")), {
    kind: "error",
  });
  assert.deepEqual(parseAssignedIdeas({ outcome: "available", items: null }, null), {
    kind: "error",
  });
});
