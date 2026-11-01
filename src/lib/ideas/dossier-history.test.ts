import assert from "node:assert/strict";
import test from "node:test";
import { parseDossierHistory } from "./dossier-history";

function snapshot(revision: number) {
  return {
    revision,
    created_at: `2026-11-01T10:0${revision}:00Z`,
    dossier: {
      stages: Array.from({ length: 6 }, (_, index) => ({
        stage_number: index + 1,
        stage_key: `stage_${index + 1}`,
        data: { content: `Revision ${revision}, stage ${index + 1}` },
        confirmed_at: "2026-11-01T09:00:00Z",
      })),
    },
  };
}

test("accepts empty history and orders valid snapshots by revision", () => {
  assert.deepEqual(parseDossierHistory([]), []);
  assert.deepEqual(
    parseDossierHistory([snapshot(4), snapshot(2)])?.map(({ revision }) => revision),
    [2, 4],
  );
});

test("rejects malformed or duplicate historical revisions", () => {
  assert.equal(parseDossierHistory([snapshot(1), snapshot(1)]), null);

  const malformed = snapshot(2);
  malformed.dossier.stages[5].stage_number = 5;
  assert.equal(parseDossierHistory([malformed]), null);
});