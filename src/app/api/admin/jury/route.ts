import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

async function getClient() {
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  return error || !user ? null : supabase;
}

export async function GET() {
  const supabase = await getClient();
  if (!supabase) return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  const { data, error } = await supabase.rpc("get_jury_operations_queue");
  if (error) return NextResponse.json({ error: error.code === "42501" ? "Scoring Administrator access required." : error.message }, { status: error.code === "42501" ? 403 : 500 });
  return NextResponse.json({ items: data ?? [] }, { headers: { "Cache-Control": "private, no-store" } });
}

export async function POST(request: Request) {
  const supabase = await getClient();
  if (!supabase) return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  const body = await request.json().catch(() => null);
  if (typeof body !== "object" || body === null || typeof body.action !== "string") {
    return NextResponse.json({ error: "Invalid jury operation." }, { status: 400 });
  }
  let result;
  if (body.action === "assign" && typeof body.ideaId === "string" && typeof body.jurorId === "string") {
    result = await supabase.rpc("assign_jury_member", { p_idea_id: body.ideaId, p_juror_id: body.jurorId });
  } else if (body.action === "approve" && typeof body.ideaId === "string" && typeof body.reason === "string") {
    result = await supabase.rpc("approve_jury_publication", { p_idea_id: body.ideaId, p_reason: body.reason });
  } else if (body.action === "publish" && typeof body.publicationId === "string") {
    result = await supabase.rpc("publish_jury_result", { p_publication_id: body.publicationId });
  } else {
    return NextResponse.json({ error: "Invalid jury operation." }, { status: 400 });
  }
  if (result.error) return NextResponse.json({ error: result.error.code === "42501" ? "Scoring Administrator access required." : result.error.message }, { status: result.error.code === "42501" ? 403 : 400 });
  return NextResponse.json(result.data);
}
