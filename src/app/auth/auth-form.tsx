"use client";

import { FormEvent, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { buildConfirmationRedirect, sanitizeReturnTo } from "@/lib/supabase/auth";

type AuthMode = "sign-in" | "sign-up";

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
  const supabase = useMemo(() => createClient(), []);
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

    let result;
    try {
      result =
        mode === "sign-up"
          ? await supabase.auth.signUp({
              email,
              password,
              options: {
                emailRedirectTo: buildConfirmationRedirect(
                  window.location.origin,
                  returnTo,
                ),
              },
            })
          : await supabase.auth.signInWithPassword({ email, password });
    } catch {
      setBusy(false);
      setError("ارتباط با سرویس ورود برقرار نشد. دوباره تلاش کنید.");
      return;
    }

    setBusy(false);
    if (result.error) {
      setError(
        mode === "sign-up"
          ? "ثبت‌نام انجام نشد. ایمیل و گذرواژه را بررسی کنید."
          : "ایمیل یا گذرواژه نادرست است.",
      );
      return;
    }

    if (mode === "sign-up" && !result.data.session) {
      setMessage(
        "لینک تأیید به ایمیل شما ارسال شد. پس از تأیید، برای ادامه به جوانه بازگردید.",
      );
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
    <form onSubmit={submit} className="space-y-5">
      <div>
        <label htmlFor="email" className="block text-sm font-medium">
          ایمیل
        </label>
        <input
          id="email"
          name="email"
          type="email"
          required
          autoComplete="email"
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          className="mt-2 min-h-11 w-full rounded-lg border border-foreground/20 bg-background px-3 text-left"
          dir="ltr"
        />
      </div>
      <div>
        <label htmlFor="password" className="block text-sm font-medium">
          گذرواژه
        </label>
        <input
          id="password"
          name="password"
          type="password"
          required
          minLength={6}
          autoComplete={mode === "sign-up" ? "new-password" : "current-password"}
          value={password}
          onChange={(event) => setPassword(event.target.value)}
          className="mt-2 min-h-11 w-full rounded-lg border border-foreground/20 bg-background px-3 text-left"
          dir="ltr"
        />
      </div>
      {(error ?? initialError) && (
        <p role="alert" className="text-sm text-red-700 dark:text-red-300">
          {error ?? initialError}
        </p>
      )}
      {message && <p role="status" className="text-sm text-green-700 dark:text-green-300">{message}</p>}
      <button
        type="submit"
        disabled={busy}
        className="min-h-11 w-full rounded-lg bg-foreground px-4 font-medium text-background disabled:opacity-60"
      >
        {busy ? "در حال پردازش…" : mode === "sign-up" ? "ایجاد حساب" : "ورود"}
      </button>
    </form>
  );
}
