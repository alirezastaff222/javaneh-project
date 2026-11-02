import assert from "node:assert/strict";
import { test } from "node:test";
import {
  createGoogleMentorModel,
  DEFAULT_MENTOR_MODEL,
  getMentorModelConfiguration,
} from "./provider";

test("Google Mentor provider targets the configured Gemini model directly", () => {
  const config = getMentorModelConfiguration({
    GOOGLE_GENERATIVE_AI_API_KEY: "test-key",
  });
  const model = createGoogleMentorModel(config.model);

  assert.equal(config.model, DEFAULT_MENTOR_MODEL);
  assert.equal(config.configured, true);
  assert.equal(model.provider, "google.generative-ai");
  assert.equal(model.modelId, "gemini-3.8-flash");
});

test("Gateway or Vercel credentials do not configure direct Google access", () => {
  const legacyEnvironment = {
    GOOGLE_GENERATIVE_AI_API_KEY: "",
    AI_GATEWAY_API_KEY: "test-key",
    VERCEL_OIDC_TOKEN: "test-token",
    VERCEL: "1",
  };
  const config = getMentorModelConfiguration(legacyEnvironment);

  assert.equal(config.configured, false);
});
