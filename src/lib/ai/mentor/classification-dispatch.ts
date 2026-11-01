export const classificationRetryableFailureCategories = [
  "circuit_open",
  "circuit_control_unavailable",
  "timeout",
  "network",
  "rate_limited",
  "unavailable",
  "persistence_unavailable",
] as const;

export type ClassificationDispatchState = {
  status: "pending" | "processing" | "current" | "stale" | "failed";
  attempt_count: number;
  last_failure_category: string | null;
  retry_after: string | null;
  lease_expires_at: string | null;
  source_stage_1_revision_id?: string;
  source_stage_2_revision_id?: string;
};

export type ClassificationDispatchDecision =
  | { kind: "dispatch" }
  | { kind: "wait"; delayMs: number }
  | { kind: "none" };

const classificationMaxAttempts = 3;
const retryableCategorySet: ReadonlySet<string> = new Set(
  classificationRetryableFailureCategories,
);

export function isClassificationRetryableFailureCategory(
  category: string | null,
): boolean {
  return category !== null && retryableCategorySet.has(category);
}

export function getClassificationDispatchDecision(
  state: ClassificationDispatchState,
  now: number,
): ClassificationDispatchDecision {
  if (state.status === "pending") return { kind: "dispatch" };

  if (state.status === "processing" && state.lease_expires_at) {
    const leaseExpiresAt = Date.parse(state.lease_expires_at);
    if (!Number.isFinite(leaseExpiresAt)) return { kind: "none" };
    if (leaseExpiresAt > now) {
      return { kind: "wait", delayMs: leaseExpiresAt - now + 250 };
    }
    return { kind: "dispatch" };
  }

  if (
    state.status === "failed" &&
    state.attempt_count < classificationMaxAttempts &&
    isClassificationRetryableFailureCategory(state.last_failure_category) &&
    state.retry_after
  ) {
    const retryAfter = Date.parse(state.retry_after);
    if (!Number.isFinite(retryAfter)) return { kind: "none" };
    if (retryAfter > now) {
      return { kind: "wait", delayMs: retryAfter - now };
    }
    return { kind: "dispatch" };
  }

  return { kind: "none" };
}

export function shouldDispatchAfterConfirmation(input: {
  stageNumber: number;
  outcome: string;
  otherStageConfirmed: boolean;
}): boolean {
  if (input.outcome !== "confirmed") return false;
  if (input.stageNumber === 2) return true;
  return input.stageNumber === 1 && input.otherStageConfirmed;
}

export class ClassificationDispatchGate {
  private readonly dispatchedKeys = new Set<string>();
  private inFlight = false;

  begin(key: string): boolean {
    if (this.inFlight || this.dispatchedKeys.has(key)) return false;
    this.inFlight = true;
    this.dispatchedKeys.add(key);
    return true;
  }

  finish(): void {
    this.inFlight = false;
  }

  allowRetry(key: string): void {
    this.dispatchedKeys.delete(key);
  }
}
