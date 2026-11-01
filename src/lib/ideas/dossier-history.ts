export type DossierHistoryStage = {
  stage_number: number;
  stage_key: string;
  data: Record<string, unknown>;
  confirmed_at: string | null;
};

export type DossierHistorySnapshot = {
  revision: number;
  dossier: { stages: DossierHistoryStage[] };
  created_at: string;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseDossierHistory(value: unknown): DossierHistorySnapshot[] | null {
  if (!Array.isArray(value)) return null;

  const revisions = new Set<number>();
  const snapshots: DossierHistorySnapshot[] = [];

  for (const row of value) {
    if (
      !isRecord(row) ||
      !Number.isInteger(row.revision) ||
      Number(row.revision) < 1 ||
      typeof row.created_at !== "string" ||
      !Number.isFinite(Date.parse(row.created_at)) ||
      !isRecord(row.dossier) ||
      !Array.isArray(row.dossier.stages) ||
      revisions.has(Number(row.revision))
    ) {
      return null;
    }

    const stages: DossierHistoryStage[] = [];
    const stageNumbers = new Set<number>();
    for (const stage of row.dossier.stages) {
      if (
        !isRecord(stage) ||
        !Number.isInteger(stage.stage_number) ||
        Number(stage.stage_number) < 1 ||
        Number(stage.stage_number) > 6 ||
        typeof stage.stage_key !== "string" ||
        !isRecord(stage.data) ||
        (stage.confirmed_at !== null && typeof stage.confirmed_at !== "string") ||
        stageNumbers.has(Number(stage.stage_number))
      ) {
        return null;
      }

      const stageNumber = Number(stage.stage_number);
      stageNumbers.add(stageNumber);
      stages.push({
        stage_number: stageNumber,
        stage_key: stage.stage_key,
        data: stage.data,
        confirmed_at: stage.confirmed_at,
      });
    }

    if (stages.length !== 6 || stageNumbers.size !== 6) return null;
    stages.sort((left, right) => left.stage_number - right.stage_number);
    revisions.add(Number(row.revision));
    snapshots.push({
      revision: Number(row.revision),
      dossier: { stages },
      created_at: row.created_at,
    });
  }

  return snapshots.sort((left, right) => left.revision - right.revision);
}