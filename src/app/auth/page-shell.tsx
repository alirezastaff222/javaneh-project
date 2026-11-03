"use client";

import Link from "next/link";
import AuthForm from "./auth-form";

export default function AuthPageShell({
  mode,
  returnTo,
  initialError,
}: {
  mode: "sign-in" | "sign-up";
  returnTo: string;
  initialError?: string;
}) {
  const isSignUp = mode === "sign-up";
  return (
    <main className="auth-shell flex flex-1 items-center justify-center px-5 py-12 sm:px-6 sm:py-16" dir="rtl">
      <div className="auth-backdrop" aria-hidden="true">
        <span className="auth-orb auth-orb-green" />
        <span className="auth-orb auth-orb-red" />
      </div>
      <section className="auth-card w-full max-w-lg rounded-[1.7rem] p-6 sm:p-9">
        <Link href="/" className="mb-8 inline-flex items-center gap-2.5" aria-label="بازگشت به جوانه">
          <span className="home-mark" aria-hidden="true">J</span>
          <span className="text-sm font-semibold tracking-tight text-white">جوانه</span>
        </Link>
        <div className="mb-6 flex items-center justify-between gap-4">
          <div>
            <p className="auth-eyebrow text-xs font-medium">{isSignUp ? "شروع مسیر ایده" : "خوش آمدید"}</p>
            <h1 className="mt-2 text-2xl font-semibold tracking-tight text-white sm:text-3xl">
              {isSignUp ? "ساخت حساب کاربری" : "ورود به جوانه"}
            </h1>
          </div>
          {isSignUp && <span className="auth-step-badge">ثبت‌نام و ادامه</span>}
        </div>
        <p className="mb-7 text-sm leading-7 text-white/55">
          {isSignUp
            ? "مشخصات و اطلاعات ورود را یک‌جا وارد کنید تا ایدهٔ اولیه‌تان حفظ شود و ادامهٔ مسیر را در حساب خود تکمیل کنید."
            : "برای ادامهٔ مسیر ایده‌ها، وارد حساب خود شوید."}
        </p>
        <AuthForm mode={mode} returnTo={returnTo} initialError={initialError} />
        <p className="mt-6 text-center text-sm text-white/55">
          {isSignUp ? "حساب دارید؟ " : "حساب ندارید؟ "}
          <Link
            href={`/auth/${isSignUp ? "sign-in" : "sign-up"}?returnTo=${encodeURIComponent(returnTo)}`}
            className="font-medium text-emerald-200 underline underline-offset-4"
          >
            {isSignUp ? "ورود" : "ثبت‌نام"}
          </Link>
        </p>
      </section>
    </main>
  );
}
