import assert from "node:assert/strict";
import test from "node:test";
import { parseParticipantGroupsResponse } from "./participant-groups";

const group = {
  id: "group-1",
  name: "Community Garden",
  description: "",
  owner_id: "user-1",
  role: "owner",
  dissolved_at: null,
  created_at: "2026-11-02T12:00:00.000Z",
  members: [
    {
      user_id: "user-1",
      role: "owner",
      joined_at: "2026-11-02T12:00:00.000Z",
    },
  ],
  pending_invitations: [],
};

test("parses group roster and invitation response shapes", () => {
  assert.deepEqual(
    parseParticipantGroupsResponse({
      groups: { groups: [group] },
      invitations: {
        invitations: [
          {
            id: "invite-1",
            group_id: "group-2",
            group_name: "Open Workshop",
            invited_by: "user-2",
            created_at: "2026-11-02T12:00:00.000Z",
            expires_at: "2026-11-09T12:00:00.000Z",
          },
        ],
      },
    }),
    {
      groups: [group],
      invitations: [
        {
          id: "invite-1",
          group_id: "group-2",
          group_name: "Open Workshop",
          invited_by: "user-2",
          created_at: "2026-11-02T12:00:00.000Z",
          expires_at: "2026-11-09T12:00:00.000Z",
        },
      ],
    },
  );
});

test("rejects a group without its designated accepted owner", () => {
  assert.equal(
    parseParticipantGroupsResponse({
      groups: {
        groups: [{ ...group, members: [] }],
      },
      invitations: { invitations: [] },
    }),
    null,
  );
});

test("rejects malformed or partial group data", () => {
  assert.equal(
    parseParticipantGroupsResponse({
      groups: { groups: [{ ...group, role: "admin" }] },
      invitations: { invitations: [] },
    }),
    null,
  );
  assert.equal(parseParticipantGroupsResponse(null), null);
});
