import { connection } from "next/server";
import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { participantResultSchema } from "@/lib/ideas/competition-results";

export async function GET(request: Request) {
  await connection();
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  if (error || !user) return NextResponse.json({ error: "Authentication required." }, { status: 401 });
  const ideaId = new URL(request.url).searchParams.get("ideaId");
  if (!ideaId) return NextResponse.json({ error: "A valid idea ID is required." }, { status: 400 });
  const { data, error: rpcError } = await supabase.rpc("get_participant_published_result", {
    p_idea_id: ideaId,
  });
  if (rpcError) return NextResponse.json({ error: "The final result could not be loaded." }, { status: 500 });
  const parsed = participantResultSchema.safeParse(data ?? { state: "unpublished" });
  if (!parsed.success) return NextResponse.json({ error: "Invalid final result." }, { status: 500 });
  return NextResponse.json(parsed.data, { headers: { "Cache-Control": "private, no-store" } });
}
