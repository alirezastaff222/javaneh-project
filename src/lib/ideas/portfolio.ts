export const IDEA_QUOTA_LIMIT = 3;

export function getIdeaCountForScope(
  ideas: Pick<IdeaPortfolioItem, "group_id">[],
  groupId: string | null,
): number {
  return ideas.filter((idea) => idea.group_id === groupId).length;
}

export function getAvailableIdeaSlots(
  ideaCount: number,
  portfolioLoaded: boolean,
): number | null {
  return portfolioLoaded
    ? Math.max(0, IDEA_QUOTA_LIMIT - ideaCount)
    : null;
}

export function canCreateIdea(
  ideaCount: number,
  portfolioLoaded: boolean,
  hasPendingRequest: boolean,
): boolean {
  return (
    hasPendingRequest ||
    (getAvailableIdeaSlots(ideaCount, portfolioLoaded) ?? 0) > 0
  );
}

export type IdeaStatus = "draft" | "in_progress" | "submitted";
export type HumanEvaluationStatus =
  | "awaiting_review"
  | "in_progress"
  | "completed";
export type StageStatus =
  | "not_started"
  | "in_progress"
  | "pending_confirmation"
  | "confirmed"
  | "needs_revision"
  | "locked";

export type IdeaNextAction =
  | "awaiting_review"
  | "submit"
  | "confirm"
  | "revise"
  | "continue";

export type PublishedFeedback = {
  content: string;
  version_number: number;
  published_at: string;
};

export type IdeaPortfolioItem = {
  id: string;
  group_id: string | null;
  title?: string;
  status: IdeaStatus;
  revision: number;
  current_step: number;
  submitted_at: string | null;
  created_at: string;
  updated_at: string;
  completedStageCount: number;
  currentStageStatus: StageStatus;
  nextAction: IdeaNextAction;
  evaluationStatus?: HumanEvaluationStatus;
  publishedFeedback?: PublishedFeedback;
};

