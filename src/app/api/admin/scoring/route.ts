import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { scoringOperationsSummarySchema } from "@/lib/ideas/scoring-operations";

export async function GET() {
  const supabase = await createClient();
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  }
  const { data, error } = await supabase.rpc("get_scoring_operations_summary");
  if (error) {
    return NextResponse.json(
      { error: error.code === "42501" ? "Scoring Administrator access required." : "Scoring operations could not be loaded." },
      { status: error.code === "42501" ? 403 : 500 },
    );
  }
  const parsed = scoringOperationsSummarySchema.safeParse(data);
  if (!parsed.success) {
    return NextResponse.json({ error: "Scoring operations data was invalid." }, { status: 500 });
  }
  return NextResponse.json(parsed.data, { headers: { "Cache-Control": "private, no-store" } });
}

export async function POST(request: Request) {
  const supabase = await createClient();
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  }
  const body = await request.json().catch(() => null);
  if (
    typeof body !== "object" || body === null ||
    typeof body.versionId !== "string" ||
    typeof body.action !== "string" ||
    !["approve", "activate"].includes(body.action) ||
    typeof body.reason !== "string" || body.reason.trim().length === 0
  ) {
    return NextResponse.json({ error: "Invalid scoring operation." }, { status: 400 });
  }
  const functionName = body.action === "approve"
    ? "approve_scoring_configuration_version"
    : "activate_scoring_configuration_version";
  const { data, error } = await supabase.rpc(functionName, {
    p_version_id: body.versionId,
    p_reason: body.reason,
  });
  if (error) {
    return NextResponse.json(
      { error: error.code === "42501" ? "Scoring Administrator access required." : error.message },
      { status: error.code === "42501" ? 403 : 400 },
    );
  }
  return NextResponse.json(data);
}
