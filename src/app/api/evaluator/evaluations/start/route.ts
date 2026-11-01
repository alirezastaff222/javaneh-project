import { NextResponse } from "next/server";

import { createClient } from "@/lib/supabase/server";
import {
  mapEvaluationError,
  parseIdeaIdBody,
  startIdeaEvaluation,
} from "@/lib/ideas/evaluator-api";

export async function POST(request: Request) {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "A valid idea ID is required." }, { status: 400 });
  }

  const parsed = parseIdeaIdBody(body);
  if (!parsed.success) {
    return NextResponse.json({ error: "A valid idea ID is required." }, { status: 400 });
  }

  const { data, error } = await startIdeaEvaluation(supabase, parsed.data.ideaId);
  if (error) {
    const mapped = mapEvaluationError(error);
    if (mapped) {
      return NextResponse.json({ error: mapped.error }, { status: mapped.status });
    }
    return NextResponse.json({ error: "The evaluation could not be started." }, { status: 500 });
  }

  return NextResponse.json(data ?? { outcome: "unknown" }, { status: 200 });
}
