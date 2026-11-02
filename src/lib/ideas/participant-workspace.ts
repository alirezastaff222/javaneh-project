import "server-only";

import { createClient } from "@/lib/supabase/server";
import { isUnauthenticatedAuthError } from "@/lib/supabase/auth-errors";
import {
  buildIdeaPortfolio,
  titleFromStageRows,
  type HumanEvaluationStatus,
  type IdeaPortfolioItem,
} from "./portfolio";

export type ParticipantProfile = {
  id: string;
  email: string | null;
};

export type ParticipantWorkspace =
  | { kind: "unauthenticated" }
  | {
      kind: "error";
      code:
        | "ideas_unavailable"
        | "stages_unavailable"
        | "evaluations_unavailable"
        | "feedback_unavailable"
        | "invalid_workspace";
    }
  | {
      kind: "authenticated";
      profile: ParticipantProfile;
      ideas: IdeaPortfolioItem[];
    };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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

export async function loadParticipantWorkspace(): Promise<ParticipantWorkspace> {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError) {
    return isUnauthenticatedAuthError(authError)
      ? { kind: "unauthenticated" }
      : { kind: "error", code: "invalid_workspace" };
  }
  if (!user) return { kind: "unauthenticated" };

  const { data: ideaRows, error: ideasError } = await supabase
    .from("ideas")
    .select("id,group_id,status,revision,current_step,submitted_at,created_at,updated_at")
    .order("updated_at", { ascending: false });

  if (ideasError || !Array.isArray(ideaRows)) {
    console.error("Participant workspace ideas query failed", {
      code: ideasError?.code,
      message: ideasError?.message,
    });
    return { kind: "error", code: "ideas_unavailable" };
  }

  const ideaIds = ideaRows.flatMap((idea) =>
    typeof idea.id === "string" ? [idea.id] : [],
  );
  let stageRows: unknown[] = [];

  if (ideaIds.length > 0) {
    const { data, error: stagesError } = await supabase
      .from("idea_stages")
      .select("idea_id,stage_number,status,data")
      .in("idea_id", ideaIds)
      .order("stage_number", { ascending: true });

    if (stagesError || !Array.isArray(data)) {
      console.error("Participant workspace stages query failed", {
        code: stagesError?.code,
        message: stagesError?.message,
      });
      return { kind: "error", code: "stages_unavailable" };
    }
    stageRows = data;
  }

  const portfolio = buildIdeaPortfolio(ideaRows, stageRows);
  if (!portfolio) return { kind: "error", code: "invalid_workspace" };

  const submittedIdeas = portfolio.filter((idea) => idea.status === "submitted");
  const evaluationResults = await Promise.all(
    submittedIdeas.map(async (idea) => {
      const { data, error } = await supabase.rpc(
        idea.group_id ? "get_group_evaluation_status" : "get_own_idea_evaluation_status",
        { p_idea_id: idea.id },
      );
      if (error) {
        console.error("Participant workspace evaluation query failed", {
          code: error.code,
          message: error.message,
        });
        return { kind: "error" as const, ideaId: idea.id };
      }
      if (!isRecord(data) || data.outcome !== "available") {
        return null;
      }
      return isHumanEvaluationStatus(data.status)
        ? { kind: "available" as const, ideaId: idea.id, status: data.status }
        : null;
    }),
  );
  if (evaluationResults.some((result) => result?.kind === "error")) {
    return { kind: "error", code: "evaluations_unavailable" };
  }
  const validEvaluationResults = evaluationResults.filter(
    (
      result,
    ): result is Extract<
      NonNullable<(typeof evaluationResults)[number]>,
      { kind: "available" }
    > => result?.kind === "available",
  );
  if (validEvaluationResults.length !== evaluationResults.length) {
    return { kind: "error", code: "invalid_workspace" };
  }
  const evaluationStatusByIdea = new Map(
    validEvaluationResults.map(({ ideaId, status }) => [ideaId, status]),
  );
  const feedbackByIdea = new Map<string, IdeaPortfolioItem["publishedFeedback"]>();
  for (const idea of submittedIdeas) {
    const { data: feedbackData, error: feedbackError } = await supabase.rpc(
      idea.group_id ? "get_group_published_feedback" : "get_own_idea_published_feedback",
      { p_idea_id: idea.id },
    );
    if (feedbackError) {
      console.error("Participant workspace feedback query failed", {
        code: feedbackError.code,
        message: feedbackError.message,
      });
      return { kind: "error", code: "feedback_unavailable" };
    }
    if (!isRecord(feedbackData)) {
      return { kind: "error", code: "invalid_workspace" };
    }
    if (feedbackData.outcome === "available") {
      const versionNumber = Number(feedbackData.version_number);
      const publishedAt = typeof feedbackData.published_at === "string"
        ? feedbackData.published_at
        : null;
      const feedbackContent = typeof feedbackData.feedback_content === "string"
        ? feedbackData.feedback_content
        : null;
      if (
        feedbackContent &&
        Number.isInteger(versionNumber) &&
        versionNumber > 0 &&
        publishedAt
      ) {
        feedbackByIdea.set(idea.id, {
          content: feedbackContent,
          version_number: versionNumber,
          published_at: publishedAt,
        });
        continue;
      }
    }
    if (feedbackData.outcome === "empty") {
      feedbackByIdea.set(idea.id, undefined);
      continue;
    }
    if (feedbackData.outcome !== "not_found") {
      return { kind: "error", code: "invalid_workspace" };
    }
    return { kind: "error", code: "invalid_workspace" };
  }
  const ideas: IdeaPortfolioItem[] = [];
  for (const portfolioIdea of portfolio) {
    const idea = {
      ...portfolioIdea,
      title: titleFromStageRows(stageRows, portfolioIdea.id),
    };
    if (idea.status !== "submitted") {
      ideas.push(idea);
      continue;
    }
    const evaluationStatus = evaluationStatusByIdea.get(idea.id);
    if (!evaluationStatus) {
      return { kind: "error", code: "invalid_workspace" };
    }
    ideas.push({
      ...idea,
      evaluationStatus,
      publishedFeedback: feedbackByIdea.get(idea.id),
    });
  }

  return {
    kind: "authenticated",
    profile: { id: user.id, email: user.email ?? null },
    ideas,
  };
}
