import { z } from "zod";

const validUuid = z.string().uuid();
const validFeedbackText = z
  .string()
  .trim()
  .min(1)
  .max(20000)
  .refine((value) => value.trim().length > 0, "Feedback content is required.");

export type AuthenticatedUser = {
  id: string;
};

export function parseDraftCreateBody(body: unknown) {
  return z
    .object({
      ideaId: validUuid,
      content: validFeedbackText,
    })
    .strict()
    .safeParse(body);
}

export function parseDraftUpdateBody(body: unknown) {
  return z
    .object({
      draftId: validUuid,
      content: validFeedbackText,
    })
    .strict()
    .safeParse(body);
}

export function parseCorrectionBody(body: unknown) {
  return z
    .object({
      ideaId: validUuid,
      content: validFeedbackText,
    })
    .strict()
    .safeParse(body);
}

export function parseDraftPublicationBody(body: unknown) {
  return z
    .object({
      draftId: validUuid,
    })
    .strict()
    .safeParse(body);
}

export async function requireAuthenticatedUser(supabase: {
  auth: {
    getUser(): Promise<{
      data: { user: AuthenticatedUser | null };
      error: { code?: string; message?: string } | null;
    }>;
  };
}) {
  const { data, error } = await supabase.auth.getUser();
  if (error || !data.user) {
    return null;
  }
  return data.user;
}

type RpcResponse = {
  data: unknown;
  error: { code?: string; message?: string } | null;
};

type RpcClient = {
  rpc: (name: string, args?: Record<string, unknown>) => unknown;
};

export async function getOwnDraft(
  supabase: RpcClient,
  ideaId: string,
) {
  const response = (await supabase.rpc("get_own_idea_feedback_draft", {
    p_idea_id: ideaId,
  })) as RpcResponse;
  return { data: response.data, error: response.error };
}

export async function createDraft(
  supabase: RpcClient,
  payload: { ideaId: string; content: string },
) {
  const response = (await supabase.rpc("create_idea_feedback_draft", {
    p_idea_id: payload.ideaId,
    p_feedback_content: payload.content,
  })) as RpcResponse;
  return { data: response.data, error: response.error };
}

export async function updateDraft(
  supabase: RpcClient,
  payload: { draftId: string; content: string },
) {
  const response = (await supabase.rpc("update_idea_feedback_draft", {
    p_draft_id: payload.draftId,
    p_feedback_content: payload.content,
  })) as RpcResponse;
  return { data: response.data, error: response.error };
}

export async function createCorrectionDraft(
  supabase: RpcClient,
  payload: { ideaId: string; content: string },
) {
  const response = (await supabase.rpc(
    "create_correction_idea_feedback_draft",
    {
      p_idea_id: payload.ideaId,
      p_feedback_content: payload.content,
    },
  )) as RpcResponse;
  return { data: response.data, error: response.error };
}

export async function getPublisherDrafts(
  supabase: RpcClient,
  draftId?: string,
) {
  if (draftId) {
    const response = (await supabase.rpc("get_eligible_feedback_draft_for_publication", {
      p_draft_id: draftId,
    })) as RpcResponse;
    return { data: response.data, error: response.error };
  }
  const response = (await supabase.rpc("get_eligible_feedback_drafts_for_publication", {})) as RpcResponse;
  return { data: response.data, error: response.error };
}

export async function publishDraft(
  supabase: RpcClient,
  draftId: string,
) {
  const response = (await supabase.rpc("publish_idea_feedback_draft", {
    p_draft_id: draftId,
  })) as RpcResponse;
  return { data: response.data, error: response.error };
}

export function mapRpcError(error: { code?: string; message?: string } | null) {
  if (!error) return null;
  if (error.code === "42501") return { status: 403, error: "Forbidden." };
  if (error.code === "23514") return { status: 400, error: "Invalid input." };
  return { status: 500, error: "The feedback operation could not be completed." };
}
