"use client";

import { useEffect, useState } from "react";
import {
  participantJuryScoreSchema,
  type ParticipantJuryScore,
} from "@/lib/ideas/jury-scoring";

const criterionNames: Record<string, string> = {
  J1: "اهمیت اجتماعی و اثرگذاری",
  J2: "عمق شناخت مسئله",
  J3: "مشارکت اجتماعی و ظرفیت‌سازی",
  J4: "نوآوری و تناسب راه‌حل",
  J5: "کیفیت برنامه اجرا",
  J6: "امکان‌پذیری و پایداری",
  J7: "مقیاس‌پذیری و یادگیری سازمانی",
};

export default function JuryScoreSummary({ ideaId }: { ideaId: string }) {
  const [score, setScore] = useState<ParticipantJuryScore | null>(null);

  useEffect(() => {
    void fetch(`/api/ideas/jury-score?ideaId=${encodeURIComponent(ideaId)}`, {
      cache: "no-store",
    })
      .then(async (response) => {
        const parsed = participantJuryScoreSchema.safeParse(await response.json());
        if (response.ok && parsed.success) setScore(parsed.data);
      })
      .catch(() => undefined);
  }, [ideaId]);

  if (!score || score.state === "unpublished") return null;
  return (
    <section className="mb-6 rounded-xl border border-foreground/10 p-4">
      <h3 className="font-semibold">نتیجه داوری نهایی</h3>
      <p className="mt-1 text-sm text-foreground/60">
        این نتیجه پس از تکمیل سه ارزیابی مستقل و انتشار رسمی قابل مشاهده است.
      </p>
      <p className="mt-4 text-2xl font-semibold tabular-nums">
        {score.final_score.toFixed(2)} / {score.maximum_points}
        <span className="ms-2 text-sm font-normal text-foreground/60">امتیاز هیئت داوری</span>
      </p>
      <ul className="mt-4 grid gap-2 sm:grid-cols-2">
        {Object.entries(score.criterion_averages).map(([key, value]) => (
          <li key={key} className="flex justify-between rounded border border-foreground/10 p-2 text-sm">
            <span>{criterionNames[key] ?? key}</span>
            <span className="tabular-nums">{value.toFixed(2)}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
