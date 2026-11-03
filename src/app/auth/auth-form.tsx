"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getSupabaseEnvironment } from "@/lib/supabase/env";
import { buildConfirmationRedirect, sanitizeReturnTo } from "@/lib/supabase/auth";

type AuthMode = "sign-in" | "sign-up";

function normalizeDigits(value: string): string {
  return value
    .replace(/[۰-۹]/g, (digit) => String("۰۱۲۳۴۵۶۷۸۹".indexOf(digit)))
    .replace(/[٠-٩]/g, (digit) => String("٠١٢٣٤٥٦٧٨٩".indexOf(digit)));
}

export default function AuthForm({
  mode,
  returnTo,
  initialError,
}: {
  mode: AuthMode;
  returnTo: string;
  initialError?: string;
}) {
  const router = useRouter();
  const isSignUp = mode === "sign-up";
  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [nationalId, setNationalId] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent<HTMLFormElement>): Promise<void> {
    event.preventDefault();
    setBusy(true);
    setError(null);
    setMessage(null);

    const normalizedNationalId = normalizeDigits(nationalId);
    if (isSignUp && !/^\d{10}$/.test(normalizedNationalId)) {
      setBusy(false);
      setError("کد ملی باید دقیقاً ۱۰ رقم باشد.");
      return;
    }

    let result;
    try {
      getSupabaseEnvironment();
      const supabase = createClient();
      result = isSignUp
        ? await supabase.auth.signUp({
            email,
            password,
            options: {
              data: {
                first_name: firstName.trim(),
                last_name: lastName.trim(),
              },
              emailRedirectTo: buildConfirmationRedirect(
                window.location.origin,
                returnTo,
                process.env.NEXT_PUBLIC_SITE_URL,
              ),
            },
          })
        : await supabase.auth.signInWithPassword({ email, password });
    } catch (caughtError) {
      setBusy(false);
      if (caughtError instanceof Error && caughtError.message.includes("NEXT_PUBLIC_SUPABASE")) {
        setError("تنظیمات Supabase کامل نیست. متغیرهای NEXT_PUBLIC_SUPABASE_URL و NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY را در فایل محیطی برنامه تنظیم و سرور را دوباره راه‌اندازی کنید.");
        return;
      }
      if (caughtError instanceof Error && caughtError.message.includes("NEXT_PUBLIC_SITE_URL")) {
        setError("نشانی سایت برای پیوند تأیید ایمیل به‌درستی پیکربندی نشده است.");
        return;
      }
      setError("ارتباط با سرویس ورود برقرار نشد. دوباره تلاش کنید.");
      return;
    }

    setBusy(false);
    if (result.error) {
      setError(
        isSignUp
          ? "ثبت‌نام انجام نشد. ایمیل و گذرواژه را بررسی کنید؛ ممکن است این ایمیل قبلاً ثبت شده باشد."
          : "ایمیل یا گذرواژه نادرست است.",
      );
      return;
    }

    if (isSignUp && !result.data.session) {
      setMessage("حساب شما ایجاد شد. لینک تأیید به ایمیلتان ارسال شده است؛ پس از تأیید، برای تکمیل ایده به جوانه بازمی‌گردید.");
      return;
    }

    if (!result.data.session) {
      setError("نشست ورود ایجاد نشد. دوباره تلاش کنید.");
      return;
    }

    router.replace(sanitizeReturnTo(returnTo));
    router.refresh();
  }

  return (
    <form onSubmit={submit} className="space-y-4" dir="rtl">
      {isSignUp && (
        <>
          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="signup-first-name" className="auth-label">نام</label>
              <input
                id="signup-first-name"
                name="firstName"
                autoComplete="given-name"
                required
                value={firstName}
                onChange={(event) => setFirstName(event.target.value)}
                className="auth-input"
              />
            </div>
            <div>
              <label htmlFor="signup-last-name" className="auth-label">نام خانوادگی</label>
              <input
                id="signup-last-name"
                name="lastName"
                autoComplete="family-name"
                required
                value={lastName}
                onChange={(event) => setLastName(event.target.value)}
                className="auth-input"
              />
            </div>
          </div>
          <div>
            <label htmlFor="signup-national-id" className="auth-label">کد ملی</label>
            <input
              id="signup-national-id"
              name="nationalId"
              inputMode="numeric"
              autoComplete="off"
              maxLength={10}
              dir="ltr"
              required
              value={nationalId}
              onChange={(event) => {
                const digits = normalizeDigits(event.target.value).replace(/\D/g, "").slice(0, 10);
                setNationalId(digits);
              }}
              aria-describedby="national-id-hint"
              className="auth-input text-left"
            />
            <p id="national-id-hint" className="mt-2 text-xs leading-5 text-white/45">
              ۱۰ رقم؛ ارقام فارسی و انگلیسی پذیرفته می‌شوند.
            </p>
            <p className="mt-1 text-xs leading-5 text-white/40">
              به‌دلیل نبود فضای ذخیره‌سازی امن پروفایل در پایگاه دادهٔ فعلی، کد ملی اعتبارسنجی می‌شود اما به Supabase ارسال یا ذخیره نمی‌شود.
            </p>
          </div>
        </>
      )}
      <div>
        <label htmlFor="email" className="auth-label">ایمیل</label>
        <input
          id="email"
          name="email"
          type="email"
          required
          autoComplete="email"
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          className="auth-input text-left"
          dir="ltr"
        />
      </div>
      <div>
        <label htmlFor="password" className="auth-label">گذرواژه</label>
        <input
          id="password"
          name="password"
          type="password"
          required
          minLength={6}
          autoComplete={isSignUp ? "new-password" : "current-password"}
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          className="auth-input text-left"
          dir="ltr"
        />
        {isSignUp && <p className="mt-2 text-xs text-white/40">حداقل ۶ نویسه</p>}
      </div>
      {(error ?? initialError) && <p role="alert" className="auth-error">{error ?? initialError}</p>}
      {message && <p role="status" className="auth-success">{message}</p>}
      <button type="submit" disabled={busy} className="auth-primary-button">
        {busy ? "در حال پردازش…" : isSignUp ? "ایجاد حساب و ادامه" : "ورود"}
        {!busy && <span aria-hidden="true">←</span>}
      </button>
    </form>
  );
}
