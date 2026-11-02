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
    <main className="flex flex-1 items-center justify-center px-6 py-16">
      <section className="w-full max-w-md rounded-2xl border border-foreground/10 bg-white p-8 shadow-sm dark:bg-neutral-950">
        <p className="text-sm font-medium text-foreground/60">جوانه</p>
        <h1 className="mt-2 text-2xl font-semibold">
          {isSignUp ? "ایجاد حساب مشارکت‌کننده" : "ورود به فضای مشارکت‌کننده"}
        </h1>
        <p className="mt-3 mb-7 text-sm leading-7 text-foreground/70">
          {isSignUp
            ? "برای ثبت و توسعه ایده، حساب خود را بسازید."
            : "برای ادامه مسیر ایده‌ها، وارد حساب خود شوید."}
        </p>
        <AuthForm mode={mode} returnTo={returnTo} initialError={initialError} />
        <p className="mt-6 text-center text-sm text-foreground/70">
          {isSignUp ? "حساب دارید؟ " : "حساب ندارید؟ "}
          <Link
            href={`/auth/${isSignUp ? "sign-in" : "sign-up"}?returnTo=${encodeURIComponent(returnTo)}`}
            className="font-medium underline underline-offset-4"
          >
            {isSignUp ? "ورود" : "ثبت‌نام"}
          </Link>
        </p>
      </section>
    </main>
  );
}
