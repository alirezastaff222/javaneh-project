import { Suspense } from "react";
import { connection } from "next/server";
import { redirect } from "next/navigation";
import { loadParticipantWorkspace } from "@/lib/ideas/participant-workspace";
import { buildAuthPath } from "@/lib/supabase/auth";
import { createClient } from "@/lib/supabase/server";
import IdeasWizard from "./ideas-wizard";

async function ParticipantWorkspace({
  searchParams,
}: {
  searchParams: Promise<{ seed?: string; groupInvite?: string }>;
}) {
  await connection();
  const params = await searchParams;
  const initialIdeaText = typeof params.seed === "string"
    ? params.seed.trim().slice(0, 4000)
    : "";
  const initialGroupInvitationId =
    typeof params.groupInvite === "string" ? params.groupInvite : "";
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    const returnParams = new URLSearchParams();
    if (initialIdeaText) returnParams.set("seed", initialIdeaText);
    if (initialGroupInvitationId) {
      returnParams.set("groupInvite", initialGroupInvitationId);
    }
    const returnTo = returnParams.size > 0
      ? `/ideas?${returnParams.toString()}`
      : "/ideas";
    redirect(buildAuthPath("/auth/sign-in", returnTo));
  }

  const initialWorkspace = await loadParticipantWorkspace();
  return (
    <IdeasWizard
      initialWorkspace={initialWorkspace}
      initialIdeaText={initialIdeaText}
      initialGroupInvitationId={initialGroupInvitationId}
    />
  );
}

export default function IdeasPage(props: {
  searchParams: Promise<{ seed?: string; groupInvite?: string }>;
}) {
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
      <ParticipantWorkspace searchParams={props.searchParams} />
    </Suspense>
  );
}
