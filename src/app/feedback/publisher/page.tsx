import { Suspense } from "react";
import { connection } from "next/server";

import { getPublisherDrafts } from "@/lib/ideas/feedback-api";
import {
  parseEligiblePublisherDrafts,
  type PublisherPageState,
} from "@/lib/ideas/feedback-publisher";
import { createClient } from "@/lib/supabase/server";

import { PublisherDashboard } from "./publisher-dashboard";

async function FeedbackPublisherWorkspace() {
  await connection();
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  let initialState: PublisherPageState;
  let actorId = "";
  if (authError) {
    initialState = { kind: "error" };
  } else if (!user) {
    initialState = { kind: "unauthenticated" };
  } else {
    actorId = user.id;
    const { data, error } = await getPublisherDrafts(supabase);
    if (error?.code === "42501") {
      initialState = { kind: "forbidden" };
    } else if (error) {
      initialState = { kind: "error" };
    } else {
      const drafts = parseEligiblePublisherDrafts(data, actorId);
      initialState = drafts
        ? { kind: "loaded", drafts }
        : { kind: "error" };
    }
  }

  return (
    <PublisherDashboard initialState={initialState} actorId={actorId} />
  );
}

export default function FeedbackPublisherPage() {
  return (
    <Suspense
      fallback={
        <main className="mx-auto max-w-5xl p-6">
          <p role="status" className="text-foreground/70">
            Loading publisher workspace...
          </p>
        </main>
      }
    >
      <FeedbackPublisherWorkspace />
    </Suspense>
  );
}
