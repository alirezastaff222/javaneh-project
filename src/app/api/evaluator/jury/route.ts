import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { juryAssignmentsSchema } from "@/lib/ideas/jury-scoring";

async function client() {
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  return error || !user ? null : supabase;
}

export async function GET(request: Request) {
  const supabase = await client();
  if (!supabase) return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  const assignmentId = new URL(request.url).searchParams.get("assignmentId");
  if (assignmentId) {
    const { data, error } = await supabase.rpc("get_jury_rubric", { p_assignment_id: assignmentId });
    if (error) return NextResponse.json({ error: error.code === "42501" ? "Jury assignment access required." : error.message }, { status: error.code === "42501" ? 403 : 500 });
    return NextResponse.json(data);
  }
  const { data, error } = await supabase.rpc("get_assigned_jury_ideas");
  if (error) return NextResponse.json({ error: "Jury assignments could not be loaded." }, { status: 500 });
  const parsed = juryAssignmentsSchema.safeParse(data ?? []);
  if (!parsed.success) return NextResponse.json({ error: "Invalid jury assignments." }, { status: 500 });
  return NextResponse.json(parsed.data, { headers: { "Cache-Control": "private, no-store" } });
}

export async function POST(request: Request) {
  const supabase = await client();
  if (!supabase) return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  const body = await request.json().catch(() => null);
  if (typeof body !== "object" || body === null || typeof body.assignmentId !== "string" || !Array.isArray(body.scores)) {
    return NextResponse.json({ error: "Invalid jury evaluation." }, { status: 400 });
  }

  const { data, error } = await supabase.rpc("submit_jury_evaluation", {
    p_assignment_id: body.assignmentId,
    p_scores: body.scores,
  });
  if (error) return NextResponse.json({ error: error.code === "42501" ? "Jury assignment access required." : error.message }, { status: error.code === "42501" ? 403 : 400 });
  return NextResponse.json(data);
}

export async function PATCH(request: Request) {
  const supabase = await client();
  if (!supabase) return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  const body = await request.json().catch(() => null);
  if (typeof body !== "object" || body === null || typeof body.assignmentId !== "string" || typeof body.reason !== "string") {
    return NextResponse.json({ error: "A conflict reason is required." }, { status: 400 });
  }
  const { data, error } = await supabase.rpc("declare_jury_conflict", {
    p_assignment_id: body.assignmentId,
    p_reason: body.reason,
  });
  if (error) return NextResponse.json({ error: error.message }, { status: 400 });
  return NextResponse.json(data);
}
