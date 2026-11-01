export type PublisherDraft = {
  draftId: string;
  ideaId: string;
  cycleId: string;
  content: string;
  previousPublishedVersionId: string | null;
  updatedAt: string;
  canPublish: boolean;
};

export type PublishedFeedbackVersion = {
  versionId: string;
  versionNumber: number;
  publishedAt: string;
};

export type PublisherPageState =
  | { kind: "unauthenticated" }
  | { kind: "forbidden" }
  | { kind: "error" }
  | { kind: "loaded"; drafts: PublisherDraft[] };

type Fetcher = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

type OperationResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseEligiblePublisherDrafts(
  value: unknown,
  actorId: string,
): PublisherDraft[] | null {
  if (
    !isRecord(value) ||
    value.outcome !== "available" ||
    !Array.isArray(value.drafts)
  ) {
    return null;
  }

  const drafts: PublisherDraft[] = [];
  for (const candidate of value.drafts) {
    if (
      !isRecord(candidate) ||
      typeof candidate.draft_id !== "string" ||
      typeof candidate.idea_id !== "string" ||
      typeof candidate.cycle_id !== "string" ||
      typeof candidate.feedback_content !== "string" ||
      (candidate.previous_published_version_id !== null &&
        typeof candidate.previous_published_version_id !== "string") ||
      typeof candidate.updated_at !== "string" ||
      typeof candidate.evaluator_user_id !== "string"
    ) {
      return null;
    }

    drafts.push({
      draftId: candidate.draft_id,
      ideaId: candidate.idea_id,
      cycleId: candidate.cycle_id,
      content: candidate.feedback_content,
      previousPublishedVersionId: candidate.previous_published_version_id,
      updatedAt: candidate.updated_at,
      canPublish:
        actorId.length > 0 && candidate.evaluator_user_id !== actorId,
    });
  }

  return drafts;
}

export async function loadEligiblePublisherDrafts(
  actorId: string,
  fetcher: Fetcher = fetch,
): Promise<PublisherPageState> {
  try {
    const response = await fetcher("/api/ideas/feedback/publication", {
      cache: "no-store",
    });
    if (response.status === 401) return { kind: "unauthenticated" };
    if (response.status === 403) return { kind: "forbidden" };
    if (!response.ok) return { kind: "error" };

    const payload: unknown = await response.json();
    const drafts = parseEligiblePublisherDrafts(payload, actorId);
    return drafts ? { kind: "loaded", drafts } : { kind: "error" };
  } catch {
    return { kind: "error" };
  }
}

export async function publishEligibleFeedbackDraft(
  draftId: string,
  fetcher: Fetcher = fetch,
): Promise<OperationResult<PublishedFeedbackVersion>> {
  try {
    const response = await fetcher("/api/ideas/feedback/publication", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ draftId }),
    });
    const payload: unknown = await response.json();
    if (isRecord(payload) && payload.outcome === "same_user") {
      return {
        ok: false,
        error: "You cannot publish feedback that you evaluated.",
      };
    }
    if (isRecord(payload) && payload.outcome === "stale_draft") {
      return {
        ok: false,
        error: "This draft is based on an older published version. Refresh and review it again.",
      };
    }
    if (
      !response.ok ||
      !isRecord(payload) ||
      payload.outcome !== "published" ||
      typeof payload.version_id !== "string" ||
      typeof payload.version_number !== "number" ||
      !Number.isInteger(payload.version_number) ||
      typeof payload.published_at !== "string"
    ) {
      return {
        ok: false,
        error: "The feedback draft could not be published.",
      };
    }

    return {
      ok: true,
      value: {
        versionId: payload.version_id,
        versionNumber: payload.version_number,
        publishedAt: payload.published_at,
      },
    };
  } catch {
    return {
      ok: false,
      error: "The feedback draft could not be published.",
    };
  }
}
