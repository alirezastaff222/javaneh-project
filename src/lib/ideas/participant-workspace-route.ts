import { NextResponse } from "next/server";
import type { ParticipantWorkspace } from "./participant-workspace";

export function createParticipantWorkspaceHandler(
  load: () => Promise<ParticipantWorkspace>,
) {
  return async function handleParticipantWorkspace(): Promise<NextResponse> {
    const workspace = await load();

    if (workspace.kind === "unauthenticated") {
      return NextResponse.json(
        { error: "Authentication required." },
        { status: 401, headers: { "Cache-Control": "private, no-store" } },
      );
    }

    if (workspace.kind === "error") {
      return NextResponse.json(
        {
          error:
            workspace.code === "ideas_unavailable"
              ? "ایده‌های شما در حال حاضر در دسترس نیستند."
              : "فضای کار شما در حال حاضر در دسترس نیست.",
          code: workspace.code,
        },
        { status: 503, headers: { "Cache-Control": "private, no-store" } },
      );
    }

    return NextResponse.json(
      { profile: workspace.profile, ideas: workspace.ideas },
      { headers: { "Cache-Control": "private, no-store" } },
    );
  };
}
