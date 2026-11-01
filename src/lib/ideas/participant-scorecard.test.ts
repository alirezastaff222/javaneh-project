import assert from "node:assert/strict";
import test from "node:test";
import { createParticipantScorecardHandler } from "./participant-scorecard-route";
import { parseParticipantScorecard } from "./participant-scorecard";
import {
  MilestoneScoreSummary,
  milestoneStatusLabel,
  remainingStagePoints,
  StageScoreSummary,
} from "../../app/ideas/participant-scorecard";

const ideaId = "a9a10000-0000-4000-8000-000000000001";

function availableResponse() {
  return {
    state: "available",
    version_number: 1,
    catalog_version: "1.0",
    maximum_points: 700,
    total_points: 17,
    stages: Array.from({ length: 6 }, (_, index) => ({
      stage_number: index + 1,
      points: index === 0 ? 17 : 0,
      maximum_points: [80, 100, 140, 140, 120, 120][index],
    })),
    milestones: Array.from({ length: 28 }, (_, index) => ({
      stage_number: Math.floor(index / 5) + 1,
      name: `Milestone ${index + 1}`,
      criteria: `Participant criteria ${index + 1}`,
      status: index === 0 ? "awarded" : "not_submitted",
      awarded_points: index === 0 ? 17 : 0,
      maximum_points: [25, 20, 20, 15, 25, 25, 25, 25, 30, 35, 35, 20, 20,
        25, 35, 25, 30, 25, 25, 25, 25, 25, 20, 30, 30, 20, 20, 20][index],
      evaluator_id: "private-evaluator",
      reason: "private milestone rationale",
    })),
    history: [
      {
        stage_number: 1,
        milestone: "Milestone 1",
        kind: "award",
        points: 17,
        recorded_at: "2026-11-01T10:00:00Z",
        actor_id: "private-actor",
        source_reference: "private-reference",
        reason: "private reason",
      },
    ],
  };
}

function get(url: string) {
  return new Request(`https://example.test/api/ideas/scorecard${url}`);
}

test("requires an authenticated session and never calls the scorecard anonymously", async () => {
  let queries = 0;
  const handler = createParticipantScorecardHandler({
    authenticate: async () => null,
    fetchScorecard: async () => {
      queries += 1;
      return {};
    },
  });

  const response = await handler(get(`?ideaId=${ideaId}`));
  assert.equal(response.status, 401);
  assert.equal(response.headers.get("cache-control"), "private, no-store");
  assert.equal(queries, 0);
});

test("accepts only an idea ID and passes the server session context to the RPC", async () => {
  const context = { session: "trusted" };
  let receivedIdeaId: string | undefined;
  let receivedContext: typeof context | undefined;
  const handler = createParticipantScorecardHandler({
    authenticate: async () => ({ context }),
    fetchScorecard: async (requestedIdeaId, session) => {
      receivedIdeaId = requestedIdeaId;
      receivedContext = session;
      return { state: "unavailable", reason: "not_assigned" };
    },
  });

  const invalid = await handler(
    get(`?ideaId=${ideaId}&participantId=another-user`),
  );
  assert.equal(invalid.status, 400);
  assert.equal(receivedIdeaId, undefined);

  const success = await handler(get(`?ideaId=${ideaId}`));
  assert.equal(success.status, 200);
  assert.equal(receivedIdeaId, ideaId);
  assert.equal(receivedContext, context);
  assert.deepEqual(await success.json(), {
    scorecard: { state: "unavailable", reason: "not_assigned" },
  });
});

test("sanitizes internal ledger fields and validates awarded points", () => {
  const raw = availableResponse();
  const scorecard = parseParticipantScorecard(raw);
  assert.ok(scorecard);
  assert.equal(scorecard.state, "available");
  if (scorecard.state !== "available") return;
  assert.deepEqual(Object.keys(scorecard.history[0]).sort(), [
    "kind",
    "milestone",
    "points",
    "recorded_at",
    "stage_number",
  ]);
  assert.equal(scorecard.milestones[0].maximum_points, 25);
  assert.equal("reason" in scorecard.milestones[0], false);
  assert.equal("evaluator_id" in scorecard.milestones[0], false);
  assert.equal("source_reference" in scorecard.history[0], false);

  raw.milestones[0].status = "pending_validation";
  raw.milestones[0].awarded_points = 0;
  assert.equal(parseParticipantScorecard(raw)?.state, "available");
});

