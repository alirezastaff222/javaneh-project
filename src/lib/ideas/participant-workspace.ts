import "server-only";

import { createClient } from "@/lib/supabase/server";
import {
  buildIdeaPortfolio,
  type HumanEvaluationStatus,
  type IdeaPortfolioItem,
} from "./portfolio";

export type ParticipantProfile = {
  id: string;
  email: string | null;
};

export type ParticipantWorkspace =
  | { kind: "unauthenticated" }
  | { kind: "error" }
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

  if (authError) return { kind: "error" };
  if (!user) return { kind: "unauthenticated" };

  const { data: ideaRows, error: ideasError } = await supabase
    .from("ideas")
    .select("id,status,revision,current_step,submitted_at,created_at,updated_at")
    .order("updated_at", { ascending: false });

  if (ideasError || !Array.isArray(ideaRows)) return { kind: "error" };

  const ideaIds = ideaRows.flatMap((idea) =>
    typeof idea.id === "string" ? [idea.id] : [],
  );
  let stageRows: unknown[] = [];

  if (ideaIds.length > 0) {
    const { data, error: stagesError } = await supabase
      .from("idea_stages")
      .select("idea_id,stage_number,status")
      .in("idea_id", ideaIds)
      .order("stage_number", { ascending: true });

    if (stagesError || !Array.isArray(data)) return { kind: "error" };
    stageRows = data;
  }

  const portfolio = buildIdeaPortfolio(ideaRows, stageRows);
  if (!portfolio) return { kind: "error" };

  const submittedIdeas = portfolio.filter((idea) => idea.status === "submitted");
  const evaluationResults = await Promise.all(
    submittedIdeas.map(async (idea) => {
      const { data, error } = await supabase.rpc(
        "get_own_idea_evaluation_status",
        { p_idea_id: idea.id },
      );
      if (error || !isRecord(data) || data.outcome !== "available") {
        return null;
      }
      return isHumanEvaluationStatus(data.status)
        ? { ideaId: idea.id, status: data.status }
        : null;
    }),
  );
  const validEvaluationResults = evaluationResults.filter(
    (result): result is NonNullable<typeof result> => result !== null,
  );
  if (validEvaluationResults.length !== evaluationResults.length) {
    return { kind: "error" };
  }
  const evaluationStatusByIdea = new Map(
    validEvaluationResults.map((result) => [result.ideaId, result.status]),
  );
  const feedbackByIdea = new Map<string, IdeaPortfolioItem["publishedFeedback"]>();
  for (const idea of submittedIdeas) {
    const { data: feedbackData, error: feedbackError } = await supabase.rpc(
      "get_own_idea_published_feedback",
      { p_idea_id: idea.id },
    );
    if (feedbackError) {
      feedbackByIdea.set(idea.id, undefined);
      continue;
    }
    if (!isRecord(feedbackData)) {
      feedbackByIdea.set(idea.id, undefined);
      continue;
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
    feedbackByIdea.set(idea.id, undefined);
  }
  const ideas: IdeaPortfolioItem[] = [];
  for (const idea of portfolio) {
    if (idea.status !== "submitted") {
      ideas.push(idea);
      continue;
    }
    const evaluationStatus = evaluationStatusByIdea.get(idea.id);
    if (!evaluationStatus) return { kind: "error" };
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
