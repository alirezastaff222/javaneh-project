export type ParticipantGroupRole = "owner" | "member";

export type ParticipantGroupMember = {
  user_id: string;
  role: ParticipantGroupRole;
  joined_at: string;
};

export type GroupInvitationSummary = {
  id: string;
  email: string;
  expires_at: string;
};

export type ParticipantGroup = {
  id: string;
  name: string;
  description: string;
  owner_id: string;
  role: ParticipantGroupRole;
  dissolved_at: string | null;
  created_at: string;
  members: ParticipantGroupMember[];
  pending_invitations: GroupInvitationSummary[];
};

export type ParticipantGroupInvitation = {
  id: string;
  group_id: string;
  group_name: string;
  invited_by: string;
  created_at: string;
  expires_at: string;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRole(value: unknown): value is ParticipantGroupRole {
  return value === "owner" || value === "member";
}

function parseMember(value: unknown): ParticipantGroupMember | null {
  if (
    !isRecord(value) ||
    typeof value.user_id !== "string" ||
    !isRole(value.role) ||
    typeof value.joined_at !== "string"
  ) {
    return null;
  }
  return {
    user_id: value.user_id,
    role: value.role,
    joined_at: value.joined_at,
  };
}

function parsePendingInvitation(value: unknown): GroupInvitationSummary | null {
  if (
    !isRecord(value) ||
    typeof value.id !== "string" ||
    typeof value.email !== "string" ||
    typeof value.expires_at !== "string"
  ) {
    return null;
  }
  return { id: value.id, email: value.email, expires_at: value.expires_at };
}

function parseGroup(value: unknown): ParticipantGroup | null {
  if (
    !isRecord(value) ||
    typeof value.id !== "string" ||
    typeof value.name !== "string" ||
    typeof value.description !== "string" ||
    typeof value.owner_id !== "string" ||
    !isRole(value.role) ||
    (value.dissolved_at !== null && typeof value.dissolved_at !== "string") ||
    typeof value.created_at !== "string" ||
    !Array.isArray(value.members) ||
    !Array.isArray(value.pending_invitations)
  ) {
    return null;
  }
  const members = value.members.map(parseMember);
  const pendingInvitations = value.pending_invitations.map(parsePendingInvitation);
  if (members.some((member) => member === null) ||
      pendingInvitations.some((invitation) => invitation === null)) {
    return null;
  }
  if (!members.some(
    (member) =>
      member !== null &&
      member.user_id === value.owner_id &&
      member.role === "owner",
  )) {
    return null;
  }
  return {
    id: value.id,
    name: value.name,
    description: value.description,
    owner_id: value.owner_id,
    role: value.role,
    dissolved_at: value.dissolved_at,
    created_at: value.created_at,
    members: members.filter((member): member is ParticipantGroupMember => member !== null),
    pending_invitations: pendingInvitations.filter(
      (invitation): invitation is GroupInvitationSummary => invitation !== null,
    ),
  };
}

function parseInvitation(value: unknown): ParticipantGroupInvitation | null {
  if (
    !isRecord(value) ||
    typeof value.id !== "string" ||
    typeof value.group_id !== "string" ||
    typeof value.group_name !== "string" ||
    typeof value.invited_by !== "string" ||
    typeof value.created_at !== "string" ||
    typeof value.expires_at !== "string"
  ) {
    return null;
  }
  return {
    id: value.id,
    group_id: value.group_id,
    group_name: value.group_name,
    invited_by: value.invited_by,
    created_at: value.created_at,
    expires_at: value.expires_at,
  };
}

export function parseParticipantGroupsResponse(value: unknown): {
  groups: ParticipantGroup[];
  invitations: ParticipantGroupInvitation[];
} | null {
  if (
    !isRecord(value) ||
    !isRecord(value.groups) ||
    !Array.isArray(value.groups.groups) ||
    !isRecord(value.invitations) ||
    !Array.isArray(value.invitations.invitations)
  ) {
    return null;
  }
  const groups = value.groups.groups.map(parseGroup);
  const invitations = value.invitations.invitations.map(parseInvitation);
  if (groups.some((group) => group === null) ||
      invitations.some((invitation) => invitation === null)) {
    return null;
  }
  return {
    groups: groups.filter((group): group is ParticipantGroup => group !== null),
    invitations: invitations.filter(
      (invitation): invitation is ParticipantGroupInvitation => invitation !== null,
    ),
  };
}
