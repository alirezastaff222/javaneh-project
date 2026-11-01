import { Suspense } from "react";
import { connection } from "next/server";
import { loadParticipantWorkspace } from "@/lib/ideas/participant-workspace";
import IdeasWizard from "./ideas-wizard";

async function ParticipantWorkspace() {
  await connection();
  const initialWorkspace = await loadParticipantWorkspace();
  return <IdeasWizard initialWorkspace={initialWorkspace} />;
}

export default function IdeasPage() {
  return (
    <Suspense
      fallback={
        <main className="flex flex-1 items-center justify-center px-6 py-16">
          <p role="status" className="text-foreground/70">
            در حال آماده‌سازی فضای مشارکت‌کننده…
          </p>
        </main>
      }
    >
      <ParticipantWorkspace />
    </Suspense>
  );
}
