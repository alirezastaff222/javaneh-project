import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import {
  getParticipantMilestoneEvaluations,
  participantMilestoneEvaluationsSchema,
  submitMilestoneForValidation,
} from "@/lib/ideas/milestone-evaluation";

const headers = { "Cache-Control": "private, no-store" };

export async function GET(request: Request) {
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) {
    return NextResponse.json({ error: "Authentication required." }, { status: 401, headers });
  }
  const ideaId = new URL(request.url).searchParams.get("ideaId");
  if (!ideaId) {
    return NextResponse.json({ error: "A valid idea ID is required." }, { status: 400, headers });
  }
  const result = await getParticipantMilestoneEvaluations(supabase, ideaId);
  if (result.error) {
    return NextResponse.json({ error: "Milestone evaluations could not be loaded." }, { status: 500, headers });
  }
  const parsed = participantMilestoneEvaluationsSchema.safeParse(result.data);
  if (!parsed.success) {
    return NextResponse.json({ error: "Milestone evaluation data was invalid." }, { status: 500, headers });
  }
  return NextResponse.json(parsed.data, { headers });
}

export async function POST(request: Request) {
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) {
    return NextResponse.json({ error: "Authentication required." }, { status: 401, headers });
  }
  let body: unknown;
  try { body = await request.json(); } catch {
    return NextResponse.json({ error: "Invalid request." }, { status: 400, headers });
  }
  if (
    typeof body !== "object" || body === null ||
    typeof (body as Record<string, unknown>).ideaId !== "string" ||
    typeof (body as Record<string, unknown>).configurationVersionId !== "string" ||
    typeof (body as Record<string, unknown>).milestoneKey !== "string" ||
    typeof (body as Record<string, unknown>).expectedRevision !== "number"
  ) {
    return NextResponse.json({ error: "Invalid milestone submission." }, { status: 400, headers });
  }
  const input = body as {
    ideaId: string;
    configurationVersionId: string;
    milestoneKey: string;
    expectedRevision: number;
  };
  const result = await submitMilestoneForValidation(supabase, input);
  if (result.error) {
    return NextResponse.json({ error: result.error.message ?? "Submission failed." }, { status: result.error.code === "42501" ? 403 : 500, headers });
  }
  return NextResponse.json(result.data ?? { outcome: "unknown" }, { headers });
}
