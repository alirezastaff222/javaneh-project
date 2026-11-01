import { NextResponse } from "next/server";
import { parseParticipantScorecard } from "./participant-scorecard";

const responseHeaders = { "Cache-Control": "private, no-store" };
const ideaIdPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function response(body: unknown, status = 200) {
  return NextResponse.json(body, { status, headers: responseHeaders });
}

export function createParticipantScorecardHandler<TContext>(dependencies: {
  authenticate(): Promise<{ context: TContext } | null>;
  fetchScorecard(ideaId: string, context: TContext): Promise<unknown>;
}) {
  return async function handleParticipantScorecard(request: Request) {
    let authenticated: Awaited<ReturnType<typeof dependencies.authenticate>>;
    try {
      authenticated = await dependencies.authenticate();
    } catch {
      return response({ error: "The scorecard could not be loaded." }, 503);
    }
    if (!authenticated) {
      return response({ error: "Authentication required." }, 401);
    }

    const parameters = new URL(request.url).searchParams;
    const ideaId = parameters.get("ideaId");
    if (parameters.size !== 1 || !ideaId || !ideaIdPattern.test(ideaId)) {
      return response({ error: "A valid idea ID is required." }, 400);
    }

    try {
      const scorecard = parseParticipantScorecard(
        await dependencies.fetchScorecard(ideaId, authenticated.context),
      );
      if (!scorecard) {
        return response({ error: "The scorecard response was invalid." }, 500);
      }
      return response({ scorecard });
    } catch {
      return response({ error: "The scorecard could not be loaded." }, 500);
    }
  };
}