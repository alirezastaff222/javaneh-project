import { Suspense } from "react";
import { redirect } from "next/navigation";
import IntakeFlow from "./intake-flow";
import { buildAuthPath } from "@/lib/supabase/auth";
import { createClient } from "@/lib/supabase/server";

export default function IdeaIntakePage(props: {
  searchParams: Promise<{ seed?: string }>;
}) {
  return (
    <Suspense
      fallback={
        <main className="intake-shell flex min-h-screen items-center justify-center px-6" dir="rtl">
          <p role="status" className="text-sm text-white/60">در حال آماده‌سازی فرم ایده…</p>
        </main>
      }
    >
      <IntakeContent searchParams={props.searchParams} />
    </Suspense>
  );
}

async function IntakeContent({
  searchParams,
}: {
  searchParams: Promise<{ seed?: string }>;
}) {
  const params = await searchParams;
  const initialIdea = typeof params.seed === "string" ? params.seed.trim().slice(0, 4000) : "";
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    const returnTo = initialIdea
      ? `/ideas/intake?seed=${encodeURIComponent(initialIdea)}`
      : "/ideas/intake";
    redirect(buildAuthPath("/auth/sign-in", returnTo));
  }

  return <IntakeFlow initialIdea={initialIdea} participantId={user.id} />;
}
