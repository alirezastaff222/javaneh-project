import { connection } from "next/server";
import { createParticipantScorecardHandler } from "@/lib/ideas/participant-scorecard-route";
import { isUnauthenticatedAuthError } from "@/lib/supabase/auth-errors";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: Request) {
  await connection();

  const handler = createParticipantScorecardHandler({
    authenticate: async () => {
      const supabase = await createClient();
      const {
        data: { user },
        error,
      } = await supabase.auth.getUser();
      if (error) {
        if (isUnauthenticatedAuthError(error)) return null;
        throw error;
      }
      return user ? { context: supabase } : null;
    },
    fetchScorecard: async (ideaId, supabase) => {
      const { data, error } = await supabase.rpc(
        "get_participant_idea_scorecard",
        { p_idea_id: ideaId },
      );
      if (error) throw error;
      return data;
    },
  });

  return handler(request);
}