export type ParticipantMilestoneStatus =
  | "not_submitted"
  | "pending_validation"
  | "validated"
  | "needs_revision"
  | "rejected"
  | "awarded"
  | "corrected";

export type ParticipantScorecard =
  | { state: "unavailable"; reason: string }
  | {
      state: "available";
      version_number: number;
      catalog_version: string;
      maximum_points: 700;
      total_points: number;
      stages: Array<{
        stage_number: number;
        points: number;
        maximum_points: number;
      }>;
      milestones: Array<{
        stage_number: number;
        name: string;
        criteria: string;
        status: ParticipantMilestoneStatus;
        awarded_points: number;
        maximum_points: number;
      }>;
      history: Array<{
        stage_number: number;
        milestone: string;
        kind: "award" | "correction";
        points: number;
        recorded_at: string;
      }>;
    };

const unavailableReasons = new Set([
  "not_found",
  "not_assigned",
  "competition_inactive",
  "scoring_unavailable",
  "inconsistent_history",
]);
const milestoneStatuses = new Set<ParticipantMilestoneStatus>([
  "not_submitted",
  "pending_validation",
  "validated",
  "needs_revision",
  "rejected",
  "awarded",
  "corrected",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isIntegerBetween(
  value: unknown,
  minimum: number,
  maximum: number,
): value is number {
  return (
    Number.isInteger(value) && Number(value) >= minimum && Number(value) <= maximum
  );
}

export function parseParticipantScorecard(
  value: unknown,
): ParticipantScorecard | null {
  if (!isRecord(value) || typeof value.state !== "string") return null;

  if (
    value.state === "unavailable" &&
    typeof value.reason === "string" &&
    unavailableReasons.has(value.reason)
  ) {
    return { state: "unavailable", reason: value.reason };
  }

  if (
    value.state !== "available" ||
    !isIntegerBetween(value.version_number, 1, 100_000) ||
    typeof value.catalog_version !== "string" ||
    value.catalog_version.length > 32 ||
    value.maximum_points !== 700 ||
    !isIntegerBetween(value.total_points, 0, 700) ||
    !Array.isArray(value.stages) ||
    value.stages.length !== 6 ||
    !Array.isArray(value.milestones) ||
    value.milestones.length !== 28 ||
    !Array.isArray(value.history) ||
    value.history.length > 56
  ) {
    return null;
  }

  const stages = value.stages.map((stage, index) => {
    if (
      !isRecord(stage) ||
      stage.stage_number !== index + 1 ||
      !isIntegerBetween(stage.points, 0, 700) ||
      !isIntegerBetween(stage.maximum_points, 1, 700) ||
      Number(stage.points) > Number(stage.maximum_points)
    ) {
      return null;
    }
    return {
      stage_number: stage.stage_number,
      points: stage.points,
      maximum_points: stage.maximum_points,
    };
  });
  const parsedStages = stages.filter(
    (stage): stage is NonNullable<typeof stage> => stage !== null,
  );
  if (parsedStages.length !== stages.length) return null;

  const milestones = value.milestones.map((milestone) => {
    if (
      !isRecord(milestone) ||
      !isIntegerBetween(milestone.stage_number, 1, 6) ||
      typeof milestone.name !== "string" ||
      milestone.name.length === 0 ||
      milestone.name.length > 240 ||
      typeof milestone.criteria !== "string" ||
      milestone.criteria.length === 0 ||
      milestone.criteria.length > 2_000 ||
      typeof milestone.status !== "string" ||
      !milestoneStatuses.has(milestone.status as ParticipantMilestoneStatus) ||
      !isIntegerBetween(milestone.awarded_points, 0, 700) ||
      !isIntegerBetween(milestone.maximum_points, 1, 700) ||
      Number(milestone.awarded_points) > Number(milestone.maximum_points) ||
      (milestone.status === "awarded" && milestone.awarded_points === 0) ||
      (milestone.status !== "awarded" && milestone.awarded_points !== 0)
    ) {
      return null;
    }
    return {
      stage_number: milestone.stage_number,
      name: milestone.name,
      criteria: milestone.criteria,
      status: milestone.status as ParticipantMilestoneStatus,
      awarded_points: milestone.awarded_points,
      maximum_points: milestone.maximum_points,
    };
  });
  const parsedMilestones = milestones.filter(
    (milestone): milestone is NonNullable<typeof milestone> =>
      milestone !== null,
  );
  if (parsedMilestones.length !== milestones.length) return null;

  const history = value.history.map((entry) => {
    if (
      !isRecord(entry) ||
      !isIntegerBetween(entry.stage_number, 1, 6) ||
      typeof entry.milestone !== "string" ||
      entry.milestone.length === 0 ||
      entry.milestone.length > 240 ||
      (entry.kind !== "award" && entry.kind !== "correction") ||
      !isIntegerBetween(entry.points, -700, 700) ||
      (entry.kind === "award" && entry.points <= 0) ||
      (entry.kind === "correction" && entry.points >= 0) ||
      typeof entry.recorded_at !== "string" ||
      !Number.isFinite(Date.parse(entry.recorded_at))
    ) {
      return null;
    }
    return {
      stage_number: entry.stage_number,
      milestone: entry.milestone,
      kind: entry.kind as "award" | "correction",
      points: entry.points,
      recorded_at: entry.recorded_at,
    };
  });
  const parsedHistory = history.filter(
    (entry): entry is NonNullable<typeof entry> => entry !== null,
  );
  if (parsedHistory.length !== history.length) return null;

  return {
    state: "available",
    version_number: value.version_number,
    catalog_version: value.catalog_version,
    maximum_points: 700,
    total_points: value.total_points,
    stages: parsedStages,
    milestones: parsedMilestones,
    history: parsedHistory,
  };
}