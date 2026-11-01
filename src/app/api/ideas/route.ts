import { connection, NextResponse } from "next/server";
import { loadParticipantWorkspace } from "@/lib/ideas/participant-workspace";

export async function GET() {
  await connection();
  const workspace = await loadParticipantWorkspace();

  if (workspace.kind === "unauthenticated") {
    return NextResponse.json(
      { error: "Authentication required." },
      {
        status: 401,
        headers: { "Cache-Control": "private, no-store" },
      },
    );
  }

  if (workspace.kind === "error") {
    return NextResponse.json(
      { error: "The participant workspace could not be loaded." },
      {
        status: 500,
        headers: { "Cache-Control": "private, no-store" },
      },
    );
  }

  return NextResponse.json(
    { profile: workspace.profile, ideas: workspace.ideas },
    { headers: { "Cache-Control": "private, no-store" } },
  );
}
