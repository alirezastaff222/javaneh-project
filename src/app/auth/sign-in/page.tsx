import { Suspense } from "react";
import AuthPageShell from "../page-shell";
import { sanitizeReturnTo } from "@/lib/supabase/auth";

async function SignInContent({
  searchParams,
}: {
  searchParams: Promise<{ returnTo?: string; error?: string }>;
}) {
  const params = await searchParams;
  const initialError =
    params.error === "missing_confirmation"
      ? "لینک تأیید ناقص است. لطفاً دوباره ثبت‌نام یا ورود را امتحان کنید."
      : params.error === "invalid_confirmation"
        ? "لینک تأیید معتبر نیست یا منقضی شده است. لطفاً دوباره ثبت‌نام کنید."
        : undefined;
  return (
    <AuthPageShell
      mode="sign-in"
      returnTo={sanitizeReturnTo(params.returnTo)}
      initialError={initialError}
    />
  );
}

export default function SignInPage(props: {
  searchParams: Promise<{ returnTo?: string; error?: string }>;
}) {
  return (
    <Suspense
      fallback={
        <main className="flex flex-1 items-center justify-center px-6 py-16">
          <p role="status">در حال آماده‌سازی…</p>
        </main>
      }
    >
      <SignInContent {...props} />
    </Suspense>
  );
}