test("requires valid milestone maxima and rejects earned points above them", () => {
  const raw = availableResponse();
  raw.milestones[0].maximum_points = 0;
  assert.equal(parseParticipantScorecard(raw), null);

  const overMaximum = availableResponse();
  overMaximum.milestones[0].awarded_points = 26;
  assert.equal(parseParticipantScorecard(overMaximum), null);
});

test("discards unexpected private fields at every allowed payload level", () => {
  const raw = availableResponse();
  Object.assign(raw, {
    jury_points: 200,
    final_competition_score: 700,
    evaluator_identity: "private",
    internal_reason: "private",
  });
  Object.assign(raw.stages[0], { jury_points: 300, source_reference: "private" });
  Object.assign(raw.milestones[0], {
    administrator_id: "private",
    internal_note: "private",
    source_reference: "private",
  });

  const scorecard = parseParticipantScorecard(raw);
  assert.ok(scorecard);
  assert.equal(scorecard.state, "available");
  if (scorecard.state !== "available") return;
  assert.deepEqual(Object.keys(scorecard), [
    "state",
    "version_number",
    "catalog_version",
    "maximum_points",
    "total_points",
    "stages",
    "milestones",
    "history",
  ]);
  assert.equal("jury_points" in scorecard.stages[0], false);
  assert.equal("internal_note" in scorecard.milestones[0], false);
  assert.equal("reason" in scorecard.history[0], false);
});

test("renders milestone and stage earned, maximum, and remaining points", () => {
  const milestone = MilestoneScoreSummary({
    points: 17,
    maximumPoints: 25,
    status: "awarded",
  });
  const stage = StageScoreSummary({
    stageNumber: 1,
    points: 17,
    maximumPoints: 80,
  });

  assert.equal(
    milestone.props.children[0].props.children.join("").replace(/\s+/g, " ").trim(),
    "17 از 25 امتیاز",
  );
  const [earned, maximum, remaining] = stage.props.children[1].props.children;
  assert.equal(earned.props.children.join(""), "کسب‌شده: 17");
  assert.equal(maximum.props.children.join(""), "حداکثر: 80");
  assert.equal(
    remaining.props.children.join("")
      .replace(/\s+/g, " ")
      .trim(),
    "باقی‌مانده: 63",
  );
});

test("stage remaining points never become negative and zero is not described as failure", () => {
  assert.equal(remainingStagePoints(80, 80), 0);
  assert.equal(remainingStagePoints(81, 80), 0);
  assert.doesNotMatch(milestoneStatusLabel("not_submitted"), /رد|شکست|ناموفق/);
  assert.doesNotMatch(milestoneStatusLabel("pending_validation"), /کسب‌شده/);
});

test("keeps all validation statuses distinct and pending points separate", () => {
  const statuses = [
    "not_submitted",
    "pending_validation",
    "validated",
    "needs_revision",
    "rejected",
    "awarded",
    "corrected",
  ] as const;
  const labels = statuses.map(milestoneStatusLabel);
  assert.equal(new Set(labels).size, statuses.length);

  for (const status of statuses) {
    const raw = availableResponse();
    raw.milestones[0].status = status;
    raw.milestones[0].awarded_points = status === "awarded" ? 17 : 0;
    const scorecard = parseParticipantScorecard(raw);
    assert.ok(scorecard?.state === "available");
    assert.equal(scorecard.milestones[0].status, status);
  }

  const pending = MilestoneScoreSummary({
    points: 0,
    maximumPoints: 20,
    status: "pending_validation",
  });
  assert.match(JSON.stringify(pending), /در امتیازهای کسب‌شده محاسبه نشده است/);
  assert.match(JSON.stringify(pending), /در انتظار بررسی/);
});

test("rejects malformed or unavailable scorecard payloads without guessing", () => {
  assert.deepEqual(parseParticipantScorecard(availableResponse())?.state, "available");
  assert.deepEqual(parseParticipantScorecard({
    state: "unavailable",
    reason: "not_assigned",
    internal_reason: "private",
  }), { state: "unavailable", reason: "not_assigned" });
  assert.equal(
    parseParticipantScorecard({ state: "unavailable", reason: "private_data" }),
    null,
  );
  assert.equal(
    parseParticipantScorecard({ ...availableResponse(), total_points: 701 }),
    null,
  );
});