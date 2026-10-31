"use client";

import dynamic from "next/dynamic";

const IdeasWizard = dynamic(() => import("./ideas-wizard"), {
  ssr: false,
  loading: () => (
    <main className="flex flex-1 items-center justify-center px-6 py-16">
      <p role="status" className="text-foreground/70">
        در حال آماده‌سازی صفحه ایده‌ها…
      </p>
    </main>
  ),
});

export default function IdeasPage() {
  return <IdeasWizard />;
}
