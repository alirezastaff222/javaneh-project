"use client";

import { useEffect, useState } from "react";
import {
  parseParticipantScorecard,
  type ParticipantMilestoneStatus,
  type ParticipantScorecard,
} from "@/lib/ideas/participant-scorecard";

type ScorecardState =
  | { kind: "loading" }
  | { kind: "error" }
  | { kind: "loaded"; scorecard: ParticipantScorecard };

function unavailableMessage(reason: string): string {
  switch (reason) {
    case "not_assigned":
      return "برای این ایده هنوز رقابت و نسخه امتیازدهی به‌طور رسمی تعیین نشده است.";
    case "competition_inactive":
      return "رقابت مرتبط در حال حاضر فعال نیست؛ امتیازدهی در دسترس نیست.";
    case "inconsistent_history":
      return "سابقه امتیازدهی این ایده نیازمند بررسی است؛ امتیازها نمایش داده نمی‌شوند.";
    case "not_found":
      return "این ایده در دسترس نیست.";
    default:
      return "نسخه امتیازدهی معتبر و فعال در دسترس نیست.";
  }
}

export function milestoneStatusLabel(status: ParticipantMilestoneStatus): string {
  switch (status) {
    case "not_submitted":
      return "هنوز برای بررسی ثبت نشده است؛ امتیازی ثبت نشده";
    case "pending_validation":
      return "در انتظار بررسی؛ امتیاز احتمالی هنوز ثبت نشده است";
    case "validated":
      return "بررسی تأیید شده؛ امتیازی در دفتر ثبت نشده است";
    case "needs_revision":
      return "نیازمند بازبینی";
    case "rejected":
      return "درخواست تأیید نشده است";
    case "awarded":
      return "امتیاز ثبت‌شده";
    case "corrected":
      return "امتیاز با اصلاح جبرانی تغییر کرده است";
  }
}

export function remainingStagePoints(points: number, maximumPoints: number): number {
  return Math.max(0, maximumPoints - points);
}

export function StageScoreSummary({
  stageNumber,
  points,
  maximumPoints,
}: {
  stageNumber: number;
  points: number;
  maximumPoints: number;
}) {
  return (
    <p className="flex flex-wrap justify-between gap-3 border-t border-foreground/10 py-2 text-sm">
      <span>مرحله {stageNumber}</span>
      <span className="flex flex-wrap gap-x-3 tabular-nums">
        <span>کسب‌شده: {points}</span>
        <span>حداکثر: {maximumPoints}</span>
        <span>باقی‌مانده: {remainingStagePoints(points, maximumPoints)}</span>
      </span>
    </p>
  );
}

export function MilestoneScoreSummary({
  points,
  maximumPoints,
  status,
}: {
  points: number;
  maximumPoints: number;
  status: ParticipantMilestoneStatus;
}) {
  return (
    <div className="text-sm sm:text-end">
      <p className="font-medium tabular-nums">
        {points} از {maximumPoints} امتیاز
      </p>
      <p className="mt-1 text-xs text-foreground/60">
        {milestoneStatusLabel(status)}
      </p>
      {status === "pending_validation" && (
        <p className="mt-1 text-xs text-amber-800 dark:text-amber-200">
          این درخواست در امتیازهای کسب‌شده محاسبه نشده است.
        </p>
      )}
      {points === 0 &&
        status !== "pending_validation" &&
        status !== "not_submitted" && (
          <p className="mt-1 text-xs text-foreground/60">
            امتیازی برای این معیار در دفتر ثبت نشده است.
          </p>
        )}
    </div>
  );
}

