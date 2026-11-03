import { Suspense } from "react";
import AuthPageShell from "../page-shell";
import { sanitizeReturnTo } from "@/lib/supabase/auth";

async function SignUpContent({
  searchParams,
}: {
  searchParams: Promise<{ returnTo?: string; seed?: string }>;
}) {
  const params = await searchParams;
  const seed = typeof params.seed === "string" ? params.seed.trim().slice(0, 4000) : "";
  const returnTo = seed
    ? `/ideas/intake?seed=${encodeURIComponent(seed)}`
    : sanitizeReturnTo(params.returnTo ?? "/ideas/intake");
  return <AuthPageShell mode="sign-up" returnTo={returnTo} />;
}

export default function SignUpPage(props: {
  searchParams: Promise<{ returnTo?: string; seed?: string }>;
}) {
  return (
    <Suspense
      fallback={
        <main className="flex flex-1 items-center justify-center px-6 py-16">
          <p role="status">در حال آماده‌سازی…</p>
        </main>
      }
    >
      <SignUpContent {...props} />
    </Suspense>
  );
}
