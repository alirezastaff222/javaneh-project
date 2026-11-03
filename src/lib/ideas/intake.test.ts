import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildInitialIdeaContent,
  IntakeRegistrationError,
  registerInitialIdea,
  type IntakeRegistrationOperation,
  type IntakeRpcClient,
} from "./intake";

describe("buildInitialIdeaContent", () => {
  it("keeps the title on the first line for the participant workspace", () => {
    const content = buildInitialIdeaContent({
      title: "  همیاری محلی\n برای خرید  ",
      initialDescription: "شبکه‌ای برای پشتیبانی همسایه‌ها",
      problem: "برخی خانواده‌ها به کالاهای ضروری دسترسی پایدار ندارند.",
      affectedPeople: "خانواده‌های محله",
      observation: "این مسئله را در چند ماه اخیر دیده‌ام.",
    });

    assert.equal(content.split("\n", 1)[0], "همیاری محلی برای خرید");
    assert.match(content, /شرح اولیه ایده:\nشبکه‌ای برای پشتیبانی همسایه‌ها/);
    assert.match(content, /مسئله:\nبرخی خانواده‌ها/);
    assert.match(content, /افراد و گروه‌های متأثر:\nخانواده‌های محله/);
    assert.match(content, /مشاهده یا شواهد اولیه:\nاین مسئله/);
  });

  it("omits unanswered optional sections without inventing content", () => {
    const content = buildInitialIdeaContent({
      title: "دسترسی بهتر به کتاب",
      initialDescription: "به‌اشتراک‌گذاری کتاب در محله",
      problem: "",
      affectedPeople: "",
      observation: "",
    });

    assert.equal(
      content,
      "دسترسی بهتر به کتاب\n\nشرح اولیه ایده:\nبه‌اشتراک‌گذاری کتاب در محله",
    );
  });
});

describe("registerInitialIdea", () => {
  const operation: IntakeRegistrationOperation = {
    createRequestId: "create-request",
    saveRequestId: "save-request",
    ideaId: null,
    expectedRevision: null,
  };

  it("creates, saves, requests confirmation, then confirms Stage 1", async () => {
    const calls: string[] = [];
    let persistedOperation: IntakeRegistrationOperation | null = null;
    const client: IntakeRpcClient = {
      async rpc(name) {
        calls.push(name);
        if (name === "create_idea") {
          return {
            data: {
              outcome: "created",
              idea_id: "idea-1",
              revision: 1,
            },
            error: null,
          };
        }
        if (name === "save_idea_content") {
          return {
            data: { outcome: "applied", result_revision: 2 },
            error: null,
          };
        }
        if (name === "request_idea_stage_confirmation") {
          return { data: { outcome: "requested" }, error: null };
        }
        return {
          data: { outcome: "confirmed", current_step: 2 },
          error: null,
        };
      },
      async loadIdeaRevision() {
        return 1;
      },
    };

    const result = await registerInitialIdea(
      client,
      "عنوان\n\nشرح مسئله",
      operation,
      (nextOperation) => {
        persistedOperation = nextOperation;
      },
    );

    assert.deepEqual(calls, [
      "create_idea",
      "save_idea_content",
      "request_idea_stage_confirmation",
      "confirm_idea_stage",
    ]);
    assert.deepEqual(persistedOperation, {
      ...operation,
      ideaId: "idea-1",
      expectedRevision: 1,
    });
    assert.deepEqual(result, { ideaId: "idea-1", revision: 2 });
  });

  it("replays a saved operation without creating a second idea", async () => {
    const calls: string[] = [];
    const client: IntakeRpcClient = {
      async rpc(name) {
        calls.push(name);
        if (name === "save_idea_content") {
          return {
            data: { outcome: "replayed", result_revision: 2 },
            error: null,
          };
        }
        if (name === "request_idea_stage_confirmation") {
          return { data: { outcome: "already_requested" }, error: null };
        }
        return {
          data: { outcome: "already_confirmed", current_step: 2 },
          error: null,
        };
      },
      async loadIdeaRevision() {
        assert.fail("A persisted revision should not need to be reloaded");
      },
    };

    const result = await registerInitialIdea(
      client,
      "عنوان\n\nشرح مسئله",
      { ...operation, ideaId: "idea-1", expectedRevision: 1 },
      () => assert.fail("The existing operation should not change"),
    );

    assert.deepEqual(calls, [
      "save_idea_content",
      "request_idea_stage_confirmation",
      "confirm_idea_stage",
    ]);
    assert.deepEqual(result, { ideaId: "idea-1", revision: 2 });
  });

  it("stops at the quota boundary before writing stage content", async () => {
    const calls: string[] = [];
    const client: IntakeRpcClient = {
      async rpc(name) {
        calls.push(name);
        return { data: { outcome: "quota_exceeded" }, error: null };
      },
      async loadIdeaRevision() {
        return null;
      },
    };

    await assert.rejects(
      registerInitialIdea(client, "عنوان", operation, () => undefined),
      (error: unknown) =>
        error instanceof IntakeRegistrationError &&
        error.phase === "create" &&
        error.outcome === "quota_exceeded",
    );
    assert.deepEqual(calls, ["create_idea"]);
  });
});