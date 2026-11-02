export function isUnauthenticatedAuthError(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false;

  const authError = error as {
    name?: unknown;
    status?: unknown;
  };

  return (
    authError.name === "AuthSessionMissingError" ||
    authError.status === 401
  );
}
