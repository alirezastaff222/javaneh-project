import { connection } from "next/server";
import {
  createDossierHistoryHandler,
  DossierHistoryUnavailableError,
} from "@/lib/ideas/dossier-history-route";
import { isUnauthenticatedAuthError } from "@/lib/supabase/auth-errors";
import { createClient } from "@/lib/supabase/server";

export async function GET(request: Request) {
  await connection();

  const handler = createDossierHistoryHandler({
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
    fetchHistory: async (ideaId, supabase) => {
      const { data, error } = await supabase.rpc(
        "get_own_submitted_idea_dossier_history",
        { p_idea_id: ideaId },
      );
      if (error?.code === "42501") {
        throw new DossierHistoryUnavailableError();
      }
      if (error) throw error;
      return data;
    },
  });

  return handler(request);
}