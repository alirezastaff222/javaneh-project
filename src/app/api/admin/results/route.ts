import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { adminResultsSchema } from "@/lib/ideas/competition-results";

async function authenticatedClient() {
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  return error || !user ? null : supabase;
}

export async function GET(request: Request) {
  const supabase = await authenticatedClient();
  if (!supabase) return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  const competitionId = new URL(request.url).searchParams.get("competitionId");
  if (!competitionId) return NextResponse.json({ error: "A competition ID is required." }, { status: 400 });
  const { data, error } = await supabase.rpc("get_competition_results_admin", {
    p_competition_id: competitionId,
  });
  if (error) return NextResponse.json({ error: error.code === "42501" ? "Scoring Administrator access required." : "Results could not be loaded." }, { status: error.code === "42501" ? 403 : 500 });
  if (data && typeof data === "object" && "error" in data) {
    return NextResponse.json({ error: "Scoring Administrator access required." }, { status: 403 });
  }
  const parsed = adminResultsSchema.safeParse(data);
  if (!parsed.success) return NextResponse.json({ error: "Invalid results response." }, { status: 500 });
  return NextResponse.json(parsed.data, { headers: { "Cache-Control": "private, no-store" } });
}

export async function POST(request: Request) {
  const supabase = await authenticatedClient();
  if (!supabase) return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  const body = await request.json().catch(() => null);
  if (typeof body !== "object" || body === null || typeof body.action !== "string"
      || typeof body.reason !== "string") {
    return NextResponse.json({ error: "Invalid result operation." }, { status: 400 });
  }
  let result;
  if (body.action === "prepare" && typeof body.competitionId === "string") {
    result = await supabase.rpc("prepare_competition_results", {
      p_competition_id: body.competitionId, p_reason: body.reason,
    });
  } else if (body.action === "approve" && typeof body.resultVersionId === "string") {
    result = await supabase.rpc("approve_competition_results", {
      p_result_version_id: body.resultVersionId, p_reason: body.reason,
    });
  } else if (body.action === "publish" && typeof body.resultVersionId === "string") {
    result = await supabase.rpc("publish_competition_results", {
      p_result_version_id: body.resultVersionId, p_reason: body.reason,
    });
  } else {
    return NextResponse.json({ error: "Invalid result operation." }, { status: 400 });
  }
  if (result.error) return NextResponse.json({ error: result.error.code === "42501" ? "Scoring Administrator access required." : result.error.message }, { status: result.error.code === "42501" ? 403 : 400 });
  return NextResponse.json(result.data);
}
