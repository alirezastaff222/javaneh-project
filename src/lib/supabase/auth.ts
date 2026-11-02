const defaultDestination = "/ideas";

export function sanitizeReturnTo(value: string | null | undefined): string {
  if (!value) return defaultDestination;

  try {
    const decoded = decodeURIComponent(value);
    if (decoded.startsWith("/") && !decoded.startsWith("//")) {
      return decoded;
    }
  } catch {
    return defaultDestination;
  }

  return defaultDestination;
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
): string {
  const callback = new URL("/auth/callback", origin);
  callback.searchParams.set("returnTo", sanitizeReturnTo(returnTo));
  return callback.toString();
}
