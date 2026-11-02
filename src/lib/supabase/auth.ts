const defaultDestination = "/ideas";

export function sanitizeReturnTo(value: string | null | undefined): string {
  if (!value) return defaultDestination;

  let destination = value;
  try {
    if (!destination.startsWith("/")) {
      destination = decodeURIComponent(destination);
    }
  } catch {
    return defaultDestination;
  }

  if (
    !destination.startsWith("/") ||
    destination.startsWith("//") ||
    destination.includes("\\")
  ) {
    return defaultDestination;
  }

  try {
    const url = new URL(destination, "https://javaneh.invalid");
    if (url.origin !== "https://javaneh.invalid") return defaultDestination;
    return `${url.pathname}${url.search}${url.hash}`;
  } catch {
    return defaultDestination;
  }
}

export function buildAuthPath(
  pathname: "/auth/sign-in" | "/auth/sign-up",
  returnTo: string | null | undefined,
): string {
  const destination = sanitizeReturnTo(returnTo);
  return `${pathname}?returnTo=${encodeURIComponent(destination)}`;
}

export function buildConfirmationRedirect(
  origin: string,
  returnTo: string | null | undefined,
  siteUrl?: string,
): string {
  const redirectOrigin = siteUrl?.trim() || origin;
  let baseUrl: URL;
  try {
    baseUrl = new URL(redirectOrigin);
  } catch {
    throw new Error("NEXT_PUBLIC_SITE_URL must be a valid absolute URL.");
  }
  const localHttp =
    baseUrl.protocol === "http:" &&
    process.env.NODE_ENV === "development" &&
    (baseUrl.hostname === "localhost" ||
      baseUrl.hostname === "127.0.0.1" ||
      baseUrl.hostname === "[::1]");
  if (
    baseUrl.username ||
    baseUrl.password ||
    (baseUrl.protocol !== "https:" && !localHttp) ||
    (siteUrl?.trim() && (baseUrl.pathname !== "/" || baseUrl.search || baseUrl.hash))
  ) {
    throw new Error(
      "NEXT_PUBLIC_SITE_URL must be an HTTPS origin (localhost is allowed for development).",
    );
  }
  const callback = new URL("/auth/callback", baseUrl.origin);
  callback.searchParams.set("returnTo", sanitizeReturnTo(returnTo));
  return callback.toString();
}
