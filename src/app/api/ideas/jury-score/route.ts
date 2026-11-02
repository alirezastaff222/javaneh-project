import { connection } from "next/server";
import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { participantJuryScoreSchema } from "@/lib/ideas/jury-scoring";

export async function GET(request: Request) {
  await connection();
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  const ideaId = new URL(request.url).searchParams.get("ideaId");
  if (!ideaId) return NextResponse.json({ error: "A valid idea ID is required." }, { status: 400 });
  const { data: idea, error: ideaError } = await supabase
    .from("ideas")
    .select("group_id")
    .eq("id", ideaId)
    .maybeSingle();
  if (ideaError) return NextResponse.json({ error: "Jury score could not be loaded." }, { status: 500 });
  const { data, error: rpcError } = await supabase.rpc(idea?.group_id
    ? "get_group_published_jury_score"
    : "get_participant_published_jury_score", {
    p_idea_id: ideaId,
  });
  if (rpcError) return NextResponse.json({ error: "Jury score could not be loaded." }, { status: 500 });
  const parsed = participantJuryScoreSchema.safeParse(data ?? { state: "unpublished" });
  if (!parsed.success) return NextResponse.json({ error: "Invalid jury score." }, { status: 500 });
  return NextResponse.json(parsed.data, { headers: { "Cache-Control": "private, no-store" } });
}
