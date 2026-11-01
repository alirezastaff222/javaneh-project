import { connection } from "next/server";
import { NextRequest, NextResponse } from "next/server";
import {
  createDraft,
  getOwnDraft,
  mapRpcError,
  parseDraftCreateBody,
  parseDraftUpdateBody,
  requireAuthenticatedUser,
  updateDraft,
} from "@/lib/ideas/feedback-api";
import { createClient } from "@/lib/supabase/server";

const privateHeaders = { "Cache-Control": "private, no-store" };

export async function GET(request: NextRequest) {
  await connection();
  const supabase = await createClient();
  const user = await requireAuthenticatedUser(supabase);
  if (!user) {
    return NextResponse.json(
      { error: "Authentication required." },
      { status: 401, headers: privateHeaders },
    );
  }

  const ideaId = request.nextUrl.searchParams.get("ideaId");
  if (!ideaId) {
    return NextResponse.json(
      { error: "ideaId is required." },
      { status: 400, headers: privateHeaders },
    );
  }

  const { data, error } = await getOwnDraft(supabase, ideaId);
  if (error) {
    const mapped = mapRpcError(error);
    return NextResponse.json(
      { error: mapped?.error ?? "The draft could not be loaded." },
      { status: mapped?.status ?? 500, headers: privateHeaders },
    );
  }

  return NextResponse.json(data ?? { outcome: "not_found" }, {
    headers: privateHeaders,
  });
}

export async function POST(request: NextRequest) {
  await connection();
  const supabase = await createClient();
  const user = await requireAuthenticatedUser(supabase);
  if (!user) {
    return NextResponse.json(
      { error: "Authentication required." },
      { status: 401, headers: privateHeaders },
    );
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { error: "Invalid JSON body." },
      { status: 400, headers: privateHeaders },
    );
  }

  const parsed = parseDraftCreateBody(body);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Invalid draft payload." },
      { status: 400, headers: privateHeaders },
    );
  }

  const { data, error } = await createDraft(supabase, {
    ideaId: parsed.data.ideaId,
    content: parsed.data.content,
  });
  if (error) {
    const mapped = mapRpcError(error);
    return NextResponse.json(
      { error: mapped?.error ?? "The draft could not be created." },
      { status: mapped?.status ?? 500, headers: privateHeaders },
    );
  }

  return NextResponse.json(data ?? { outcome: "not_found" }, {
    headers: privateHeaders,
  });
}

export async function PATCH(request: NextRequest) {
  await connection();
  const supabase = await createClient();
  const user = await requireAuthenticatedUser(supabase);
  if (!user) {
    return NextResponse.json(
      { error: "Authentication required." },
      { status: 401, headers: privateHeaders },
    );
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { error: "Invalid JSON body." },
      { status: 400, headers: privateHeaders },
    );
  }

  const parsed = parseDraftUpdateBody(body);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Invalid draft payload." },
      { status: 400, headers: privateHeaders },
    );
  }

  const { data, error } = await updateDraft(supabase, {
    draftId: parsed.data.draftId,
    content: parsed.data.content,
  });
  if (error) {
    const mapped = mapRpcError(error);
    return NextResponse.json(
      { error: mapped?.error ?? "The draft could not be updated." },
      { status: mapped?.status ?? 500, headers: privateHeaders },
    );
  }

  return NextResponse.json(data ?? { outcome: "not_found" }, {
    headers: privateHeaders,
  });
}
