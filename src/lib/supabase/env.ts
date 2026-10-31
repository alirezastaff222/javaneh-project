type SupabaseEnvironment = {
  url: string;
  publishableKey: string;
};

function configurationError(reason: string): Error {
  return new Error(
    `Supabase configuration error: ${reason} Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY.`,
  );
}

export function getSupabaseEnvironment(): SupabaseEnvironment {
  const urlValue = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim();

  if (!urlValue || !publishableKey) {
    throw configurationError("Both public configuration values are required.");
  }

  let url: URL;
  try {
    url = new URL(urlValue);
  } catch {
    throw configurationError("NEXT_PUBLIC_SUPABASE_URL must be a valid URL.");
  }

  const isLocalhost =
    url.hostname === "localhost" ||
    url.hostname === "127.0.0.1" ||
    url.hostname === "[::1]";
  const isLocalHttp =
    url.protocol === "http:" &&
    isLocalhost &&
    process.env.NODE_ENV === "development";

  if (
    url.username ||
    url.password ||
    !url.hostname ||
    (url.protocol !== "https:" && !isLocalHttp)
  ) {
    throw configurationError(
      "NEXT_PUBLIC_SUPABASE_URL must use HTTPS, except for localhost during development.",
    );
  }

  return { url: urlValue, publishableKey };
}
