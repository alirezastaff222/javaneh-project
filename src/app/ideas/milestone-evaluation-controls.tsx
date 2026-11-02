"use client";

import { useCallback, useEffect, useState } from "react";
import {
  participantMilestoneEvaluationsSchema,
  type ParticipantMilestoneEvaluations,
} from "@/lib/ideas/milestone-evaluation";

function statusLabel(status: string): string {
  switch (status) {
    case "not_submitted": return "ثبت نشده";
    case "pending_validation": return "در انتظار بررسی انسانی";
    case "validated": return "تأیید شده؛ در انتظار ثبت امتیاز";
    case "needs_revision": return "نیازمند بازبینی";
    case "rejected": return "رد شده";
    default: return status;
  }
}

export default function MilestoneEvaluationControls({ ideaId }: { ideaId: string }) {
  const [data, setData] = useState<ParticipantMilestoneEvaluations | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState<string | null>(null);

  const load = useCallback(async () => {
    const response = await fetch(`/api/ideas/milestones?ideaId=${encodeURIComponent(ideaId)}`, {
      cache: "no-store",
    });
    const payload: unknown = await response.json();
    const parsed = participantMilestoneEvaluationsSchema.safeParse(payload);
    if (!response.ok || !parsed.success) throw new Error("Milestone evaluation load failed.");
    setData(parsed.data);
  }, [ideaId]);

  useEffect(() => {
    void (async () => {
      try {
        await load();
      } catch {
        setMessage("وضعیت بررسی معیارها بارگذاری نشد.");
      }
    })();
  }, [load]);

  async function submit(milestoneKey: string) {
    if (!data || data.state !== "available") return;
    setSubmitting(milestoneKey);
    setMessage(null);
    try {
      const response = await fetch("/api/ideas/milestones", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ideaId,
          configurationVersionId: data.configuration_version_id,
          milestoneKey,
          expectedRevision: data.idea_revision,
        }),
      });
      const payload = (await response.json()) as { outcome?: string };
      if (!response.ok) throw new Error("submit failed");
      setMessage(
        payload.outcome === "needs_revision"
          ? "این معیار نیازمند بازبینی است."
          : payload.outcome === "pending_validation"
            ? "معیار برای بررسی انسانی ثبت شد."
            : "معیار برای بررسی ثبت شد.",
      );
      window.dispatchEvent(new CustomEvent("participant-scorecard-refresh"));
      await load();
    } catch {
      setMessage("ثبت معیار برای بررسی انجام نشد.");
    } finally {
      setSubmitting(null);
    }
  }

  if (!data || data.state === "unavailable") return null;

  return (
    <section className="mb-6 rounded-xl border border-foreground/10 p-4">
      <h3 className="font-semibold">ثبت معیارها برای بررسی</h3>
      <p className="mt-1 text-sm text-foreground/60">
        نتیجه بررسی پیش از ثبت امتیاز رسمی نمایش داده می‌شود.
      </p>
      {message ? <p className="mt-3 text-sm" role="status">{message}</p> : null}
      <ul className="mt-4 space-y-2">
        {data.milestones.map((milestone) => (
          <li
            key={milestone.milestone_key}
            className="flex flex-wrap items-center justify-between gap-3 border-t border-foreground/10 py-3"
          >
            <div className="min-w-0 text-sm">
              مرحله {milestone.stage_number}: {milestone.name}
              <span className="ms-2 text-foreground/60">
                ({statusLabel(milestone.status)})
              </span>
              {milestone.feedback ? (
                <p className="mt-1 text-xs leading-5 text-foreground/65">
                  بازخورد: {milestone.feedback}
                </p>
              ) : null}
            </div>
            {(milestone.status === "not_submitted" ||
              milestone.status === "needs_revision" ||
              milestone.status === "rejected") && (
              <button
                type="button"
                disabled={submitting === milestone.milestone_key}
                onClick={() => void submit(milestone.milestone_key)}
                className="rounded-lg bg-foreground px-3 py-2 text-xs font-medium text-background disabled:opacity-60"
              >
                {submitting === milestone.milestone_key ? "در حال ثبت…" : "ثبت برای بررسی"}
              </button>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
