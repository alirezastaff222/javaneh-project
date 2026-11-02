"use client";

import { useCallback, useEffect, useState } from "react";
import {
  scoringOperationsSummarySchema,
  type ScoringOperationsSummary,
} from "@/lib/ideas/scoring-operations";
import JuryOperationsPanel from "./jury-operations-panel";
import ResultsOperationsPanel from "./results-operations-panel";

export default function ScoringOperationsPanel() {
  const [data, setData] = useState<ScoringOperationsSummary | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const response = await fetch("/api/admin/scoring", { cache: "no-store" });
      const payload: unknown = await response.json();
      const parsed = scoringOperationsSummarySchema.safeParse(payload);
      if (!response.ok || !parsed.success) throw new Error("load failed");
      setData(parsed.data);
    } catch {
      setMessage("Scoring operations could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void (async () => {
      await load();
    })();
  }, [load]);

  async function operate(versionId: string, action: "approve" | "activate") {
    const reason = window.prompt(
      action === "approve" ? "Approval reason" : "Activation reason",
    )?.trim();
    if (!reason) return;
    setBusy(versionId);
    setMessage(null);
    try {
      const response = await fetch("/api/admin/scoring", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ versionId, action, reason }),
      });
      const payload = (await response.json()) as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Operation failed");
      setMessage("Scoring configuration updated.");
      await load();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "Operation failed.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <main className="mx-auto max-w-6xl space-y-6 p-6">
      <header>
        <p className="text-sm uppercase tracking-[0.2em] text-foreground/60">Operations</p>
        <h1 className="mt-2 text-3xl font-semibold">Scoring configurations</h1>
        <p className="mt-2 text-sm text-foreground/65">
          Review approved configuration versions and use the existing protected lifecycle actions.
        </p>
      </header>
      {message ? <p role="status" className="rounded border border-foreground/10 p-3 text-sm">{message}</p> : null}
      {loading ? <p role="status">Loading scoring operations…</p> : null}
      {!loading && !data ? (
        <button type="button" onClick={() => void load()} className="rounded border px-4 py-2">
          Retry
        </button>
      ) : null}
      {data?.configurations.map((configuration) => (
        <article key={configuration.version_id} className="rounded-xl border border-foreground/10 p-5">
          <div className="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 className="text-xl font-semibold">
                {configuration.configuration_key} · v{configuration.version_number}
              </h2>
              <p className="mt-1 text-sm text-foreground/65">
                وضعیت: {configuration.status} · آماده‌سازی: {configuration.ready ? "کامل" : "ناقص"}
              </p>
              {configuration.competition ? (
                <p className="mt-1 text-sm text-foreground/65">
                  رقابت: {configuration.competition.name} ({configuration.competition.status})
                </p>
              ) : null}
            </div>
            <div className="flex gap-2">
              {configuration.status === "draft" ? (
                <button type="button" disabled={busy === configuration.version_id} onClick={() => void operate(configuration.version_id, "approve")} className="rounded bg-foreground px-3 py-2 text-xs text-background disabled:opacity-60">
                  تأیید نسخه
                </button>
              ) : null}
              {configuration.status === "approved" && configuration.ready ? (
                <button type="button" disabled={busy === configuration.version_id} onClick={() => void operate(configuration.version_id, "activate")} className="rounded border px-3 py-2 text-xs disabled:opacity-60">
                  فعال‌سازی نسخه
                </button>
              ) : null}
            </div>
          </div>
          <div className="mt-4 grid gap-3 sm:grid-cols-4 text-sm">
            <span>توسعه: {configuration.development_max_points}</span>
            <span>کل: {configuration.overall_max_points}</span>
            <span>در انتظار بررسی: {configuration.pending_evaluations}</span>
            <span>امتیاز اعطا‌شده: {configuration.awarded_development_points}</span>
          </div>
          <ul className="mt-4 grid gap-2 sm:grid-cols-2">
            {configuration.milestones.map((milestone) => (
              <li key={milestone.milestone_key} className="rounded border border-foreground/10 p-3 text-sm">
                <span className="font-medium">{milestone.milestone_key}</span>
                <span className="ms-2 text-foreground/60">مرحله {milestone.stage_number}</span>
                <p className="mt-1 text-foreground/65">{milestone.definition ?? "بدون توضیح"}</p>
                <p className="mt-1 text-xs text-foreground/60">
                  {milestone.validation_mode ?? "نامشخص"} · {milestone.point_value ?? 0} امتیاز
                </p>
              </li>
            ))}
          </ul>
        </article>
      ))}
      {data?.configurations.map((configuration) => configuration.competition ? (
        <ResultsOperationsPanel
          key={`results:${configuration.competition.id}`}
          competitionId={configuration.competition.id}
        />
      ) : null)}
      <JuryOperationsPanel />
    </main>
  );
}
