import assert from "node:assert/strict";
import test from "node:test";
import {
  buildIdeaPortfolio,
  canCreateIdea,
  getAvailableIdeaSlots,
  getIdeaCountForScope,
  IDEA_QUOTA_LIMIT,
  isIdeaPortfolioItem,
  titleFromStageRows,
  type IdeaStatus,
} from "./portfolio";

function fixtureIdea(
  id: string,
  status: IdeaStatus,
  currentStep: number,
  completedStageCount: number,
) {
  const stages = Array.from({ length: 7 }, (_, index) => {
    const stageNumber = index + 1;
    return {
      idea_id: id,
      stage_number: stageNumber,
      status:
        stageNumber === 7
          ? "locked"
          : stageNumber <= completedStageCount
            ? "confirmed"
            : stageNumber === currentStep
              ? "in_progress"
              : "locked",
    };
  });

  return {
    idea: {
      id,
      status,
      revision: 1,
      current_step: currentStep,
      submitted_at: status === "submitted" ? "2026-11-01T10:00:00Z" : null,
      created_at: "2026-11-01T09:00:00Z",
      updated_at: "2026-11-01T10:00:00Z",
    },
    stages,
  };
}

test("builds participant progress and next actions from idea stage rows", () => {
  const developing = fixtureIdea("idea-a", "in_progress", 2, 1);
  const complete = fixtureIdea("idea-b", "in_progress", 6, 6);
  const submitted = fixtureIdea("idea-c", "submitted", 7, 6);
  const portfolio = buildIdeaPortfolio(
    [developing.idea, complete.idea, submitted.idea],
    [...developing.stages, ...complete.stages, ...submitted.stages],
  );

  assert.deepEqual(
    portfolio?.map(({ completedStageCount, nextAction }) => ({
      completedStageCount,
      nextAction,
    })),
    [
      { completedStageCount: 1, nextAction: "continue" },
      { completedStageCount: 6, nextAction: "submit" },
      { completedStageCount: 6, nextAction: "awaiting_review" },
    ],
  );
  assert.equal(IDEA_QUOTA_LIMIT - portfolio!.length, 0);
});

test("keeps an empty portfolio valid and all three quota slots available", () => {
  const portfolio = buildIdeaPortfolio([], []);

  assert.deepEqual(portfolio, []);
  assert.equal(IDEA_QUOTA_LIMIT - portfolio!.length, 3);
  assert.equal(getAvailableIdeaSlots(portfolio!.length, true), 3);
  assert.equal(canCreateIdea(portfolio!.length, true, false), true);
});

test("derives a concise idea title from saved Stage 1 content", () => {
  assert.equal(
    titleFromStageRows(
      [
        {
          idea_id: "idea-a",
          stage_number: 1,
          data: { content: "  Safer streets\nA longer problem description" },
        },
      ],
      "idea-a",
    ),
    "Safer streets",
  );
  assert.equal(
    titleFromStageRows(
      [{ idea_id: "idea-a", stage_number: 2, data: { content: "Other" } }],
      "idea-a",
    ),
    undefined,
  );
});

test("reports confirmation and revision as the next required action", () => {
  const pending = fixtureIdea("idea-pending", "in_progress", 2, 1);
  pending.stages[1].status = "pending_confirmation";
  const needsRevision = fixtureIdea("idea-revision", "in_progress", 2, 1);
  needsRevision.stages[1].status = "needs_revision";
  const portfolio = buildIdeaPortfolio(
    [pending.idea, needsRevision.idea],
    [...pending.stages, ...needsRevision.stages],
  );

  assert.deepEqual(
    portfolio?.map((idea) => idea.nextAction),
    ["confirm", "revise"],
  );
});

test("accepts only participant-safe evaluation states on submitted ideas", () => {
  const submitted = fixtureIdea("idea-submitted", "submitted", 7, 6);
  const [portfolioItem] = buildIdeaPortfolio(
    [submitted.idea],
    submitted.stages,
  ) ?? [];
  assert.ok(portfolioItem);

  for (const evaluationStatus of [
    "awaiting_review",
    "in_progress",
    "completed",
  ]) {
    assert.equal(
      isIdeaPortfolioItem({ ...portfolioItem, evaluationStatus }),
      true,
    );
  }
  assert.equal(
    isIdeaPortfolioItem({
      ...portfolioItem,
      evaluationStatus: "winner_selected",
    }),
    false,
  );
  assert.equal(
    isIdeaPortfolioItem({
      ...portfolioItem,
      status: "in_progress",
      evaluationStatus: "completed",
    }),
    false,
  );
});

test("accepts participant-safe published feedback metadata on submitted ideas", () => {
  const submitted = fixtureIdea("idea-feedback", "submitted", 7, 6);
  const portfolioItem = buildIdeaPortfolio([submitted.idea], submitted.stages)?.[0];

  assert.ok(portfolioItem);
  assert.equal(
    isIdeaPortfolioItem({
      ...portfolioItem,
      evaluationStatus: "completed",
      publishedFeedback: {
        content: "بازخورد نهایی برای مشارکت‌کننده",
        version_number: 2,
        published_at: "2026-11-02T10:00:00Z",
      },
    }),
    true,
  );
  assert.equal(
    isIdeaPortfolioItem({
      ...portfolioItem,
      publishedFeedback: {
        content: "بازخورد نامعتبر",
        version_number: 0,
        published_at: "2026-11-02T10:00:00Z",
      },
    }),
    false,
  );
});

test("rejects incomplete or cross-idea stage data instead of misreporting progress", () => {
  const idea = fixtureIdea("idea-a", "in_progress", 1, 0);

  assert.equal(
    buildIdeaPortfolio([idea.idea], idea.stages.slice(0, 6)),
    null,
  );
  assert.equal(
    buildIdeaPortfolio(
      [idea.idea],
      [...idea.stages, { idea_id: "idea-b", stage_number: 1, status: "confirmed" }],
    ),
    null,
  );
});

test("counts submitted ideas toward quota and blocks creation when all slots are occupied", () => {
  const portfolio = [
    fixtureIdea("idea-a", "in_progress", 1, 0),
    fixtureIdea("idea-b", "in_progress", 2, 1),
    fixtureIdea("idea-c", "submitted", 7, 6),
  ];

  assert.equal(getAvailableIdeaSlots(portfolio.length, true), 0);
  assert.equal(canCreateIdea(portfolio.length, true, false), false);
  assert.equal(canCreateIdea(portfolio.length, true, true), true);
});

test("failed refresh cannot release a displayed slot, while refreshed deletion can", () => {
  const fullQuotaCount = 3;

  assert.equal(getAvailableIdeaSlots(fullQuotaCount, false), null);
  assert.equal(getAvailableIdeaSlots(fullQuotaCount - 1, true), 1);
});

test("individual and group ideas consume separate three-idea quotas", () => {
  const portfolio = [
    { group_id: null },
    { group_id: null },
    { group_id: "group-a" },
    { group_id: "group-a" },
    { group_id: "group-b" },
  ];

  assert.equal(getIdeaCountForScope(portfolio, null), 2);
  assert.equal(getIdeaCountForScope(portfolio, "group-a"), 2);
  assert.equal(getIdeaCountForScope(portfolio, "group-b"), 1);
  assert.equal(getAvailableIdeaSlots(getIdeaCountForScope(portfolio, null), true), 1);
  assert.equal(getAvailableIdeaSlots(getIdeaCountForScope(portfolio, "group-a"), true), 1);
});
