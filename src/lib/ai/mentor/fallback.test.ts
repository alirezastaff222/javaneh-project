import assert from "node:assert/strict";
import { test } from "node:test";
import {
  IDEA_STAGE_FALLBACK_GUIDANCE,
  IDEA_STAGES,
} from "../../ideas/stages";

test("each participant stage has specific non-AI continuation guidance, never Stage 7", () => {
  const participantStages = IDEA_STAGES.filter((stage) => stage.number <= 6);
  assert.equal(participantStages.length, 6);
  for (const stage of participantStages) {
    if (stage.number > 6) continue;
    const guidance =
      IDEA_STAGE_FALLBACK_GUIDANCE[
        stage.key as Exclude<typeof stage.key, "human_review">
      ];
    assert.ok(guidance, `${stage.key} must have guidance`);
    assert.ok(guidance.summary.length > 20);
    assert.ok(guidance.questions.length >= 2);
  }
  assert.equal(
    Object.hasOwn(IDEA_STAGE_FALLBACK_GUIDANCE, "human_review"),
    false,
  );
});

test("the non-AI guidance adds no requirement to existing scoring or stage data", () => {
  assert.deepEqual(
    Object.keys(IDEA_STAGE_FALLBACK_GUIDANCE).sort(),
    [
      "define_problem",
      "develop_ideas",
      "feasibility_resilience",
      "idea_dossier",
      "identify_social_capacities",
      "implementation_plan",
    ].sort(),
  );
  assert.ok(
    IDEA_STAGES.every((stage) => "outcome" in stage && "key" in stage),
  );
});
