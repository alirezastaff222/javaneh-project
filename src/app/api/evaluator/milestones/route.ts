import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import {
  getMilestoneValidationQueue,
  validateMilestoneRequest,
} from "@/lib/ideas/milestone-evaluation";

const headers = { "Cache-Control": "private, no-store" };

async function authenticatedClient() {
  const supabase = await createClient();
  const { data: { user }, error } = await supabase.auth.getUser();
  return error || !user ? null : supabase;
}

export async function GET() {
  const supabase = await authenticatedClient();
  if (!supabase) return NextResponse.json({ error: "Authentication required." }, { status: 401, headers });
  const result = await getMilestoneValidationQueue(supabase);
  if (result.error) return NextResponse.json({ error: result.error.code === "42501" ? "Validator access required." : "Validation queue could not be loaded." }, { status: result.error.code === "42501" ? 403 : 500, headers });
  return NextResponse.json({ outcome: "available", items: result.data ?? [] }, { headers });
}

export async function POST(request: Request) {
  const supabase = await authenticatedClient();
  if (!supabase) return NextResponse.json({ error: "Authentication required." }, { status: 401, headers });
  let body: unknown;
  try { body = await request.json(); } catch {
    return NextResponse.json({ error: "Invalid request." }, { status: 400, headers });
  }
  if (
    typeof body !== "object" || body === null ||
    typeof (body as Record<string, unknown>).requestId !== "string" ||
    !["validated", "needs_revision", "rejected"].includes(String((body as Record<string, unknown>).outcome)) ||
    typeof (body as Record<string, unknown>).evaluationLevel !== "number" ||
    typeof (body as Record<string, unknown>).reason !== "string"
  ) {
    return NextResponse.json({ error: "Invalid validation decision." }, { status: 400, headers });
  }
  const input = body as {
    requestId: string;
    outcome: "validated" | "needs_revision" | "rejected";
    evaluationLevel: number;
    reason: string;
  };
  const result = await validateMilestoneRequest(supabase, input);
  if (result.error) return NextResponse.json({ error: result.error.code === "42501" ? "Validator access required." : "Validation decision failed." }, { status: result.error.code === "42501" ? 403 : 500, headers });
  return NextResponse.json(result.data ?? { outcome: "unknown" }, { headers });
}
