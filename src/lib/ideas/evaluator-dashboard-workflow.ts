export type FeedbackDraft = {
  draftId: string;
  content: string;
  previousPublishedVersionId: string | null;
};

type WorkflowResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

type Fetcher = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseDraft(value: unknown): FeedbackDraft | null {
  if (
    !isRecord(value) ||
    typeof value.draft_id !== "string" ||
    typeof value.feedback_content !== "string" ||
    (value.previous_published_version_id !== null &&
      typeof value.previous_published_version_id !== "string")
  ) {
    return null;
  }
  return {
    draftId: value.draft_id,
    content: value.feedback_content,
    previousPublishedVersionId: value.previous_published_version_id,
  };
}

async function postDraft(
  path: string,
  ideaId: string,
  content: string,
  fetcher: Fetcher,
): Promise<WorkflowResult<FeedbackDraft>> {
  try {
    const response = await fetcher(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ideaId, content }),
    });
    const payload: unknown = await response.json();
    if (
      isRecord(payload) &&
      payload.outcome === "no_published_version"
    ) {
      return {
        ok: false,
        error: "A correction requires previously published feedback.",
      };
    }
    if (isRecord(payload) && payload.outcome === "draft_exists") {
      return {
        ok: false,
        error: "A draft already exists. Load it to continue editing.",
      };
    }
    if (
      !response.ok ||
      !isRecord(payload) ||
      payload.outcome !== "created" ||
      typeof payload.draft_id !== "string" ||
      (payload.previous_published_version_id !== null &&
        typeof payload.previous_published_version_id !== "string")
    ) {
      return {
        ok: false,
        error: "The feedback draft could not be created.",
      };
    }
    return {
      ok: true,
      value: {
        draftId: payload.draft_id,
        content,
        previousPublishedVersionId: payload.previous_published_version_id,
      },
    };
  } catch {
    return { ok: false, error: "The feedback draft could not be created." };
  }
}

export async function loadEvaluatorFeedbackDraft(
  ideaId: string,
  fetcher: Fetcher = fetch,
): Promise<WorkflowResult<FeedbackDraft | null>> {
  try {
    const response = await fetcher(
      `/api/ideas/feedback/drafts?ideaId=${encodeURIComponent(ideaId)}`,
      { cache: "no-store" },
    );
    const payload: unknown = await response.json();
    if (!response.ok || !isRecord(payload)) {
      return { ok: false, error: "The feedback draft could not be loaded." };
    }
    if (payload.outcome === "not_found") return { ok: true, value: null };
    if (payload.outcome !== "available") {
      return { ok: false, error: "The feedback draft could not be loaded." };
    }
    const draft = parseDraft(payload);
    return draft
      ? { ok: true, value: draft }
      : { ok: false, error: "The feedback draft could not be loaded." };
  } catch {
    return { ok: false, error: "The feedback draft could not be loaded." };
  }
}

export function createEvaluatorFeedbackDraft(
  ideaId: string,
  content: string,
  fetcher: Fetcher = fetch,
) {
  return postDraft("/api/ideas/feedback/drafts", ideaId, content, fetcher);
}

export function createEvaluatorCorrectionDraft(
  ideaId: string,
  content: string,
  fetcher: Fetcher = fetch,
) {
  return postDraft(
    "/api/ideas/feedback/drafts/correction",
    ideaId,
    content,
    fetcher,
  );
}

export async function saveEvaluatorFeedbackDraft(
  draftId: string,
  content: string,
  fetcher: Fetcher = fetch,
): Promise<WorkflowResult<null>> {
  try {
    const response = await fetcher("/api/ideas/feedback/drafts", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ draftId, content }),
    });
    const payload: unknown = await response.json();
    if (!response.ok || !isRecord(payload) || payload.outcome !== "updated") {
      return { ok: false, error: "The feedback draft could not be saved." };
    }
    return { ok: true, value: null };
  } catch {
    return { ok: false, error: "The feedback draft could not be saved." };
  }
}