export function titleFromStageRows(
  stageRows: unknown[],
  ideaId: string,
): string | undefined {
  const stage = stageRows.find(
    (row) =>
      isRecord(row) &&
      row.idea_id === ideaId &&
      row.stage_number === 1 &&
      isRecord(row.data) &&
      typeof row.data.content === "string",
  );
  if (!isRecord(stage) || !isRecord(stage.data)) return undefined;
  const firstLine = (stage.data.content as string)
    .trim()
    .split(/\r?\n/, 1)[0]
    .trim();
  if (!firstLine) return undefined;
  return firstLine.length > 72 ? `${firstLine.slice(0, 69).trimEnd()}...` : firstLine;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isIdeaStatus(value: unknown): value is IdeaStatus {
  return value === "draft" || value === "in_progress" || value === "submitted";
}

function isStageStatus(value: unknown): value is StageStatus {
  return (
    value === "not_started" ||
    value === "in_progress" ||
    value === "pending_confirmation" ||
    value === "confirmed" ||
    value === "needs_revision" ||
    value === "locked"
  );
}

function isHumanEvaluationStatus(
  value: unknown,
): value is HumanEvaluationStatus {
  return (
    value === "awaiting_review" ||
    value === "in_progress" ||
    value === "completed"
  );
}

function isPublishedFeedback(value: unknown): value is PublishedFeedback {
  return (
    isRecord(value) &&
    typeof value.content === "string" &&
    Number.isInteger(value.version_number) &&
    Number(value.version_number) > 0 &&
    typeof value.published_at === "string"
  );
}

const nextActionForStage: Record<StageStatus, IdeaNextAction> = {
  not_started: "continue",
  in_progress: "continue",
  pending_confirmation: "confirm",
  confirmed: "continue",
  needs_revision: "revise",
  locked: "continue",
};

export function buildIdeaPortfolio(
  ideaRows: unknown,
  stageRows: unknown,
): IdeaPortfolioItem[] | null {
  if (!Array.isArray(ideaRows) || !Array.isArray(stageRows)) return null;

  const stagesByIdea = new Map<string, Map<number, StageStatus>>();
  for (const row of stageRows) {
    if (
      !isRecord(row) ||
      typeof row.idea_id !== "string" ||
      !Number.isInteger(row.stage_number) ||
      Number(row.stage_number) < 1 ||
      Number(row.stage_number) > 7 ||
      !isStageStatus(row.status)
    ) {
      return null;
    }

    const stages = stagesByIdea.get(row.idea_id) ?? new Map();
    const stageNumber = Number(row.stage_number);
    if (stages.has(stageNumber)) return null;
    stages.set(stageNumber, row.status);
    stagesByIdea.set(row.idea_id, stages);
  }

  const result: IdeaPortfolioItem[] = [];
  const ideaIds = new Set<string>();
  for (const row of ideaRows) {
    if (
      !isRecord(row) ||
      typeof row.id !== "string" ||
      (row.group_id !== undefined &&
        row.group_id !== null &&
        typeof row.group_id !== "string") ||
      !isIdeaStatus(row.status) ||
      !Number.isInteger(row.revision) ||
      Number(row.revision) < 1 ||
      !Number.isInteger(row.current_step) ||
      Number(row.current_step) < 1 ||
      Number(row.current_step) > 7 ||
      (row.submitted_at !== null && typeof row.submitted_at !== "string") ||
      typeof row.created_at !== "string" ||
      typeof row.updated_at !== "string"
    ) {
      return null;
    }
    if (ideaIds.has(row.id)) return null;
    ideaIds.add(row.id);

    const stages = stagesByIdea.get(row.id);
    if (
      !stages ||
      stages.size !== 7 ||
      stages.get(7) !== "locked"
    ) {
      return null;
    }

    const completedStageCount = Array.from({ length: 6 }, (_, index) =>
      stages.get(index + 1) === "confirmed",
    ).filter(Boolean).length;
    const currentStageStatus = stages.get(Number(row.current_step));
    if (!currentStageStatus) return null;

    const nextAction: IdeaNextAction =
      row.status === "submitted"
        ? "awaiting_review"
        : completedStageCount === 6
          ? "submit"
          : nextActionForStage[currentStageStatus];

    result.push({
      id: row.id,
      group_id: typeof row.group_id === "string" ? row.group_id : null,
      status: row.status,
      revision: Number(row.revision),
      current_step: Number(row.current_step),
      submitted_at: row.submitted_at,
      created_at: row.created_at,
      updated_at: row.updated_at,
      completedStageCount,
      currentStageStatus,
      nextAction,
    });
  }

  if (Array.from(stagesByIdea.keys()).some((ideaId) => !ideaIds.has(ideaId))) {
    return null;
  }

  return result;
}

export function isIdeaPortfolioItem(value: unknown): value is IdeaPortfolioItem {
  return (
    isRecord(value) &&
    typeof value.id === "string" &&
    (value.group_id === null || typeof value.group_id === "string") &&
    (value.title === undefined || typeof value.title === "string") &&
    isIdeaStatus(value.status) &&
    Number.isInteger(value.revision) &&
    Number(value.revision) > 0 &&
    Number.isInteger(value.current_step) &&
    Number(value.current_step) >= 1 &&
    Number(value.current_step) <= 7 &&
    (value.submitted_at === null || typeof value.submitted_at === "string") &&
    typeof value.created_at === "string" &&
    typeof value.updated_at === "string" &&
    Number.isInteger(value.completedStageCount) &&
    Number(value.completedStageCount) >= 0 &&
    Number(value.completedStageCount) <= 6 &&
    isStageStatus(value.currentStageStatus) &&
    (value.evaluationStatus === undefined ||
      (value.status === "submitted" &&
        isHumanEvaluationStatus(value.evaluationStatus))) &&
    (value.publishedFeedback === undefined ||
      (value.status === "submitted" && isPublishedFeedback(value.publishedFeedback))) &&
    [
      "awaiting_review",
      "submit",
      "confirm",
      "revise",
      "continue",
    ].includes(String(value.nextAction))
  );
}
