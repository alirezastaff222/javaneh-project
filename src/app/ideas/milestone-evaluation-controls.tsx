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

export default function MilestoneEvaluationControls({
  ideaId,
  isGroupIdea = false,
}: {
  ideaId: string;
  isGroupIdea?: boolean;
}) {
  const [data, setData] = useState<ParticipantMilestoneEvaluations | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const [loadError, setLoadError] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadAttempt, setLoadAttempt] = useState(0);
  const [submitting, setSubmitting] = useState<string | null>(null);

  const load = useCallback(async (): Promise<void> => {
    setLoading(true);
    setLoadError(false);
    try {
      const response = await fetch(`/api/ideas/milestones?ideaId=${encodeURIComponent(ideaId)}`, {
        cache: "no-store",
      });
      const payload: unknown = await response.json();
      const parsed = participantMilestoneEvaluationsSchema.safeParse(payload);
      if (!response.ok || !parsed.success) {
        throw new Error("Milestone evaluation load failed.");
      }
      setData(parsed.data);
    } catch {
      setData(null);
      setLoadError(true);
    } finally {
      setLoading(false);
    }
  }, [ideaId]);

  useEffect(() => {
    const timer = window.setTimeout(() => void load(), 0);
    return () => window.clearTimeout(timer);
  }, [load, loadAttempt]);

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
      if (payload.outcome === "needs_revision") {
        setMessage("این معیار نیازمند بازبینی است.");
      } else if (payload.outcome === "pending_validation") {
        setMessage("معیار برای بررسی انسانی ثبت شد.");
      } else if (payload.outcome === "validated") {
        setMessage("بررسی سروری معیار تأیید شد؛ امتیاز فقط پس از ثبت در دفتر رسمی نمایش داده می‌شود.");
      } else if (payload.outcome === "replayed") {
        setMessage("درخواست قبلی بازیابی شد؛ وضعیت فعلی دوباره بارگذاری می‌شود.");
      } else {
        throw new Error("Unexpected milestone submission outcome.");
      }
      window.dispatchEvent(new CustomEvent("participant-scorecard-refresh"));
      await load();
    } catch {
      setMessage("ثبت معیار برای بررسی انجام نشد.");
    } finally {
      setSubmitting(null);
    }
  }

  if (loading) {
    return (
      <section className="mb-6 rounded-xl border border-foreground/10 p-4">
        <h3 className="font-semibold">
          {isGroupIdea ? "پیشرفت معیارهای گروه" : "ثبت معیارها برای بررسی"}
        </h3>
        <p role="status" className="mt-3 text-sm text-foreground/60">
          در حال بارگذاری وضعیت بررسی معیارها…
        </p>
      </section>
    );
  }

  if (loadError || !data) {
    return (
      <section className="mb-6 rounded-xl border border-foreground/10 p-4">
        <h3 className="font-semibold">
          {isGroupIdea ? "پیشرفت معیارهای گروه" : "ثبت معیارها برای بررسی"}
        </h3>
        <div className="mt-3 flex flex-wrap items-center gap-3 text-sm">
          <p role="alert" className="text-red-700 dark:text-red-300">
            وضعیت بررسی معیارها بارگذاری نشد.
          </p>
          <button
            type="button"
            onClick={() => setLoadAttempt((value) => value + 1)}
            className="min-h-9 rounded-lg border border-foreground/20 px-3 font-medium"
          >
            تلاش دوباره
          </button>
        </div>
      </section>
    );
  }

  if (data.state === "unavailable") {
    return (
      <section className="mb-6 rounded-xl border border-foreground/10 p-4">
        <h3 className="font-semibold">
          {isGroupIdea ? "پیشرفت معیارهای گروه" : "ثبت معیارها برای بررسی"}
        </h3>
        <p role="status" className="mt-3 text-sm text-foreground/60">
          ثبت معیار برای بررسی در حال حاضر در دسترس نیست.
        </p>
      </section>
    );
  }

  return (
    <section className="mb-6 rounded-xl border border-foreground/10 p-4">
      <h3 className="font-semibold">
        {isGroupIdea ? "پیشرفت معیارهای گروه" : "ثبت معیارها برای بررسی"}
      </h3>
      <p className="mt-1 text-sm text-foreground/60">
        {isGroupIdea
          ? "اعضای پذیرفته‌شده می‌توانند معیارها را برای بررسی ثبت کنند؛ امتیازهای تأییدشده به گروه تعلق می‌گیرد."
          : "نتیجه بررسی پیش از ثبت امتیاز رسمی نمایش داده می‌شود."}
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
                {submitting === milestone.milestone_key
                  ? "در حال ثبت…"
                  : "ثبت برای بررسی"}
              </button>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
