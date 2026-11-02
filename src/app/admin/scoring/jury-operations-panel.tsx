"use client";

import { useCallback, useEffect, useState } from "react";

type JuryQueueItem = {
  idea_id: string;
  assignments: Array<{ assignment_id: string; juror_id: string; status: string; conflict_declared: boolean }>;
  publication: { publication_id: string; status: string; final_score: number } | null;
};

export default function JuryOperationsPanel() {
  const [items, setItems] = useState<JuryQueueItem[]>([]);
  const [jurorIds, setJurorIds] = useState<Record<string, string>>({});
  const [message, setMessage] = useState<string | null>(null);
  const load = useCallback(async () => {
    const response = await fetch("/api/admin/jury", { cache: "no-store" });
    const payload = (await response.json()) as { items?: JuryQueueItem[]; error?: string };
    if (!response.ok) throw new Error(payload.error ?? "Jury operations could not be loaded.");
    setItems(payload.items ?? []);
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      void load().catch((error: unknown) =>
        setMessage(error instanceof Error ? error.message : "Jury operations could not be loaded."),
      );
    }, 0);
    return () => window.clearTimeout(timer);
  }, [load]);

  async function action(body: Record<string, string>) {
    const response = await fetch("/api/admin/jury", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    });
    const payload = (await response.json()) as { error?: string };
    setMessage(response.ok ? "عملیات داوری ثبت شد." : payload.error ?? "عملیات انجام نشد.");
    if (response.ok) await load();
  }

  return (
    <section className="rounded-xl border border-foreground/10 p-5">
      <h2 className="text-xl font-semibold">مدیریت داوری هیئت</h2>
      <p className="mt-1 text-sm text-foreground/65">
        برای هر ایده دقیقاً سه عضو مستقل تخصیص دهید و پس از تکمیل، انتشار را تأیید کنید.
      </p>
      {message ? <p role="status" className="mt-3 text-sm">{message}</p> : null}
      <ul className="mt-4 space-y-3">
        {items.map((item) => {
          const submitted = item.assignments.filter((assignment) => assignment.status === "submitted").length;
          const publication = item.publication;
          return (
            <li key={item.idea_id} className="rounded border border-foreground/10 p-3 text-sm">
              <p className="font-medium">ایده: {item.idea_id}</p>
              <p className="mt-1 text-foreground/65">
                تخصیص‌ها: {item.assignments.length}/3 · ارزیابی‌های نهایی: {submitted}/3
              </p>
              {item.assignments.length < 3 ? (
                <div className="mt-2 flex flex-wrap gap-2">
                  <input
                    value={jurorIds[item.idea_id] ?? ""}
                    onChange={(event) => setJurorIds((current) => ({ ...current, [item.idea_id]: event.target.value }))}
                    placeholder="شناسه کاربر عضو هیئت"
                    className="min-w-64 rounded border p-2 text-xs"
                  />
                  <button
                    type="button"
                    onClick={() => void action({ action: "assign", ideaId: item.idea_id, jurorId: jurorIds[item.idea_id] ?? "" })}
                    className="rounded border px-3 py-2 text-xs"
                  >
                    تخصیص عضو
                  </button>
                </div>
              ) : null}
              {publication?.status === "approved" ? (
                <button type="button" onClick={() => void action({ action: "publish", publicationId: publication.publication_id })} className="mt-2 rounded bg-foreground px-3 py-2 text-xs text-background">
                  انتشار نتیجه
                </button>
              ) : null}
            </li>
          );
        })}
      </ul>
    </section>
  );
}
