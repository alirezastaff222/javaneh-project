import { NextResponse } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { buildAuthPath, sanitizeReturnTo } from "@/lib/supabase/auth";

export async function GET(request: Request) {
  const url = new URL(request.url);
  const returnTo = sanitizeReturnTo(url.searchParams.get("returnTo"));
  const code = url.searchParams.get("code");

  if (!code) {
    return NextResponse.redirect(
      new URL(`${buildAuthPath("/auth/sign-in", returnTo)}&error=missing_confirmation`, url.origin),
    );
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.exchangeCodeForSession(code);
  if (error) {
    return NextResponse.redirect(
      new URL(`${buildAuthPath("/auth/sign-in", returnTo)}&error=invalid_confirmation`, url.origin),
    );
  }

  return NextResponse.redirect(new URL(returnTo, url.origin));
}
