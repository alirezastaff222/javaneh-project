import { NextResponse } from "next/server";
import { isUnauthenticatedAuthError } from "@/lib/supabase/auth-errors";
import { parseDossierHistory } from "./dossier-history";

const responseHeaders = { "Cache-Control": "private, no-store" };
const ideaIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function response(body: unknown, status = 200) {
  return NextResponse.json(body, { status, headers: responseHeaders });
}

export class DossierHistoryUnavailableError extends Error {}

export function createDossierHistoryHandler<TContext>(dependencies: {
  authenticate(): Promise<{ context: TContext } | null>;
  fetchHistory(ideaId: string, context: TContext): Promise<unknown>;
}) {
  return async function handleDossierHistory(request: Request) {
    let authenticated: Awaited<ReturnType<typeof dependencies.authenticate>>;
    try {
      authenticated = await dependencies.authenticate();
    } catch (error) {
      if (isUnauthenticatedAuthError(error)) {
        return response({ error: "Authentication required." }, 401);
      }
      return response({ error: "History could not be loaded." }, 503);
    }

    if (!authenticated) {
      return response({ error: "Authentication required." }, 401);
    }

    const parameters = new URL(request.url).searchParams;
    const ideaId = parameters.get("ideaId");
    if (
      parameters.size !== 1 ||
      !ideaId ||
      !ideaIdPattern.test(ideaId)
    ) {
      return response({ error: "A valid idea ID is required." }, 400);
    }

    try {
      const history = parseDossierHistory(
        await dependencies.fetchHistory(ideaId, authenticated.context),
      );
      if (!history) return response({ error: "History could not be loaded." }, 500);
      return response({ history });
    } catch (error) {
      if (error instanceof DossierHistoryUnavailableError) {
        return response({ error: "History is unavailable." }, 404);
      }
      return response({ error: "History could not be loaded." }, 500);
    }
  };
}