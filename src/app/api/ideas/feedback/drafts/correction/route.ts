import { connection } from "next/server";
import { NextRequest, NextResponse } from "next/server";
import {
  createCorrectionDraft,
  mapRpcError,
  parseCorrectionBody,
  requireAuthenticatedUser,
} from "@/lib/ideas/feedback-api";
import { createClient } from "@/lib/supabase/server";

const privateHeaders = { "Cache-Control": "private, no-store" };

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

  const parsed = parseCorrectionBody(body);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Invalid correction payload." },
      { status: 400, headers: privateHeaders },
    );
  }

  const { data, error } = await createCorrectionDraft(supabase, {
    ideaId: parsed.data.ideaId,
    content: parsed.data.content,
  });
  if (error) {
    const mapped = mapRpcError(error);
    return NextResponse.json(
      { error: mapped?.error ?? "The correction draft could not be created." },
      { status: mapped?.status ?? 500, headers: privateHeaders },
    );
  }

  return NextResponse.json(data ?? { outcome: "not_found" }, {
    headers: privateHeaders,
  });
}
