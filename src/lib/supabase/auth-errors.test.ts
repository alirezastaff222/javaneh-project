import assert from "node:assert/strict";
import test from "node:test";
import { isUnauthenticatedAuthError } from "./auth-errors";

test("recognizes missing and invalid sessions as unauthenticated", () => {
  assert.equal(
    isUnauthenticatedAuthError({
      name: "AuthSessionMissingError",
      status: 400,
    }),
    true,
  );
  assert.equal(isUnauthenticatedAuthError({ status: 401 }), true);
});

test("does not classify unrelated backend failures as unauthenticated", () => {
  assert.equal(isUnauthenticatedAuthError(new Error("service unavailable")), false);
  assert.equal(isUnauthenticatedAuthError({ status: 500 }), false);
});
