"use client";

import { useCallback, useEffect, useState } from "react";
import {
  juryAssignmentsSchema,
} from "@/lib/ideas/jury-scoring";

type Criterion = {
  criterion_key: string;
  display_name: string;
  description: string;
  maximum_points: number;
};

type Rubric = {
  assignment_id: string;
  idea_id: string;
  dossier_revision: number;
  rubric_version: string;
  criteria: Criterion[];
  dossier: Record<string, unknown> | null;
};

export default function JuryPanel() {
  const [assignments, setAssignments] = useState<ReturnType<typeof juryAssignmentsSchema.parse>>([]);
  const [rubric, setRubric] = useState<Rubric | null>(null);
  const [scores, setScores] = useState<Record<string, { level: number; justification: string }>>({});
  const [message, setMessage] = useState<string | null>(null);

  const load = useCallback(async () => {
    const response = await fetch("/api/evaluator/jury", { cache: "no-store" });
    const payload: unknown = await response.json();
    if (!response.ok) throw new Error("Jury assignments could not be loaded.");
    const parsed = juryAssignmentsSchema.safeParse(payload);
    if (!parsed.success) throw new Error("Invalid jury assignments.");
    setAssignments(parsed.data);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void load().catch((error: unknown) =>
        setMessage(error instanceof Error ? error.message : "Jury assignments could not be loaded."),
      );
    }, 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function openAssignment(assignmentId: string) {
    const response = await fetch(`/api/evaluator/jury?assignmentId=${assignmentId}`, { cache: "no-store" });
    const payload = (await response.json()) as Rubric & { error?: string };
    if (!response.ok) {
      setMessage(payload.error ?? "Jury rubric could not be loaded.");
      return;
    }
    setRubric(payload);
  }

  async function submit() {
    if (!rubric) return;
    const response = await fetch("/api/evaluator/jury", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        assignmentId: rubric.assignment_id,
        scores: rubric.criteria.map((criterion) => ({
          criterion_key: criterion.criterion_key,
          level: scores[criterion.criterion_key]?.level ?? 0,
          justification: scores[criterion.criterion_key]?.justification ?? "",
        })),
      }),
    });
    const payload = (await response.json()) as { error?: string };
    setMessage(response.ok ? "ارزیابی هیئت ثبت شد." : payload.error ?? "ثبت ارزیابی انجام نشد.");
    if (response.ok) await load();
  }

  async function recuse() {
    if (!rubric) return;
    const response = await fetch("/api/evaluator/jury", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ assignmentId: rubric.assignment_id, reason: "Conflict of interest declared by juror." }),
    });
    const payload = (await response.json()) as { error?: string };
    setMessage(response.ok ? "تعارض منافع ثبت و تخصیص لغو شد." : payload.error ?? "ثبت تعارض انجام نشد.");
    if (response.ok) {
      setRubric(null);
      await load();
    }
  }

  return (
    <section className="rounded-xl border border-foreground/10 p-4">
      <h2 className="text-xl font-semibold">ارزیابی مستقل هیئت</h2>
      <p className="mt-1 text-sm text-foreground/65">
        امتیاز توسعه و ارزیابی سایر اعضا در این فرایند نمایش داده نمی‌شود.
      </p>
      {message ? <p role="status" className="mt-3 text-sm">{message}</p> : null}
      <ul className="mt-4 space-y-2">
        {assignments.map((assignment) => (
          <li key={assignment.assignment_id} className="flex flex-wrap justify-between gap-3 border-t py-3 text-sm">
            <span>ایده {assignment.idea_id} · وضعیت: {assignment.status}</span>
            {assignment.status === "assigned" && !assignment.conflict_declared ? (
              <button type="button" onClick={() => void openAssignment(assignment.assignment_id)} className="rounded bg-foreground px-3 py-2 text-xs text-background">
                باز کردن پرونده و روبریک
              </button>
            ) : null}
          </li>
        ))}
      </ul>
      {rubric ? (
        <div className="mt-5 space-y-4 border-t pt-4">
          <h3 className="font-semibold">روبریک {rubric.rubric_version}</h3>
          <details>
            <summary className="cursor-pointer text-sm font-medium">پرونده ایده</summary>
            <pre className="mt-2 max-h-64 overflow-auto rounded bg-foreground/5 p-3 text-xs">
              {JSON.stringify(rubric.dossier ?? {}, null, 2)}
            </pre>
          </details>
          {rubric.criteria.map((criterion) => (
            <div key={criterion.criterion_key} className="rounded border p-3">
              <p className="font-medium">{criterion.display_name} · {criterion.maximum_points}</p>
              <p className="mt-1 text-sm text-foreground/65">{criterion.description}</p>
              <select
                value={scores[criterion.criterion_key]?.level ?? 0}
                onChange={(event) => setScores((current) => ({
                  ...current,
                  [criterion.criterion_key]: {
                    level: Number(event.target.value),
                    justification: current[criterion.criterion_key]?.justification ?? "",
                  },
                }))}
                className="mt-2 rounded border p-2"
              >
                {[0, 1, 2, 3, 4].map((level) => <option key={level} value={level}>سطح {level}</option>)}
              </select>
              <textarea
                value={scores[criterion.criterion_key]?.justification ?? ""}
                onChange={(event) => setScores((current) => ({
                  ...current,
                  [criterion.criterion_key]: {
                    level: current[criterion.criterion_key]?.level ?? 0,
                    justification: event.target.value,
                  },
                }))}
                placeholder="توجیه و ارجاع به شواهد پرونده"
                className="mt-2 min-h-20 w-full rounded border p-2 text-sm"
              />
            </div>
          ))}
          <button type="button" onClick={() => void submit()} className="rounded bg-foreground px-4 py-2 text-sm text-background">
            ثبت نهایی ارزیابی
          </button>
          <button type="button" onClick={() => void recuse()} className="ms-2 rounded border px-4 py-2 text-sm">
            اعلام تعارض منافع
          </button>
        </div>
      ) : null}
    </section>
  );
}
