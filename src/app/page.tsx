import Link from "next/link";
import { Suspense } from "react";

const stages = [
  "Define the problem",
  "Find community strengths",
  "Develop possible ideas",
  "Plan how to act",
  "Test feasibility",
  "Prepare your idea dossier",
];

export default function Home(props: {
  searchParams: Promise<{ seed?: string; welcome?: string }>;
}) {
  return (
    <Suspense
      fallback={
        <main className="home-shell flex flex-1 items-center justify-center">
          <p role="status" className="text-sm text-white/60">در حال آماده‌سازی جوانه…</p>
        </main>
      }
    >
      <HomeContent searchParams={props.searchParams} />
    </Suspense>
  );
}

async function HomeContent({
  searchParams,
}: {
  searchParams: Promise<{ seed?: string; welcome?: string }>;
}) {
  const params = await searchParams;
  const seed = typeof params.seed === "string" ? params.seed.slice(0, 4000) : "";
  const showWelcome = params.welcome === "1" && seed.length > 0;

  return (
    <main lang="en" dir="ltr" className="home-shell flex-1 px-5 pt-4 sm:px-8 sm:pt-5">
      <div className="home-backdrop" aria-hidden="true">
        <div className="home-light-ring" />
        <div className="home-dot-field" />
        <span className="home-orb home-orb-green" />
        <span className="home-orb home-orb-white" />
        <span className="home-orb home-orb-red" />
        <span className="home-light-point home-light-point-green" />
        <span className="home-light-point home-light-point-red" />
      </div>

      <div className="home-content mx-auto flex min-h-[calc(100svh-1.25rem)] max-w-7xl flex-col">
        <header className="home-header flex items-center justify-between gap-4">
          <Link href="/" className="flex items-center gap-2.5" aria-label="Javaneh home">
            <span className="home-mark" aria-hidden="true">J</span>
            <span className="text-base font-semibold tracking-tight text-white">javaneh</span>
          </Link>
          <nav aria-label="Account" className="flex items-center gap-2">
            <Link
              href="/auth/sign-in?returnTo=%2Fideas"
              className="home-login rounded-full px-4 py-2 text-xs font-medium text-white/75 transition-colors hover:text-white focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-200"
            >
              Sign in
            </Link>
            <Link
              href="/auth/sign-up?returnTo=%2Fideas"
              className="home-account-link rounded-full px-4 py-2 text-xs font-medium text-[#111713] transition hover:bg-white/90 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-200"
            >
              Create account
            </Link>
          </nav>
        </header>

        {showWelcome && (
          <section className="home-welcome mx-auto mt-5 w-full max-w-3xl rounded-2xl p-4 text-right sm:p-5" dir="rtl" aria-live="polite">
            <p className="text-sm font-semibold text-emerald-100">به جوانه خوش آمدید؛ حالا می‌توانید فرایند ثبت ایده را تکمیل کنید.</p>
            <p className="mt-2 line-clamp-2 text-sm leading-6 text-white/65">{seed}</p>
            <Link
              href={`/ideas/intake?seed=${encodeURIComponent(seed)}`}
              className="home-submit mt-4 inline-flex min-h-10 items-center justify-center gap-2 rounded-lg px-4 text-xs font-semibold text-[#07120d] transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-200"
            >
              ثبت ایده
              <span aria-hidden="true">←</span>
            </Link>
          </section>
        )}

        <section className="home-hero relative flex flex-1 flex-col items-center text-center" aria-labelledby="home-title">
          <div className="home-hero-content relative flex w-full flex-col items-center">
            <Link
              href="/ideas"
              className="home-discovery mb-5 inline-flex items-center gap-3 rounded-full px-4 py-2 text-[0.68rem] font-medium text-white/75 transition hover:border-white/30 hover:text-white focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-200"
            >
              Social innovation, grown together
              <span className="home-discovery-arrow" aria-hidden="true">↗</span>
            </Link>

            <h1 id="home-title" className="max-w-3xl text-[2.4rem] font-medium leading-[1.08] tracking-[-0.045em] text-white sm:text-5xl lg:text-[3.55rem]">
              A good idea can change
              <br className="hidden sm:block" />{" "}
              <span className="home-headline-accent">where it begins.</span>
            </h1>
            <p className="mt-4 max-w-xl text-sm leading-6 text-white/60 sm:text-base">
              Javaneh helps people turn the social challenges they see every day into thoughtful, workable ideas for their communities.
            </p>

            <form action="/ideas/intake?demo=1" method="get" className="home-glass mt-7 w-full max-w-[34rem] rounded-2xl p-3 text-left sm:mt-8 sm:p-4">
              <div className="mb-2 flex items-center justify-between gap-3 px-1.5">
                <label htmlFor="first-idea" className="text-xs font-medium text-white/75 sm:text-sm">
                  What would you like to change?
                </label>
                <span className="home-input-indicator" aria-hidden="true">
                  <span />
                  Your idea starts here
                </span>
              </div>
              <textarea
                id="first-idea"
                name="seed"
                required
                maxLength={4000}
                rows={3}
                defaultValue={showWelcome ? seed : undefined}
                placeholder="Describe the social problem you want to solve..."
                className="home-textarea w-full resize-y rounded-xl px-3.5 py-3 text-sm leading-6 text-white outline-none transition placeholder:text-white/35 focus:border-emerald-200/50 focus:ring-4 focus:ring-emerald-200/10 sm:px-4"
              />
              <div className="mt-2.5 flex flex-col gap-3 px-1 sm:flex-row sm:items-center sm:justify-between">
                <p className="max-w-xs text-[0.68rem] leading-5 text-white/45">
                  Start with a concern, a place, or a community you care about.
                </p>
                <button
                  type="submit"
                  className="home-submit inline-flex min-h-10 shrink-0 items-center justify-center gap-3 rounded-lg px-4 text-xs font-semibold text-[#07120d] transition focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-emerald-200"
                >
                  Continue with your idea
                  <span aria-hidden="true">→</span>
                </button>
              </div>
            </form>

            <div className="home-trust mt-6 flex items-center gap-2 text-[0.68rem] text-white/45">
              <span className="home-lock-icon" aria-hidden="true">✳</span>
              Your work stays yours · No account needed to begin
            </div>

            <div className="home-journey mt-7 w-full max-w-4xl" aria-label="The six stages of your idea journey">
              <div className="mb-3 flex items-center justify-center gap-2 text-[0.62rem] font-medium uppercase tracking-[0.17em] text-white/45">
                <span className="home-journey-line" aria-hidden="true" />
                From insight to action
                <span className="home-journey-line" aria-hidden="true" />
              </div>
              <ol className="home-stages">
                {stages.map((stage, index) => (
                  <li key={stage} className="home-stage flex items-start gap-2 text-left">
                    <span className={`home-stage-number flex size-6 shrink-0 items-center justify-center rounded-full border text-[0.65rem] font-medium ${index === 0 ? "home-stage-active" : ""}`}>
                      {index + 1}
                    </span>
                    <span className={`pt-1 text-[0.65rem] leading-4 sm:text-xs ${index === 0 ? "text-white/85" : "text-white/45"}`}>{stage}</span>
                  </li>
                ))}
              </ol>
            </div>
          </div>
        </section>

        <footer className="home-footer flex flex-wrap items-center justify-between gap-3 py-4 text-[0.65rem]">
          <span>Javaneh · Social innovation platform</span>
          <div className="flex gap-5">
            <Link href="/evaluator" className="underline-offset-4 hover:text-white hover:underline">Evaluator workspace</Link>
            <Link href="/feedback/publisher" className="underline-offset-4 hover:text-white hover:underline">Feedback publishing</Link>
          </div>
        </footer>
      </div>
    </main>
  );
}
