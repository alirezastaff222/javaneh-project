import Link from "next/link";

export default function Home() {
  return (
    <main lang="en" dir="ltr" className="home-shell flex-1 px-5 pb-10 pt-5 sm:px-8 sm:pt-8">
      <div className="mx-auto flex min-h-[calc(100svh-3.75rem)] max-w-7xl flex-col">
        <header className="flex items-center justify-between gap-4">
          <Link href="/" className="flex items-center gap-3" aria-label="Javaneh home">
            <span className="home-mark" aria-hidden="true">J</span>
            <span className="text-lg font-semibold tracking-tight text-[#172a24]">javaneh</span>
          </Link>
          <nav aria-label="Account" className="flex items-center gap-2 sm:gap-3">
            <Link
              href="/auth/sign-in?returnTo=%2Fideas"
              className="rounded-full px-3 py-2 text-sm font-medium text-[#52615b] transition-colors hover:text-[#172a24] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#3a7160]"
            >
              Sign in
            </Link>
            <Link
              href="/auth/sign-up?returnTo=%2Fideas"
              className="rounded-full border border-white/80 bg-white/60 px-4 py-2 text-sm font-medium text-[#172a24] shadow-sm backdrop-blur-xl transition hover:bg-white/85 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#3a7160]"
            >
              Create account
            </Link>
          </nav>
        </header>

        <div className="grid flex-1 items-center gap-12 py-16 lg:grid-cols-[minmax(0,1.15fr)_minmax(19rem,0.85fr)] lg:gap-20 lg:py-20">
          <section className="mx-auto w-full max-w-2xl lg:mx-0">
            <p className="mb-5 inline-flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.16em] text-[#567268]">
              <span className="size-2 rounded-full bg-[#d58a61]" aria-hidden="true" />
              Social innovation, grown together
            </p>
            <h1 className="max-w-xl font-serif text-5xl leading-[1.06] text-[#172a24] sm:text-6xl">
              A good idea can change <span className="text-[#4d7667]">where it begins.</span>
            </h1>
            <p className="mt-6 max-w-lg text-base leading-7 text-[#596760] sm:text-lg sm:leading-8">
              Javaneh helps people turn the social challenges they see every day into thoughtful, workable ideas for their communities.
            </p>

            <form action="/ideas" method="get" className="home-glass mt-9 rounded-[1.25rem] p-3 sm:p-4">
              <label htmlFor="first-idea" className="mb-2 block px-2 text-sm font-medium text-[#344b41]">
                What would you like to change?
              </label>
              <textarea
                id="first-idea"
                name="seed"
                required
                maxLength={4000}
                rows={4}
                placeholder="Describe the social problem you want to solve..."
                className="w-full resize-y rounded-xl border border-[#dce4df] bg-white/70 px-4 py-3 text-base leading-7 text-[#172a24] outline-none transition placeholder:text-[#89958f] focus:border-[#719486] focus:ring-4 focus:ring-[#719486]/15"
              />
              <div className="mt-3 flex flex-col gap-3 px-1 sm:flex-row sm:items-center sm:justify-between">
                <p className="max-w-xs text-xs leading-5 text-[#6b7972]">
                  Start with a concern, a place, or a community you care about.
                </p>
                <button
                  type="submit"
                  className="inline-flex min-h-12 shrink-0 items-center justify-center gap-3 rounded-xl bg-[#1f493b] px-5 text-sm font-semibold text-white shadow-[0_8px_24px_rgba(31,73,59,0.18)] transition hover:bg-[#173c30] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[#1f493b]"
                >
                  Start Developing Your Idea
                  <span aria-hidden="true">→</span>
                </button>
              </div>
            </form>
          </section>

          <aside className="mx-auto w-full max-w-md lg:mx-0 lg:justify-self-end" aria-label="The idea development journey">
            <div className="home-journey relative overflow-hidden rounded-[1.5rem] p-6 sm:p-8">
              <div className="flex items-start justify-between gap-5">
                <div>
                  <p className="text-xs font-semibold uppercase tracking-[0.14em] text-[#62756c]">From insight to action</p>
                  <h2 className="mt-2 font-serif text-3xl text-[#172a24]">Room to grow.</h2>
                </div>
                <span className="rounded-full border border-white/80 bg-white/55 px-3 py-1.5 text-xs font-medium text-[#4c655a] backdrop-blur-xl">6 guided stages</span>
              </div>
              <ol className="mt-8 space-y-0">
                {[
                  "Define the problem",
                  "Find community strengths",
                  "Develop possible ideas",
                  "Plan how to act",
                  "Test feasibility",
                  "Prepare your idea dossier",
                ].map((stage, index) => (
                  <li key={stage} className="relative flex min-h-12 items-center gap-4">
                    {index < 5 && <span className="absolute left-[15px] top-8 h-8 w-px bg-[#bdcec4]" aria-hidden="true" />}
                    <span className={`relative z-10 flex size-8 shrink-0 items-center justify-center rounded-full border text-xs font-semibold ${index === 0 ? "border-[#3c705d] bg-[#3c705d] text-white" : "border-[#c9d7cf] bg-white/80 text-[#65786e]"}`}>
                      {index + 1}
                    </span>
                    <span className={`text-sm ${index === 0 ? "font-semibold text-[#233d32]" : "text-[#64736b]"}`}>{stage}</span>
                  </li>
                ))}
              </ol>
              <p className="mt-7 border-t border-[#d6e0d9] pt-5 text-sm leading-6 text-[#65736c]">
                Your work stays yours. Save a draft, return when you are ready, and move forward one considered step at a time.
              </p>
            </div>
            <p className="mt-4 text-center text-xs leading-5 text-[#78847e]">
              Built for people working toward more resilient, inclusive communities.
            </p>
          </aside>
        </div>

        <footer className="flex flex-wrap items-center justify-between gap-3 border-t border-[#dce4df] py-5 text-xs text-[#78847e]">
          <span>Javaneh · Social innovation platform</span>
          <div className="flex gap-5">
            <Link href="/evaluator" className="underline-offset-4 hover:underline">Evaluator workspace</Link>
            <Link href="/feedback/publisher" className="underline-offset-4 hover:underline">Feedback publishing</Link>
          </div>
        </footer>
      </div>
    </main>
  );
}
