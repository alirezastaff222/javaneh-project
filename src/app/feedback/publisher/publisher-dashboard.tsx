"use client";

import Link from "next/link";
import { useState } from "react";

import {
  loadEligiblePublisherDrafts,
  publishEligibleFeedbackDraft,
  type PublisherDraft,
  type PublisherPageState,
  type PublishedFeedbackVersion,
} from "@/lib/ideas/feedback-publisher";

type PublishedDraft = {
  draft: PublisherDraft;
  version: PublishedFeedbackVersion;
};

function formatDate(value: string) {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? value : date.toLocaleString();
}

export function PublisherDashboard({
  initialState,
  actorId,
}: {
  initialState: PublisherPageState;
  actorId: string;
}) {
  const [pageState, setPageState] = useState(initialState);
  const [publishedDrafts, setPublishedDrafts] = useState<PublishedDraft[]>([]);
  const [selectedDraftId, setSelectedDraftId] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [publishingDraftId, setPublishingDraftId] = useState<string | null>(null);
  const [actionMessage, setActionMessage] = useState<{
    kind: "success" | "error";
    text: string;
  } | null>(null);

  const eligibleDrafts =
    pageState.kind === "loaded" ? pageState.drafts : [];
  const selectedDraft =
    eligibleDrafts.find((draft) => draft.draftId === selectedDraftId) ??
    eligibleDrafts[0] ??
    null;

  async function refreshQueue() {
    setRefreshing(true);
    setActionMessage(null);
    const nextState = await loadEligiblePublisherDrafts(actorId);
    setPageState(nextState);
    setSelectedDraftId(null);
    setRefreshing(false);
  }

  async function publishDraft(draft: PublisherDraft) {
    if (!draft.canPublish || publishingDraftId) return;
    setPublishingDraftId(draft.draftId);
    setActionMessage(null);
    const result = await publishEligibleFeedbackDraft(draft.draftId);
    if (!result.ok) {
      setActionMessage({ kind: "error", text: result.error });
      setPublishingDraftId(null);
      return;
    }

    setPageState((current) =>
      current.kind === "loaded"
        ? {
            kind: "loaded",
            drafts: current.drafts.filter(
              (candidate) => candidate.draftId !== draft.draftId,
            ),
          }
        : current,
    );
    setPublishedDrafts((current) => [
      { draft, version: result.value },
      ...current,
    ]);
    setSelectedDraftId(null);
    setActionMessage({
      kind: "success",
      text: `Feedback published as version ${result.value.versionNumber}.`,
    });
    setPublishingDraftId(null);
  }

  if (pageState.kind === "unauthenticated") {
    return (
      <main className="mx-auto max-w-5xl space-y-4 p-6">
        <h1 className="text-3xl font-semibold">Feedback publication</h1>
        <p role="alert">Sign in to access the publisher workspace.</p>
      </main>
    );
  }

  if (pageState.kind === "forbidden") {
    return (
      <main className="mx-auto max-w-5xl space-y-4 p-6">
        <h1 className="text-3xl font-semibold">Feedback publication</h1>
        <p role="alert">
          Publisher access is restricted to users with the feedback publisher
          permission.
        </p>
      </main>
    );
  }

  if (pageState.kind === "error") {
    return (
      <main className="mx-auto max-w-5xl space-y-4 p-6">
        <h1 className="text-3xl font-semibold">Feedback publication</h1>
        <p role="alert">The publisher workspace could not be loaded.</p>
        <button
          type="button"
          onClick={() => void refreshQueue()}
          disabled={refreshing}
          className="min-h-11 rounded-lg border border-foreground/20 px-4 font-medium hover:bg-foreground/5 disabled:opacity-60"
        >
          {refreshing ? "Loading..." : "Try again"}
        </button>
      </main>
    );
  }

  return (
    <main className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="text-sm uppercase tracking-[0.2em] text-foreground/60">
            Human evaluation
          </p>
          <h1 className="mt-2 text-3xl font-semibold">Feedback publication</h1>
          <p className="mt-2 max-w-2xl text-sm text-foreground/70">
            Review private evaluator drafts and publish them independently.
            Publishing feedback does not select winners or change evaluation
            results.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void refreshQueue()}
          disabled={refreshing}
          className="inline-flex min-h-11 items-center rounded-lg border border-foreground/20 px-4 font-medium transition-colors hover:bg-foreground/5 disabled:opacity-60"
        >
          {refreshing ? "Refreshing..." : "Refresh"}
        </button>
      </header>

      {actionMessage ? (
        <p
          role={actionMessage.kind === "error" ? "alert" : "status"}
          aria-live={actionMessage.kind === "error" ? "assertive" : "polite"}
          className="rounded-lg bg-foreground/5 p-4"
        >
          {actionMessage.text}
        </p>
      ) : null}
      {refreshing ? (
        <p role="status" className="text-sm text-foreground/65">
          Refreshing eligible feedback drafts...
        </p>
      ) : null}

      <section aria-labelledby="eligible-drafts-heading" className="space-y-4">
        <div>
          <h2 id="eligible-drafts-heading" className="text-xl font-semibold">
            Eligible drafts
          </h2>
          <p className="mt-1 text-sm text-foreground/65">
            Drafts remain private until a separate authorized publisher
            publishes them.
          </p>
        </div>

        {eligibleDrafts.length === 0 ? (
          <p role="status" className="rounded-xl border border-foreground/10 p-6 text-foreground/70">
            There are no feedback drafts eligible for publication.
          </p>
        ) : (
          <div className="grid gap-5 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
            <ul className="space-y-3">
              {eligibleDrafts.map((draft) => (
                <li key={draft.draftId}>
                  <button
                    type="button"
                    onClick={() => setSelectedDraftId(draft.draftId)}
                    aria-pressed={selectedDraft?.draftId === draft.draftId}
                    className="w-full rounded-xl border border-foreground/15 p-4 text-left transition-colors hover:bg-foreground/5 aria-pressed:border-foreground/50"
                  >
                    <span className="block font-medium">
                      {draft.previousPublishedVersionId
                        ? "Correction draft"
                        : "Initial feedback draft"}
                    </span>
                    <span className="mt-2 block text-sm text-foreground/65">
                      Idea {draft.ideaId}
                    </span>
                    <span className="mt-1 block text-xs text-foreground/55">
                      Evaluation cycle {draft.cycleId}
                    </span>
                  </button>
                </li>
              ))}
            </ul>

            {selectedDraft ? (
              <article className="space-y-5 rounded-xl border border-foreground/10 p-5">
                <div>
                  <p className="text-xs uppercase tracking-[0.16em] text-foreground/55">
                    {selectedDraft.previousPublishedVersionId
                      ? "Correction awaiting publication"
                      : "Unpublished feedback"}
                  </p>
                  <h3 className="mt-2 text-lg font-semibold">
                    Associated idea and completed evaluation
                  </h3>
                  <dl className="mt-3 grid gap-2 text-sm sm:grid-cols-2">
                    <div>
                      <dt className="text-foreground/55">Idea ID</dt>
                      <dd className="break-all">{selectedDraft.ideaId}</dd>
                    </div>
                    <div>
                      <dt className="text-foreground/55">Evaluation cycle</dt>
                      <dd className="break-all">{selectedDraft.cycleId}</dd>
                    </div>
                    <div>
                      <dt className="text-foreground/55">Evaluation status</dt>
                      <dd>Completed</dd>
                    </div>
                    <div>
                      <dt className="text-foreground/55">Draft updated</dt>
                      <dd>{formatDate(selectedDraft.updatedAt)}</dd>
                    </div>
                  </dl>
                </div>

                {selectedDraft.previousPublishedVersionId ? (
                  <p className="rounded-lg bg-foreground/5 p-3 text-sm">
                    Correction of published version{" "}
                    <span className="break-all font-mono">
                      {selectedDraft.previousPublishedVersionId}
                    </span>
                  </p>
                ) : null}

                <div>
                  <h4 className="font-medium">Private draft content</h4>
                  <p className="mt-2 whitespace-pre-wrap rounded-lg bg-foreground/5 p-4 leading-7">
                    {selectedDraft.content}
                  </p>
                </div>

                {selectedDraft.canPublish ? (
                  <button
                    type="button"
                    onClick={() => void publishDraft(selectedDraft)}
                    disabled={publishingDraftId !== null}
                    className="min-h-11 rounded-lg bg-foreground px-4 font-medium text-background transition-opacity hover:opacity-85 disabled:opacity-50"
                  >
                    {publishingDraftId === selectedDraft.draftId
                      ? "Publishing..."
                      : "Publish feedback"}
                  </button>
                ) : (
                  <p role="status" className="rounded-lg bg-amber-500/10 p-3 text-sm">
                    You authored this evaluation. A different authorized
                    publisher must publish it.
                  </p>
                )}
              </article>
            ) : null}
          </div>
        )}
      </section>

      <section className="rounded-xl border border-foreground/10 p-5">
        <h2 className="font-semibold">Correction workflow</h2>
        <p className="mt-2 text-sm leading-6 text-foreground/70">
          The assigned evaluator creates a private correction draft in the
          evaluator workspace through the existing correction API. It appears
          here for independent publication and is linked to its prior published
          version.
        </p>
        <Link
          href="/evaluator"
          className="mt-3 inline-flex min-h-11 items-center rounded-lg border border-foreground/20 px-4 font-medium hover:bg-foreground/5 focus-visible:outline-2 focus-visible:outline-offset-2"
        >
          Open evaluator workspace
        </Link>
      </section>

      {publishedDrafts.length > 0 ? (
        <section aria-labelledby="published-feedback-heading" className="space-y-4">
          <div>
            <h2 id="published-feedback-heading" className="text-xl font-semibold">
              Published in this session
            </h2>
            <p className="mt-1 text-sm text-foreground/65">
              Published versions are immutable. Corrections are authored by the
              assigned evaluator in the evaluator workspace and return here for
              independent publication.
            </p>
          </div>
          <ul className="space-y-3">
            {publishedDrafts.map(({ draft, version }) => (
              <li
                key={version.versionId}
                className="rounded-xl border border-foreground/10 p-5"
              >
                <p className="font-medium">
                  Published version {version.versionNumber}
                </p>
                <p className="mt-1 text-sm text-foreground/65">
                  Idea {draft.ideaId} · Evaluation cycle {draft.cycleId}
                </p>
                <p className="mt-1 text-sm text-foreground/65">
                  Published {formatDate(version.publishedAt)}
                </p>
                <p className="mt-3 break-all font-mono text-xs text-foreground/55">
                  Version ID: {version.versionId}
                </p>
                <p className="mt-4 whitespace-pre-wrap rounded-lg bg-foreground/5 p-4 leading-7">
                  {draft.content}
                </p>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <p className="text-sm text-foreground/60">
        Private evaluator identities are not shown here. Idea owners can see
        published feedback only through their participant workspace.
      </p>
    </main>
  );
}
