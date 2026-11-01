import { NextResponse } from "next/server";

import { getAssignedDossier, mapEvaluationError, parseAssignedDossier, parseIdeaIdBody } from "@/lib/ideas/evaluator-api";
import { createClient } from "@/lib/supabase/server";

const privateHeaders = { "Cache-Control": "private, no-store" };

export async function GET(
  _request: Request,
  { params }: { params: Promise<{ ideaId: string }> },
) {
  const supabase = await createClient();
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser();

  if (authError || !user) {
    return NextResponse.json(
      { error: "Authentication required." },
      { status: 401, headers: privateHeaders },
    );
  }

  const { ideaId } = await params;
  const parsedIdeaId = parseIdeaIdBody({ ideaId });
  if (!parsedIdeaId.success) {
    return NextResponse.json(
      { error: "A valid idea ID is required." },
      { status: 400, headers: privateHeaders },
    );
  }

  const { data, error } = await getAssignedDossier(
    supabase,
    parsedIdeaId.data.ideaId,
  );
  if (error) {
    const mapped = mapEvaluationError(error);
    return NextResponse.json(
      {
        error: mapped?.error ?? "The assigned dossier could not be loaded.",
      },
      { status: mapped?.status ?? 500, headers: privateHeaders },
    );
  }

  if (
    typeof data === "object" &&
    data !== null &&
    "outcome" in data &&
    data.outcome === "not_found_or_not_assigned"
  ) {
    return NextResponse.json(
      { error: "The assigned dossier is unavailable." },
      { status: 404, headers: privateHeaders },
    );
  }

  const parsedDossier = parseAssignedDossier(data);
  if (!parsedDossier.success) {
    return NextResponse.json(
      { error: "The assigned dossier could not be loaded." },
      { status: 500, headers: privateHeaders },
    );
  }

  return NextResponse.json(parsedDossier.data, { headers: privateHeaders });
}
