import { Suspense } from "react";

import { createClient } from "@/lib/supabase/server";
import { parseAssignedIdeas } from "@/lib/ideas/evaluator-api";

import { EvaluatorDashboard } from "./evaluator-dashboard";

async function EvaluatorContent() {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return (
      <main className="mx-auto max-w-4xl p-6">
        <h1 className="text-2xl font-semibold">Evaluator access</h1>
        <p className="mt-3 text-foreground/70">
          Sign in to view assigned submissions for human review.
        </p>
      </main>
    );
  }

  const { data, error } = await supabase.rpc(
    "get_own_assigned_idea_evaluations",
    {},
  );
  const initialAssignments = parseAssignedIdeas(data, error);

  return <EvaluatorDashboard initialAssignments={initialAssignments} />;
}

export default function EvaluatorPage() {
  return (
    <Suspense
      fallback={
        <main className="mx-auto max-w-6xl space-y-6 p-6">
          <h1 className="text-2xl font-semibold">Evaluator access</h1>
          <p role="status" className="text-foreground/70">
            Loading assigned submissions for human review...
          </p>
        </main>
      }
    >
      <EvaluatorContent />
    </Suspense>
  );
}
