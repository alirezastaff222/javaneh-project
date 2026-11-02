"use client";

import { useMemo, useState } from "react";

import {
  parseAssignedIdeas,
  parseAssignedDossier,
  type AssignmentLoadState,
  type AssignedDossier,
} from "@/lib/ideas/evaluator-api";
import {
  createEvaluatorCorrectionDraft,
  createEvaluatorFeedbackDraft,
  loadEvaluatorFeedbackDraft,
  saveEvaluatorFeedbackDraft,
  type FeedbackDraft,
} from "@/lib/ideas/evaluator-dashboard-workflow";
import { IDEA_STAGES } from "@/lib/ideas/stages";
import MilestoneValidationQueue from "./milestone-validation-queue";
import JuryPanel from "./jury-panel";

type DossierState =
  | { kind: "closed" }
  | { kind: "loading"; ideaId: string }
  | { kind: "error"; ideaId: string }
  | { kind: "loaded"; ideaId: string; dossier: AssignedDossier };

type FeedbackState =
  | { kind: "closed" }
  | { kind: "loading"; ideaId: string }
  | { kind: "error"; ideaId: string; message: string }
  | {
      kind: "empty";
      ideaId: string;
      content: string;
      message: { kind: "success" | "error"; text: string } | null;
      saving: boolean;
    }
  | {
      kind: "draft";
      ideaId: string;
      draft: FeedbackDraft;
      content: string;
      message: { kind: "success" | "error"; text: string } | null;
      saving: boolean;
    };

function statusLabel(status: string) {
  switch (status) {
    case "awaiting_review":
      return "Awaiting review";
    case "in_progress":
      return "In progress";
    case "completed":
      return "Completed";
    default:
      return status;
  }
}

