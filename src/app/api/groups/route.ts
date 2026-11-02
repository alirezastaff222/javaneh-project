import { connection } from "next/server";
import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";

const headers = { "Cache-Control": "private, no-store" };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function authenticatedClient() {
  const supabase = await createClient();
  const {
    data: { user },
    error,
  } = await supabase.auth.getUser();
  return { supabase, user, error };
}

export async function GET() {
  await connection();
  const { supabase, user, error } = await authenticatedClient();
  if (error || !user) {
    return NextResponse.json({ error: "Authentication required." }, { status: 401, headers });
  }
  const [groups, invitations] = await Promise.all([
    supabase.rpc("get_my_participant_groups"),
    supabase.rpc("get_my_group_invitations"),
  ]);
  if (groups.error || invitations.error) {
    console.error("Participant groups could not be loaded", {
      groups: groups.error?.code,
      invitations: invitations.error?.code,
    });
    return NextResponse.json({ error: "Groups could not be loaded." }, { status: 500, headers });
  }
  return NextResponse.json({
    groups: groups.data,
    invitations: invitations.data,
  }, { headers });
}

export async function POST(request: Request) {
  await connection();
  const { supabase, user, error } = await authenticatedClient();
  if (error || !user) {
    return NextResponse.json({ error: "Authentication required." }, { status: 401, headers });
  }

  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return NextResponse.json({ error: "Invalid request body." }, { status: 400, headers });
  }
  if (!isRecord(payload) || typeof payload.action !== "string") {
    return NextResponse.json({ error: "Invalid group action." }, { status: 400, headers });
  }

  let rpcName: string;
  let rpcArgs: Record<string, unknown>;
  switch (payload.action) {
    case "create":
      if (typeof payload.name !== "string" ||
          (payload.description !== undefined && typeof payload.description !== "string")) {
        return NextResponse.json({ error: "Invalid group profile." }, { status: 400, headers });
      }
      rpcName = "create_participant_group";
      rpcArgs = {
        p_name: payload.name,
        p_description: payload.description ?? "",
      };
      break;
    case "invite":
      if (typeof payload.groupId !== "string" || typeof payload.email !== "string") {
        return NextResponse.json({ error: "Invalid invitation." }, { status: 400, headers });
      }
      rpcName = "create_group_invitation";
      rpcArgs = { p_group_id: payload.groupId, p_email: payload.email };
      break;
    case "accept":
    case "reject":
      if (typeof payload.invitationId !== "string") {
        return NextResponse.json({ error: "Invalid invitation." }, { status: 400, headers });
      }
      rpcName = "respond_to_group_invitation";
      rpcArgs = {
        p_invitation_id: payload.invitationId,
        p_accept: payload.action === "accept",
      };
      break;
    case "revoke":
      if (typeof payload.invitationId !== "string") {
        return NextResponse.json({ error: "Invalid invitation." }, { status: 400, headers });
      }
      rpcName = "revoke_group_invitation";
      rpcArgs = { p_invitation_id: payload.invitationId };
      break;
    case "remove_member":
    case "transfer_ownership":
      if (typeof payload.groupId !== "string" || typeof payload.memberId !== "string") {
        return NextResponse.json({ error: "Invalid member action." }, { status: 400, headers });
      }
      rpcName = "manage_participant_group";
      rpcArgs = {
        p_group_id: payload.groupId,
        p_action: payload.action,
        p_member_id: payload.memberId,
      };
      break;
    case "leave":
    case "dissolve":
      if (typeof payload.groupId !== "string") {
        return NextResponse.json({ error: "Invalid group action." }, { status: 400, headers });
      }
      rpcName = "manage_participant_group";
      rpcArgs = {
        p_group_id: payload.groupId,
        p_action: payload.action,
        p_member_id: null,
      };
      break;
    default:
      return NextResponse.json({ error: "Unsupported group action." }, { status: 400, headers });
  }

  const { data, error: rpcError } = await supabase.rpc(rpcName, rpcArgs);
  if (rpcError) {
    console.error("Participant group action failed", {
      action: payload.action,
      code: rpcError.code,
    });
    return NextResponse.json({ error: "Group action could not be completed." }, { status: 500, headers });
  }
  return NextResponse.json(data, { headers });
}
