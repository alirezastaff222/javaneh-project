import { NextResponse } from "next/server";

import { createClient } from "@/lib/supabase/server";
import {
  getAssignedIdeas,
  mapEvaluationError,
  parseAssignedIdeas,
} from "@/lib/ideas/evaluator-api";

export async function GET() {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  }

  const { data, error } = await getAssignedIdeas(supabase);
  if (error) {
    const mapped = mapEvaluationError(error);
    if (mapped) {
      return NextResponse.json({ error: mapped.error }, { status: mapped.status });
    }
    return NextResponse.json({ error: "The evaluator assignments could not be loaded." }, { status: 500 });
  }

  const assignments = parseAssignedIdeas(data, null);
  if (assignments.kind === "error") {
    return NextResponse.json(
      { error: "The evaluator assignments could not be loaded." },
      { status: 500 },
    );
  }

  return NextResponse.json({
    outcome: "available",
    items: assignments.items,
  });
}
