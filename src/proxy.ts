import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { getSupabaseEnvironment } from "@/lib/supabase/env";

export async function proxy(request: NextRequest) {
  if (
    request.nextUrl.pathname === "/ideas/intake" &&
    request.nextUrl.searchParams.get("demo") === "1"
  ) {
    return NextResponse.next();
  }

  const { url, publishableKey } = getSupabaseEnvironment();
  const response = NextResponse.next({ request });
  const supabase = createServerClient(url, publishableKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        cookiesToSet.forEach(({ name, value, options }) => {
          request.cookies.set(name, value);
          response.cookies.set(name, value, options);
        });
      },
    },
  });

  await supabase.auth.getUser();
  return response;
}

export const config = {
  matcher: ["/ideas/:path*", "/auth/callback"],
};
