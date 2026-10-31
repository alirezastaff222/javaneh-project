import Link from "next/link";

export default function Home() {
  return (
    <main className="flex min-h-full flex-1 items-center justify-center px-6 py-24 text-center">
      <div className="space-y-4">
        <h1 className="text-4xl font-semibold tracking-tight text-foreground">
          جوانه
        </h1>
        <p className="text-lg text-foreground/80">
          بستر توسعه نوآوری اجتماعی
        </p>
        <p className="text-base text-foreground/60">به جوانه خوش آمدید.</p>
        <Link
          href="/ideas"
          className="inline-flex min-h-11 items-center rounded-lg border border-foreground/20 px-4 font-medium transition-colors hover:bg-foreground/5 focus-visible:outline-2 focus-visible:outline-offset-2"
        >
          ثبت و توسعه ایده
        </Link>
      </div>
    </main>
  );
}
