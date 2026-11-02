import assert from "node:assert/strict";
import test from "node:test";
import {
  buildAuthPath,
  buildConfirmationRedirect,
  sanitizeReturnTo,
} from "./auth";

test("keeps local return destinations and rejects external destinations", () => {
  assert.equal(sanitizeReturnTo("/ideas?idea=123"), "/ideas?idea=123");
  assert.equal(
    sanitizeReturnTo("/ideas?seed=food%20desert%20%26%20100%25"),
    "/ideas?seed=food%20desert%20%26%20100%25",
  );
  assert.equal(sanitizeReturnTo("//evil.example"), "/ideas");
  assert.equal(sanitizeReturnTo("https://evil.example"), "/ideas");
  assert.equal(sanitizeReturnTo("/\\evil.example"), "/ideas");
});

test("constructs sign-in and confirmation redirect URLs", () => {
  assert.equal(
    buildAuthPath("/auth/sign-in", "/ideas?idea=123"),
    "/auth/sign-in?returnTo=%2Fideas%3Fidea%3D123",
  );
  assert.equal(
    buildConfirmationRedirect("https://javaneh.example", "/ideas"),
    "https://javaneh.example/auth/callback?returnTo=%2Fideas",
  );
  assert.equal(
    buildConfirmationRedirect(
      "https://preview.example",
      "/ideas?seed=community",
      "https://javaneh.example/",
    ),
    "https://javaneh.example/auth/callback?returnTo=%2Fideas%3Fseed%3Dcommunity",
  );
  assert.throws(
    () => buildConfirmationRedirect("https://javaneh.example", "/ideas", "javaneh.example"),
    /NEXT_PUBLIC_SITE_URL/,
  );
});
