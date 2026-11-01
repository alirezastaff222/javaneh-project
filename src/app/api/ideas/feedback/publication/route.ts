import { connection } from "next/server";
import { NextRequest, NextResponse } from "next/server";
import {
  getPublisherDrafts,
  mapRpcError,
  parseDraftPublicationBody,
  publishDraft,
  requireAuthenticatedUser,
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

  const draftId = request.nextUrl.searchParams.get("draftId");
  if (draftId) {
    const { data, error } = await getPublisherDrafts(supabase, draftId);
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

  const { data, error } = await getPublisherDrafts(supabase);
  if (error) {
    const mapped = mapRpcError(error);
    return NextResponse.json(
      { error: mapped?.error ?? "Eligible drafts could not be loaded." },
      { status: mapped?.status ?? 500, headers: privateHeaders },
    );
  }

  return NextResponse.json(data ?? { outcome: "available", drafts: [] }, {
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

  const parsed = parseDraftPublicationBody(body);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Invalid publication payload." },
      { status: 400, headers: privateHeaders },
    );
  }

  const { data, error } = await publishDraft(supabase, parsed.data.draftId);
  if (error) {
    const mapped = mapRpcError(error);
    return NextResponse.json(
      { error: mapped?.error ?? "The draft could not be published." },
      { status: mapped?.status ?? 500, headers: privateHeaders },
    );
  }

  return NextResponse.json(data ?? { outcome: "not_found" }, {
    headers: privateHeaders,
  });
}