export function EvaluatorDashboard({
  initialAssignments,
}: {
  initialAssignments: AssignmentLoadState;
}) {
  const [assignments, setAssignments] =
    useState<AssignmentLoadState>(initialAssignments);
  const [status, setStatus] = useState<string | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [dossierState, setDossierState] = useState<DossierState>({
    kind: "closed",
  });
  const [feedbackState, setFeedbackState] = useState<FeedbackState>({
    kind: "closed",
  });
  const items = useMemo(
    () => (assignments.kind === "loaded" ? assignments.items : []),
    [assignments],
  );

  const summary = useMemo(() => {
    return {
      total: items.length,
      inProgress: items.filter((idea) => idea.status === "in_progress").length,
      awaitingReview: items.filter((idea) => idea.status === "awaiting_review").length,
      completed: items.filter((idea) => idea.status === "completed").length,
    };
  }, [items]);

  async function refreshAssignments() {
    setIsRefreshing(true);
    try {
      const response = await fetch("/api/evaluator/assignments");
      const payload: unknown = await response.json();
      if (!response.ok) {
        setAssignments({ kind: "error" });
        return;
      }
      setAssignments(parseAssignedIdeas(payload, null));
    } catch {
      setAssignments({ kind: "error" });
    } finally {
      setIsRefreshing(false);
    }
  }

  async function handleAction(action: "start" | "complete", ideaId: string) {
    const response = await fetch(`/api/evaluator/evaluations/${action}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ideaId }),
    });
    const payload = await response.json();
    if (!response.ok) {
      setStatus(payload.error ?? "The evaluation action failed.");
      return;
    }

    const outcome = typeof payload.outcome === "string" ? payload.outcome : "updated";
    setStatus(`Action outcome: ${outcome}`);
    await refreshAssignments();
  }

  async function loadAssignedDossier(ideaId: string) {
    setDossierState({ kind: "loading", ideaId });
    try {
      const response = await fetch(
        `/api/evaluator/assignments/${encodeURIComponent(ideaId)}/dossier`,
        { cache: "no-store" },
      );
      const payload: unknown = await response.json();
      const parsed = parseAssignedDossier(payload);
      if (!response.ok || !parsed.success) {
        setDossierState({ kind: "error", ideaId });
        return;
      }
      setDossierState({ kind: "loaded", ideaId, dossier: parsed.data });
    } catch {
      setDossierState({ kind: "error", ideaId });
    }
  }

  async function loadFeedbackDraft(ideaId: string) {
    setFeedbackState({ kind: "loading", ideaId });
    const result = await loadEvaluatorFeedbackDraft(ideaId);
    if (!result.ok) {
      setFeedbackState({ kind: "error", ideaId, message: result.error });
      return;
    }
    if (!result.value) {
      setFeedbackState({
        kind: "empty",
        ideaId,
        content: "",
        message: null,
        saving: false,
      });
      return;
    }
    setFeedbackState({
      kind: "draft",
      ideaId,
      draft: result.value,
      content: result.value.content,
      message: null,
      saving: false,
    });
  }

  async function createFeedbackDraft(ideaId: string, correction: boolean) {
    if (feedbackState.kind !== "empty" || feedbackState.ideaId !== ideaId) return;
    const content = feedbackState.content;
    setFeedbackState({ ...feedbackState, saving: true, message: null });
    const result = correction
      ? await createEvaluatorCorrectionDraft(ideaId, content)
      : await createEvaluatorFeedbackDraft(ideaId, content);
    if (!result.ok) {
      setFeedbackState({
        kind: "empty",
        ideaId,
        content,
        message: { kind: "error", text: result.error },
        saving: false,
      });
      return;
    }
    setFeedbackState({
      kind: "draft",
      ideaId,
      draft: result.value,
      content,
      message: {
        kind: "success",
        text: correction
          ? "Correction draft created. It is still private and has not been published."
          : "Draft created. It is still private and has not been published.",
      },
      saving: false,
    });
  }

  async function saveFeedbackDraft(ideaId: string) {
    if (feedbackState.kind !== "draft" || feedbackState.ideaId !== ideaId) return;
    const { draft, content } = feedbackState;
    setFeedbackState({ ...feedbackState, saving: true, message: null });
    const result = await saveEvaluatorFeedbackDraft(draft.draftId, content);
    setFeedbackState({
      kind: "draft",
      ideaId,
      draft,
      content,
      message: result.ok
        ? {
            kind: "success",
            text: "Draft saved. Saving does not publish feedback or change evaluation status.",
          }
        : { kind: "error", text: result.error },
      saving: false,
    });
  }

  return (
    <main className="mx-auto max-w-6xl space-y-6 p-6">
      <MilestoneValidationQueue />
      <JuryPanel />
      <header className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="text-sm uppercase tracking-[0.2em] text-foreground/60">
            Evaluation workflow
          </p>
          <h1 className="mt-2 text-3xl font-semibold">Assigned ideas</h1>
        </div>
        <button
          type="button"
          onClick={() => void refreshAssignments()}
          className="inline-flex h-11 items-center rounded-lg border border-foreground/20 px-4 font-medium transition-colors hover:bg-foreground/5"
        >
          {isRefreshing ? "Refreshing..." : "Refresh"}
        </button>
      </header>

      <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <div className="rounded-xl border border-foreground/10 bg-foreground/3 p-4">
          <p className="text-xs uppercase tracking-[0.18em] text-foreground/50">Total</p>
          <p className="mt-2 text-2xl font-semibold">{summary.total}</p>
        </div>
        <div className="rounded-xl border border-foreground/10 bg-foreground/3 p-4">
          <p className="text-xs uppercase tracking-[0.18em] text-foreground/50">Awaiting review</p>
          <p className="mt-2 text-2xl font-semibold">{summary.awaitingReview}</p>
        </div>
        <div className="rounded-xl border border-foreground/10 bg-foreground/3 p-4">
          <p className="text-xs uppercase tracking-[0.18em] text-foreground/50">In progress</p>
          <p className="mt-2 text-2xl font-semibold">{summary.inProgress}</p>
        </div>
        <div className="rounded-xl border border-foreground/10 bg-foreground/3 p-4">
          <p className="text-xs uppercase tracking-[0.18em] text-foreground/50">Completed</p>
          <p className="mt-2 text-2xl font-semibold">{summary.completed}</p>
        </div>
      </section>

      {status ? (
        <div className="rounded-lg border border-amber-500/30 bg-amber-500/8 px-4 py-3 text-sm text-amber-800">
          {status}
        </div>
      ) : null}

      {assignments.kind === "error" ? (
        <div className="rounded-xl border border-red-500/30 p-6 text-center">
          <p role="alert" className="text-sm text-red-700">
            Assignments could not be loaded. Please try again.
          </p>
          <button
            type="button"
            disabled={isRefreshing}
            onClick={() => void refreshAssignments()}
            className="mt-4 inline-flex h-11 items-center rounded-lg border border-foreground/20 px-4 font-medium disabled:opacity-60"
          >
            {isRefreshing ? "Retrying..." : "Retry loading assignments"}
          </button>
        </div>
      ) : assignments.kind === "empty" ? (
        <div className="rounded-xl border border-dashed border-foreground/20 p-10 text-center text-foreground/70">
          No submitted ideas are currently assigned to you.
        </div>
      ) : assignments.kind === "loaded" ? (
        <div className="space-y-4">
          {items.map((idea) => (
            <article
              key={idea.idea_id}
              className="rounded-xl border border-foreground/10 bg-foreground/3 p-5"
            >
              <div className="flex flex-col gap-4 lg:flex-row lg:items-center lg:justify-between">
                <div className="space-y-2">
                  <div className="flex items-center gap-3">
                    <span className="rounded-full border border-foreground/15 px-2.5 py-1 text-xs font-medium uppercase tracking-[0.18em] text-foreground/70">
                      {statusLabel(idea.status)}
                    </span>
                    <span className="text-sm text-foreground/60">Stage {idea.current_step}</span>
                  </div>
                  <p className="font-mono text-sm text-foreground/70">Idea ID: {idea.idea_id}</p>
                  <div className="flex flex-wrap gap-x-4 gap-y-1 text-sm text-foreground/60">
                    <span>Submitted: {idea.submitted_at ? new Date(idea.submitted_at).toLocaleString() : "—"}</span>
                    <span>Assigned: {idea.assigned_at ? new Date(idea.assigned_at).toLocaleString() : "—"}</span>
                    <span>Started: {idea.started_at ? new Date(idea.started_at).toLocaleString() : "—"}</span>
                  </div>
                </div>
                <div className="flex gap-3">
                  <button
                    type="button"
                    disabled={
                      dossierState.kind === "loading" &&
                      dossierState.ideaId === idea.idea_id
                    }
                    onClick={() => {
                      if (
                        dossierState.kind === "loaded" &&
                        dossierState.ideaId === idea.idea_id
                      ) {
                        setDossierState({ kind: "closed" });
                      } else {
                        void loadAssignedDossier(idea.idea_id);
                      }
                    }}
                    className="inline-flex h-11 items-center rounded-lg border border-foreground/20 px-4 font-medium hover:bg-foreground/5 disabled:opacity-60"
                  >
                    {dossierState.kind === "loading" &&
                    dossierState.ideaId === idea.idea_id
                      ? "Loading dossier..."
                      : dossierState.kind === "error" &&
                          dossierState.ideaId === idea.idea_id
                        ? "Retry dossier"
                        : dossierState.kind === "loaded" &&
                            dossierState.ideaId === idea.idea_id
                          ? "Close dossier"
                          : "View submitted dossier"}
                  </button>
                  {idea.status === "awaiting_review" ? (
                    <button
                      type="button"
                      onClick={() => void handleAction("start", idea.idea_id)}
                      className="inline-flex h-11 items-center rounded-lg bg-foreground text-background px-4 font-medium"
                    >
                      Start evaluation
                    </button>
                  ) : null}
                  {idea.status === "in_progress" ? (
                    <button
                      type="button"
                      onClick={() => void handleAction("complete", idea.idea_id)}
                      className="inline-flex h-11 items-center rounded-lg border border-foreground/20 px-4 font-medium hover:bg-foreground/5"
                    >
                      Complete evaluation
                    </button>
                  ) : null}
                </div>
              </div>
              {dossierState.kind === "loading" &&
              dossierState.ideaId === idea.idea_id ? (
                <p role="status" className="mt-4 text-sm text-foreground/65">
                  Loading the assigned submitted dossier...
                </p>
              ) : null}
              {dossierState.kind === "error" &&
              dossierState.ideaId === idea.idea_id ? (
                <p role="alert" className="mt-4 text-sm text-red-700">
                  The assigned dossier could not be loaded. Try again.
                </p>
              ) : null}
              {dossierState.kind === "loaded" &&
              dossierState.ideaId === idea.idea_id ? (
                <section className="mt-5 rounded-lg border border-foreground/10 p-4">
                  <h2 className="font-semibold">
                    Submitted dossier — revision {dossierState.dossier.revision}
                  </h2>
                  <p className="mt-1 text-sm text-foreground/65">
                    This view contains only the submitted revision for this assigned evaluation.
                  </p>
                  <ol className="mt-4 divide-y divide-foreground/10">
                    {dossierState.dossier.dossier.stages.map((stage) => (
                      <li key={stage.stage_number} className="py-4 first:pt-0 last:pb-0">
                        <h3 className="font-medium">
                          {IDEA_STAGES[stage.stage_number - 1].title}
                        </h3>
                        <pre
                          dir="auto"
                          className="mt-2 whitespace-pre-wrap break-words rounded-lg bg-foreground/[0.03] p-3 font-sans text-sm leading-7"
                        >
                          {typeof stage.data.content === "string"
                            ? stage.data.content || "No content was submitted for this stage."
                            : JSON.stringify(stage.data, null, 2)}
                        </pre>
                      </li>
                    ))}
                  </ol>
                </section>
              ) : null}
              {idea.status === "completed" ? (
                <section className="mt-5 rounded-lg border border-foreground/10 p-4">
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div>
                      <h2 className="font-semibold">Private feedback draft</h2>
                      <p className="mt-1 text-sm text-foreground/65">
                        Drafting is separate from evaluation completion and publication.
                      </p>
                    </div>
                    <button
                      type="button"
                      disabled={
                        feedbackState.kind === "loading" &&
                        feedbackState.ideaId === idea.idea_id
                      }
                      onClick={() => {
                        if (
                          feedbackState.kind !== "closed" &&
                          feedbackState.ideaId === idea.idea_id
                        ) {
                          setFeedbackState({ kind: "closed" });
                        } else {
                          void loadFeedbackDraft(idea.idea_id);
                        }
                      }}
                      className="inline-flex h-10 items-center rounded-lg border border-foreground/20 px-3 text-sm font-medium disabled:opacity-60"
                    >
                      {feedbackState.kind === "loading" &&
                      feedbackState.ideaId === idea.idea_id
                        ? "Loading draft..."
                        : feedbackState.kind !== "closed" &&
                            feedbackState.ideaId === idea.idea_id
                          ? "Close draft"
                          : "Load private draft"}
                    </button>
                  </div>
                  {feedbackState.kind === "loading" &&
                  feedbackState.ideaId === idea.idea_id ? (
                    <p role="status" className="mt-4 text-sm text-foreground/65">
                      Loading your private draft...
                    </p>
                  ) : null}
                  {feedbackState.kind === "error" &&
                  feedbackState.ideaId === idea.idea_id ? (
                    <div className="mt-4">
                      <p role="alert" className="text-sm text-red-700">
                        {feedbackState.message}
                      </p>
                      <button
                        type="button"
                        onClick={() => void loadFeedbackDraft(idea.idea_id)}
                        className="mt-3 inline-flex h-10 items-center rounded-lg border border-foreground/20 px-3 text-sm font-medium"
                      >
                        Retry loading draft
                      </button>
                    </div>
                  ) : null}
                  {feedbackState.kind === "empty" &&
                  feedbackState.ideaId === idea.idea_id ? (
                    <div className="mt-4 space-y-3">
                      <label className="block text-sm font-medium">
                        Feedback
                        <textarea
                          value={feedbackState.content}
                          disabled={feedbackState.saving}
                          onChange={(event) =>
                            setFeedbackState({
                              ...feedbackState,
                              content: event.target.value,
                            })
                          }
                          rows={6}
                          maxLength={20000}
                          className="mt-2 block w-full rounded-lg border border-foreground/20 bg-background p-3 font-normal"
                        />
                      </label>
                      {feedbackState.message ? (
                        <p
                          role={feedbackState.message.kind === "error" ? "alert" : "status"}
                          className={`text-sm ${
                            feedbackState.message.kind === "error"
                              ? "text-red-700"
                              : "text-foreground/70"
                          }`}
                        >
                          {feedbackState.message.text}
                        </p>
                      ) : null}
                      <div className="flex flex-wrap gap-3">
                        <button
                          type="button"
                          disabled={feedbackState.saving || !feedbackState.content.trim()}
                          onClick={() => void createFeedbackDraft(idea.idea_id, false)}
                          className="inline-flex h-10 items-center rounded-lg bg-foreground px-3 text-sm font-medium text-background disabled:opacity-60"
                        >
                          {feedbackState.saving ? "Saving..." : "Create private draft"}
                        </button>
                        <button
                          type="button"
                          disabled={feedbackState.saving || !feedbackState.content.trim()}
                          onClick={() => void createFeedbackDraft(idea.idea_id, true)}
                          className="inline-flex h-10 items-center rounded-lg border border-foreground/20 px-3 text-sm font-medium disabled:opacity-60"
                        >
                          {feedbackState.saving ? "Saving..." : "Create correction draft"}
                        </button>
                      </div>
                    </div>
                  ) : null}
                  {feedbackState.kind === "draft" &&
                  feedbackState.ideaId === idea.idea_id ? (
                    <div className="mt-4 space-y-3">
                      <p className="text-xs text-foreground/60">
                        {feedbackState.draft.previousPublishedVersionId
                          ? "Correction draft for previously published feedback."
                          : "Unpublished initial draft."}
                      </p>
                      <label className="block text-sm font-medium">
                        Feedback
                        <textarea
                          value={feedbackState.content}
                          disabled={feedbackState.saving}
                          onChange={(event) =>
                            setFeedbackState({
                              ...feedbackState,
                              content: event.target.value,
                              message: null,
                            })
                          }
                          rows={6}
                          maxLength={20000}
                          className="mt-2 block w-full rounded-lg border border-foreground/20 bg-background p-3 font-normal"
                        />
                      </label>
                      {feedbackState.message ? (
                        <p
                          role={feedbackState.message.kind === "error" ? "alert" : "status"}
                          className={`text-sm ${
                            feedbackState.message.kind === "error"
                              ? "text-red-700"
                              : "text-foreground/70"
                          }`}
                        >
                          {feedbackState.message.text}
                        </p>
                      ) : null}
                      <button
                        type="button"
                        disabled={feedbackState.saving || !feedbackState.content.trim()}
                        onClick={() => void saveFeedbackDraft(idea.idea_id)}
                        className="inline-flex h-10 items-center rounded-lg bg-foreground px-3 text-sm font-medium text-background disabled:opacity-60"
                      >
                        {feedbackState.saving ? "Saving..." : "Save private draft"}
                      </button>
                    </div>
                  ) : null}
                </section>
              ) : null}
            </article>
          ))}
        </div>
      ) : null}
    </main>
  );
}
