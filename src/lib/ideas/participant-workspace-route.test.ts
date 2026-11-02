import assert from "node:assert/strict";
import test from "node:test";
import { createParticipantWorkspaceHandler } from "./participant-workspace-route";

test("rejects an unauthenticated workspace request", async () => {
  const response = await createParticipantWorkspaceHandler(async () => ({
    kind: "unauthenticated",
  }))();
  assert.equal(response.status, 401);
});

test("returns a recoverable dependency error instead of a false quota", async () => {
  const response = await createParticipantWorkspaceHandler(async () => ({
    kind: "error",
    code: "ideas_unavailable",
  }))();
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: "ایده‌های شما در حال حاضر در دسترس نیستند.",
    code: "ideas_unavailable",
  });
});
