import { Suspense } from "react";
import AuthPageShell from "../page-shell";
import { sanitizeReturnTo } from "@/lib/supabase/auth";

async function SignUpContent({
  searchParams,
}: {
  searchParams: Promise<{ returnTo?: string }>;
}) {
  const params = await searchParams;
  return <AuthPageShell mode="sign-up" returnTo={sanitizeReturnTo(params.returnTo)} />;
}

export default function SignUpPage(props: {
  searchParams: Promise<{ returnTo?: string }>;
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
