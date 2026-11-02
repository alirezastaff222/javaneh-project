"use client";

import { useCallback, useEffect, useState } from "react";
import { adminResultsSchema } from "@/lib/ideas/competition-results";

export default function ResultsOperationsPanel({ competitionId }: { competitionId: string }) {
  const [results, setResults] = useState<ReturnType<typeof adminResultsSchema.parse> | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const load = useCallback(async () => {
    const response = await fetch(`/api/admin/results?competitionId=${encodeURIComponent(competitionId)}`, { cache: "no-store" });
    const payload: unknown = await response.json();
    if (!response.ok) throw new Error("نتایج بارگذاری نشد.");
    const parsed = adminResultsSchema.safeParse(payload);
    if (!parsed.success) throw new Error("پاسخ نتایج معتبر نیست.");
    setResults(parsed.data);
  }, [competitionId]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void load().catch((error: unknown) =>
        setMessage(error instanceof Error ? error.message : "نتایج بارگذاری نشد."),
      );
    }, 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function action(actionName: "prepare" | "approve" | "publish", resultVersionId?: string) {
    const response = await fetch("/api/admin/results", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: actionName,
        competitionId,
        resultVersionId,
        reason: "عملیات رسمی نتایج رقابت",
      }),
    });
    const payload = (await response.json()) as { error?: string };
    setMessage(response.ok ? "عملیات نتایج ثبت شد." : payload.error ?? "عملیات انجام نشد.");
    if (response.ok) await load();
  }

  const latest = results?.versions[0];
  return (
    <section className="mt-6 rounded-xl border border-foreground/10 p-5">
      <h2 className="text-xl font-semibold">نتایج نهایی رقابت</h2>
      {message ? <p role="status" className="mt-2 text-sm">{message}</p> : null}
      {!results ? <p className="mt-3 text-sm text-foreground/60">در حال بارگذاری…</p> : (
        <>
          <p className="mt-2 text-sm text-foreground/65">
            وضعیت رقابت: {results.status} · نتایج فقط پس از بسته‌شدن رقابت قابل انتشار است.
          </p>
          {latest ? <p className="mt-1 text-sm">آخرین نسخه: {latest.version_number} · {latest.status}</p> : null}
          <div className="mt-3 flex flex-wrap gap-2">
            {!latest ? <button type="button" onClick={() => void action("prepare")} className="rounded border px-3 py-2 text-sm">آماده‌سازی نتایج</button> : null}
            {latest?.status === "prepared" ? <button type="button" onClick={() => void action("approve", latest.result_version_id)} className="rounded border px-3 py-2 text-sm">تأیید نتایج</button> : null}
            {latest?.status === "approved" ? <button type="button" onClick={() => void action("publish", latest.result_version_id)} className="rounded bg-foreground px-3 py-2 text-sm text-background">انتشار نتایج</button> : null}
          </div>
          <ul className="mt-4 space-y-2 text-sm">
            {results.entries.map((entry) => (
              <li key={`${entry.result_version_id}:${entry.idea_id}`} className="flex flex-wrap justify-between gap-2 border-t pt-2">
                <span>{entry.idea_id}</span>
                <span>{entry.eligibility === "ranked" ? `رتبه ${entry.rank} · ${entry.final_score}/1000` : "در انتظار تکمیل داوری"}</span>
              </li>
            ))}
          </ul>
        </>
      )}
    </section>
  );
}
