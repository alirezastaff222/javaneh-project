export type ClassificationDispatchState = {
  status:
    | "pending"
    | "processing_active"
    | "processing_expired"
    | "current"
    | "stale"
    | "retry_wait"
    | "retry_ready"
    | "failed";
  wait_ms: number | null;
  source_stage_1_revision_id: string;
  source_stage_2_revision_id: string;
};

export type ClassificationDispatchDecision =
  | { kind: "dispatch" }
  | { kind: "wait"; delayMs: number }
  | { kind: "none" };

export type ClassificationRetryTimerScheduler = {
  setTimeout(callback: () => void, delayMs: number): number;
  clearTimeout(timerId: number): void;
};

export function isRetryableClassificationHttpStatus(status: number): boolean {
  return status === 408 || status === 429 || (status >= 500 && status <= 599);
}

export function shouldRetryClassificationHttpRequest(
  retryCount: number,
): boolean {
  return Number.isInteger(retryCount) && retryCount >= 1 && retryCount <= 3;
}

export function getClassificationDispatchDecision(
  state: ClassificationDispatchState,
): ClassificationDispatchDecision {
  if (
    state.status === "pending" ||
    state.status === "processing_expired" ||
    state.status === "retry_ready"
  ) {
    return { kind: "dispatch" };
  }

  if (
    (state.status === "processing_active" || state.status === "retry_wait") &&
    state.wait_ms !== null &&
    Number.isInteger(state.wait_ms) &&
    state.wait_ms > 0
  ) {
    return { kind: "wait", delayMs: state.wait_ms };
  }

  return { kind: "none" };
}

export class ClassificationRetryTimerRegistry {
  private readonly timers = new Map<
    string,
    { sourceKey: string; timerId: number }
  >();
  private sourceKey: string | null = null;

  setSourceKey(
    sourceKey: string,
    scheduler: ClassificationRetryTimerScheduler,
  ): boolean {
    if (this.sourceKey === sourceKey) return false;
    this.sourceKey = sourceKey;
    for (const [key, timer] of this.timers) {
      if (timer.sourceKey !== sourceKey) {
        scheduler.clearTimeout(timer.timerId);
        this.timers.delete(key);
      }
    }
    return true;
  }

  schedule(
    key: string,
    sourceKey: string,
    delayMs: number,
    callback: () => void,
    scheduler: ClassificationRetryTimerScheduler,
  ): boolean {
    if (this.sourceKey !== sourceKey || this.timers.has(key)) return false;
    const timerId = scheduler.setTimeout(() => {
      const timer = this.timers.get(key);
      if (!timer || timer.timerId !== timerId) return;
      this.timers.delete(key);
      if (this.sourceKey === sourceKey) callback();
    }, delayMs);
    this.timers.set(key, { sourceKey, timerId });
    return true;
  }

  clearAll(scheduler: ClassificationRetryTimerScheduler): void {
    for (const timer of this.timers.values()) {
      scheduler.clearTimeout(timer.timerId);
    }
    this.timers.clear();
  }
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