export default function ParticipantScorecard({
  ideaId,
}: {
  ideaId: string;
}) {
  const [state, setState] = useState<ScorecardState>({ kind: "loading" });

  useEffect(() => {
    let active = true;

    void (async () => {
      try {
        const parameters = new URLSearchParams({ ideaId });
        const response = await fetch(
          `/api/ideas/scorecard?${parameters.toString()}`,
          { method: "GET", cache: "no-store" },
        );
        if (!response.ok) throw new Error("Scorecard request failed.");
        const payload: unknown = await response.json();
        const scorecard =
          typeof payload === "object" &&
          payload !== null &&
          !Array.isArray(payload) &&
          "scorecard" in payload
            ? parseParticipantScorecard(payload.scorecard)
            : null;
        if (!scorecard) throw new Error("Invalid scorecard response.");
        if (active) setState({ kind: "loaded", scorecard });
      } catch {
        if (active) setState({ kind: "error" });
      }
    })();

    return () => {
      active = false;
    };
  }, [ideaId]);

  return (
    <section
      aria-labelledby="participant-scorecard-title"
      className="mb-6 rounded-xl border border-foreground/10 bg-foreground/[0.02] p-4 sm:p-5"
    >
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h3 id="participant-scorecard-title" className="font-semibold">
            کارنامه توسعه ایده
          </h3>
          <p className="mt-1 text-sm text-foreground/60">
            فقط امتیازهای ثبت‌شده در دفتر رسمی محاسبه می‌شوند.
          </p>
        </div>
        {state.kind === "loaded" && state.scorecard.state === "available" && (
          <p className="text-sm font-medium">
            نسخه امتیازدهی {state.scorecard.version_number} · معیارها{" "}
            {state.scorecard.catalog_version}
          </p>
        )}
      </div>

      {state.kind === "loading" ? (
        <p role="status" className="mt-4 text-sm text-foreground/60">
          در حال بارگذاری کارنامه…
        </p>
      ) : state.kind === "error" ? (
        <p role="alert" className="mt-4 text-sm text-red-800 dark:text-red-200">
          کارنامه بارگذاری نشد. صفحه را تازه‌سازی کنید.
        </p>
      ) : state.scorecard.state === "unavailable" ? (
        <p role="status" className="mt-4 text-sm leading-6 text-foreground/70">
          {unavailableMessage(state.scorecard.reason)}
        </p>
      ) : (
        <>
          <p className="mt-4 text-2xl font-semibold tabular-nums">
            {state.scorecard.total_points} / {state.scorecard.maximum_points}
            <span className="ms-2 text-sm font-normal text-foreground/60">
              امتیاز توسعه
            </span>
          </p>

          <div className="mt-4 grid gap-2 sm:grid-cols-3">
            {state.scorecard.stages.map((stage) => (
              <StageScoreSummary
                key={stage.stage_number}
                stageNumber={stage.stage_number}
                points={stage.points}
                maximumPoints={stage.maximum_points}
              />
            ))}
          </div>

          <div className="mt-5 space-y-4">
            {state.scorecard.stages.map((stage) => (
              <section key={stage.stage_number}>
                <h4 className="border-b border-foreground/10 pb-2 text-sm font-semibold">
                  معیارهای مرحله {stage.stage_number}
                </h4>
                <ul className="divide-y divide-foreground/10">
                  {state.scorecard.state === "available" &&
                    state.scorecard.milestones
                      .filter(
                        (milestone) =>
                          milestone.stage_number === stage.stage_number,
                      )
                      .map((milestone) => (
                        <li
                          key={`${milestone.stage_number}:${milestone.name}`}
                          className="grid gap-1 py-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:gap-4"
                        >
                          <div>
                            <p className="text-sm font-medium">{milestone.name}</p>
                            <p className="mt-1 text-sm leading-6 text-foreground/65">
                              {milestone.criteria}
                            </p>
                          </div>
                          <MilestoneScoreSummary
                            points={milestone.awarded_points}
                            maximumPoints={milestone.maximum_points}
                            status={milestone.status}
                          />
                        </li>
                      ))}
                </ul>
              </section>
            ))}
          </div>

          {state.scorecard.history.length > 0 && (
            <details className="mt-5 border-t border-foreground/10 pt-3">
              <summary className="cursor-pointer text-sm font-medium">
                تاریخچه امتیازهای ثبت‌شده
              </summary>
              <ul className="mt-2 divide-y divide-foreground/10">
                {state.scorecard.history.map((entry, index) => (
                  <li
                    key={`${entry.recorded_at}:${entry.stage_number}:${index}`}
                    className="flex flex-wrap justify-between gap-2 py-2 text-sm"
                  >
                    <span>
                      مرحله {entry.stage_number} · {entry.milestone} ·{" "}
                      {entry.kind === "award" ? "امتیاز" : "اصلاح جبرانی"}
                    </span>
                    <span className="tabular-nums">
                      {entry.points > 0 ? "+" : ""}
                      {entry.points}
                    </span>
                  </li>
                ))}
              </ul>
            </details>
          )}
        </>
      )}
    </section>
  );
}