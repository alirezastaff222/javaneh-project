"use client";

import { useEffect, useState } from "react";
import { participantResultSchema, type ParticipantResult } from "@/lib/ideas/competition-results";

export default function FinalResultSummary({ ideaId }: { ideaId: string }) {
  const [result, setResult] = useState<ParticipantResult | null>(null);

  useEffect(() => {
    void fetch(`/api/ideas/result?ideaId=${encodeURIComponent(ideaId)}`, { cache: "no-store" })
      .then(async (response) => {
        const parsed = participantResultSchema.safeParse(await response.json());
        if (response.ok && parsed.success) setResult(parsed.data);
      })
      .catch(() => undefined);
  }, [ideaId]);

  if (!result || result.state === "unpublished") return null;
  return (
    <section className="mb-6 rounded-xl border border-foreground/10 p-4">
      <h3 className="font-semibold">نتیجه نهایی منتشرشده</h3>
      <p className="mt-3 text-2xl font-semibold tabular-nums">
        {result.final_score.toFixed(2)} / 1000
      </p>
      <div className="mt-3 grid gap-2 text-sm sm:grid-cols-3">
        <span>توسعه: {result.development_score.toFixed(2)} / 700</span>
        <span>هیئت داوری: {result.jury_score.toFixed(2)} / 300</span>
        <span>رتبه: {result.rank}</span>
      </div>
    </section>
  );
}
