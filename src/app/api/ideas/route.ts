import { connection } from "next/server";
import { loadParticipantWorkspace } from "@/lib/ideas/participant-workspace";
import { createParticipantWorkspaceHandler } from "@/lib/ideas/participant-workspace-route";

export async function GET() {
  await connection();
  return createParticipantWorkspaceHandler(loadParticipantWorkspace)();
}
