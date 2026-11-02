"use client";

import { useCallback, useEffect, useState } from "react";

type QueueItem = {
  request_id: string;
  idea_id: string;
  milestone_key: string;
  stage_number: number;
  validation_mode: string;
  objective_passed: boolean | null;
  evidence: Record<string, unknown>;
};

export default function MilestoneValidationQueue() {
  const [items, setItems] = useState<QueueItem[]>([]);
  const [reason, setReason] = useState<Record<string, string>>({});
  const [evaluationLevel, setEvaluationLevel] = useState<Record<string, number>>({});
  const [message, setMessage] = useState<string | null>(null);

  const load = useCallback(async () => {
    const response = await fetch("/api/evaluator/milestones", { cache: "no-store" });
    const payload = (await response.json()) as { items?: unknown[] };
    if (!response.ok || !Array.isArray(payload.items)) throw new Error("load failed");
    setItems(payload.items as QueueItem[]);
  }, []);

  useEffect(() => {
    void (async () => {
      try {
        await load();
      } catch {
        setMessage("صف بررسی معیارها بارگذاری نشد.");
      }
    })();
  }, [load]);

  async function decide(item: QueueItem, outcome: "validated" | "needs_revision" | "rejected") {
    const text = reason[item.request_id]?.trim() ?? "";
    if (!text) {
      setMessage("برای تصمیم بررسی، توضیح لازم است.");
      return;
    }
    const response = await fetch("/api/evaluator/milestones", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        requestId: item.request_id,
        outcome,
        evaluationLevel: outcome === "validated" ? evaluationLevel[item.request_id] ?? 1 : 0,
        reason: text,
      }),
    });
    if (!response.ok) {
      setMessage("تصمیم بررسی ثبت نشد.");
      return;
    }
    setMessage("تصمیم بررسی ثبت شد.");
    await load();
  }

  return (
    <section className="rounded-xl border border-foreground/10 p-4">
      <h2 className="text-xl font-semibold">معیارهای در انتظار بررسی</h2>
      {message ? <p className="mt-2 text-sm" role="status">{message}</p> : null}
      {items.length === 0 ? (
        <p className="mt-3 text-sm text-foreground/60">موردی در صف بررسی نیست.</p>
      ) : (
        <ul className="mt-4 space-y-4">
          {items.map((item) => (
            <li key={item.request_id} className="border-t border-foreground/10 pt-4">
              <p className="text-sm font-medium">
                مرحله {item.stage_number} · {item.milestone_key} · {item.validation_mode}
              </p>
              <pre className="mt-2 max-h-32 overflow-auto rounded bg-foreground/5 p-2 text-xs">
                {JSON.stringify(item.evidence, null, 2)}
              </pre>
              <textarea
                value={reason[item.request_id] ?? ""}
                onChange={(event) =>
                  setReason((current) => ({
                    ...current,
                    [item.request_id]: event.target.value,
                  }))
                }
                placeholder="Reason and actionable feedback"
                className="mt-2 min-h-20 w-full rounded border border-foreground/20 p-2 text-sm"
              />
              <label className="mt-2 flex items-center gap-2 text-sm">
                سطح ارزیابی
                <select
                  value={evaluationLevel[item.request_id] ?? 1}
                  onChange={(event) =>
                    setEvaluationLevel((current) => ({
                      ...current,
                      [item.request_id]: Number(event.target.value),
                    }))
                  }
                  className="rounded border border-foreground/20 p-1"
                >
                  {[1, 2, 3, 4].map((level) => (
                    <option key={level} value={level}>{level}</option>
                  ))}
                </select>
              </label>
              <div className="mt-2 flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={() => void decide(item, "validated")}
                  className="rounded bg-foreground px-3 py-2 text-xs text-background"
                >
                  تأیید
                </button>
                <button
                  type="button"
                  onClick={() => void decide(item, "needs_revision")}
                  className="rounded border border-foreground/20 px-3 py-2 text-xs"
                >
                  نیازمند بازبینی
                </button>
                <button
                  type="button"
                  onClick={() => void decide(item, "rejected")}
                  className="rounded border border-red-500/40 px-3 py-2 text-xs text-red-700"
                >
                  رد
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
