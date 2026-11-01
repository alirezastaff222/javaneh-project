"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import {
  ClassificationDispatchGate,
  ClassificationRetryTimerRegistry,
  getClassificationDispatchDecision,
  isRetryableClassificationHttpStatus,
  shouldRetryClassificationHttpRequest,
  type ClassificationDispatchState,
} from "@/lib/ai/mentor/classification-dispatch";

const stateProjectionSchema = z
  .object({
    status: z.enum([
      "missing",
      "not_found",
      "pending",
      "processing_active",
      "processing_expired",
      "current",
      "stale",
      "retry_wait",
      "retry_ready",
      "failed",
    ]),
    current_classification_id: z.string().uuid().nullable(),
    source_stage_1_revision_id: z.string().uuid().nullable(),
    source_stage_2_revision_id: z.string().uuid().nullable(),
    wait_ms: z.number().int().min(0).max(120_000).nullable(),
  })
  .strict();

const resultSchema = z
  .object({
    classification_id: z.string().uuid(),
    taxonomy_version: z.string(),
    primary_axis_id: z.string(),
    secondary_axis_1_id: z.string(),
    secondary_axis_2_id: z.string(),
    primary_percentage: z.number().int().min(0).max(100),
    secondary_1_percentage: z.number().int().min(0).max(100),
    secondary_2_percentage: z.number().int().min(0).max(100),
    primary_rationale: z.string().min(1),
    secondary_1_rationale: z.string().min(1),
    secondary_2_rationale: z.string().min(1),
  })
  .strict()
  .refine(
    (result) =>
      new Set([
        result.primary_axis_id,
        result.secondary_axis_1_id,
        result.secondary_axis_2_id,
      ]).size === 3 &&
      result.primary_percentage +
        result.secondary_1_percentage +
        result.secondary_2_percentage ===
        100 &&
      result.primary_percentage > result.secondary_1_percentage &&
      result.primary_percentage > result.secondary_2_percentage,
  );

const axesSchema = z
  .array(
    z
      .object({
        axis_id: z.string(),
        official_name: z.string(),
        official_definition: z.string(),
      })
      .strict(),
  )
  .length(3);

type Props = {
  supabase: SupabaseClient;
  ideaId: string;
  eligible: boolean;
  triggerVersion: number;
};

type DisplayAxis = {
  id: string;
  name: string;
  rationale: string;
  percentage: number;
  primary: boolean;
};

export default function ClassificationPanel({
  supabase,
  ideaId,
  eligible,
  triggerVersion,
}: Props) {
  const [status, setStatus] = useState<string>("loading");
  const [axes, setAxes] = useState<DisplayAxis[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [dispatchState, setDispatchState] =
    useState<ClassificationDispatchState | null>(null);
  const loadVersion = useRef(0);
  const handledTriggerVersion = useRef(triggerVersion);
  const loadClassificationRef = useRef<() => Promise<void>>(async () => undefined);
  const dispatchGate = useRef(new ClassificationDispatchGate());
  const retryTimers = useRef(new ClassificationRetryTimerRegistry());
  const stateRetryTimer = useRef<number | null>(null);
  const networkRetryCounts = useRef(new Map<string, number>());

  const loadClassification = useCallback(async () => {
    const requestVersion = ++loadVersion.current;
    const { data: projection, error: stateError } = await supabase.rpc(
      "get_own_idea_classification_status",
      { p_idea_id: ideaId },
    );
    if (requestVersion !== loadVersion.current) return;
    if (stateError) {
      setDispatchState(null);
      setStatus("unavailable");
      setError("وضعیت دسته‌بندی از پایگاه داده دریافت نشد.");
      return;
    }
    setError(null);
    setAxes([]);
    const parsedState = stateProjectionSchema.safeParse(projection);
    if (!parsedState.success) {
      setDispatchState(null);
      setStatus("unavailable");
      setError("ساختار وضعیت دسته‌بندی معتبر نیست.");
      return;
    }
    if (
      parsedState.data.status === "missing" ||
      parsedState.data.status === "not_found" ||
      !parsedState.data.source_stage_1_revision_id ||
      !parsedState.data.source_stage_2_revision_id
    ) {
      setDispatchState(null);
      setStatus(eligible ? "pending" : "not_ready");
      return;
    }

    setDispatchState({
      status: parsedState.data.status,
      wait_ms: parsedState.data.wait_ms,
      source_stage_1_revision_id: parsedState.data.source_stage_1_revision_id,
      source_stage_2_revision_id: parsedState.data.source_stage_2_revision_id,
    });
    setStatus(
      parsedState.data.status === "processing_active" ||
        parsedState.data.status === "processing_expired"
        ? "processing"
        : parsedState.data.status === "retry_wait" ||
            parsedState.data.status === "retry_ready"
          ? "failed"
          : parsedState.data.status,
    );
    if (
      parsedState.data.status !== "current" ||
      !parsedState.data.current_classification_id
    ) {
      return;
    }

    const { data: resultRow, error: resultError } = await supabase
      .from("idea_classification_results")
      .select(
        "classification_id,taxonomy_version,primary_axis_id,secondary_axis_1_id,secondary_axis_2_id,primary_percentage,secondary_1_percentage,secondary_2_percentage,primary_rationale,secondary_1_rationale,secondary_2_rationale",
      )
      .eq("classification_id", parsedState.data.current_classification_id)
      .maybeSingle();
    if (requestVersion !== loadVersion.current) return;
    const parsedResult = resultSchema.safeParse(resultRow);
    if (resultError || !parsedResult.success) {
      setStatus("stale");
      setError("دسته‌بندی جاری در دسترس نیست و برای جلوگیری از نمایش نتیجه قدیمی پنهان شده است.");
      return;
    }

    const result = parsedResult.data;
    const selectedIds = [
      result.primary_axis_id,
      result.secondary_axis_1_id,
      result.secondary_axis_2_id,
    ];
    const { data: axisRows, error: axesError } = await supabase
      .from("thematic_axes")
      .select("axis_id,official_name,official_definition")
      .eq("taxonomy_version", result.taxonomy_version)
      .in("axis_id", selectedIds);
    if (requestVersion !== loadVersion.current) return;
    const parsedAxes = axesSchema.safeParse(axisRows);
    if (axesError || !parsedAxes.success) {
      setStatus("stale");
      setError("اطلاعات رسمی محورهای دسته‌بندی در دسترس نیست.");
      return;
    }

    const axisById = new Map(
      parsedAxes.data.map((axis) => [axis.axis_id, axis]),
    );
    const displayAxes: DisplayAxis[] = [
      {
        id: result.primary_axis_id,
        name: axisById.get(result.primary_axis_id)?.official_name ?? "",
        rationale: result.primary_rationale,
        percentage: result.primary_percentage,
        primary: true,
      },
      {
        id: result.secondary_axis_1_id,
        name: axisById.get(result.secondary_axis_1_id)?.official_name ?? "",
        rationale: result.secondary_1_rationale,
        percentage: result.secondary_1_percentage,
        primary: false,
      },
      {
        id: result.secondary_axis_2_id,
        name: axisById.get(result.secondary_axis_2_id)?.official_name ?? "",
        rationale: result.secondary_2_rationale,
        percentage: result.secondary_2_percentage,
        primary: false,
      },
    ];
    if (displayAxes.some((axis) => !axis.name)) {
      setStatus("stale");
      setError("اطلاعات رسمی محورهای دسته‌بندی کامل نیست.");
      return;
    }
    setAxes(displayAxes);
  }, [eligible, ideaId, supabase]);

  useEffect(() => {
    loadClassificationRef.current = loadClassification;
  }, [loadClassification]);

  const dispatchClassification = useCallback(
    async (key: string, sourceKey: string) => {
      if (!eligible || !dispatchGate.current.begin(key)) return;
      let retryableRequestFailure = true;
      let requestError: string | null = null;
      try {
        const response = await fetch("/api/classification", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ideaId }),
        });
        if (!response.ok) {
          retryableRequestFailure = isRetryableClassificationHttpStatus(
            response.status,
          );
          throw new Error("Classification request could not be completed.");
        }
        const body: unknown = await response.json();
        const responseSchema = z.object({ status: z.string() }).strict();
        if (!responseSchema.safeParse(body).success) {
          throw new Error("Classification status response was invalid.");
        }
        retryableRequestFailure = false;
        networkRetryCounts.current.delete(sourceKey);
      } catch {
        requestError =
          "دسته‌بندی فعلاً دریافت نشد؛ تأیید مرحله و ادامه کار شما حفظ شده است.";
        const retryCount = (networkRetryCounts.current.get(sourceKey) ?? 0) + 1;
        networkRetryCounts.current.set(sourceKey, retryCount);
        if (
          retryableRequestFailure &&
          shouldRetryClassificationHttpRequest(retryCount)
        ) {
          retryTimers.current.schedule(
            `${sourceKey}:${key}`,
            sourceKey,
            30_000,
            () => {
              dispatchGate.current.allowRetry(key);
              void loadClassificationRef.current();
            },
            window,
          );
        }
      } finally {
        dispatchGate.current.finish();
        await loadClassificationRef.current();
        if (requestError) setError(requestError);
      }
    },
    [eligible, ideaId],
  );

  useEffect(() => {
    void Promise.resolve()
      .then(loadClassification)
      .catch(() => {
        setDispatchState(null);
        setStatus("unavailable");
        setError("وضعیت دسته‌بندی از پایگاه داده دریافت نشد.");
      });
  }, [loadClassification]);

  useEffect(() => {
    const sourceKey = dispatchState
      ? `${ideaId}:${dispatchState.source_stage_1_revision_id}:${dispatchState.source_stage_2_revision_id}`
      : `${ideaId}:missing`;
    if (retryTimers.current.setSourceKey(sourceKey, window)) {
      networkRetryCounts.current.clear();
    }
    if (stateRetryTimer.current !== null) {
      window.clearTimeout(stateRetryTimer.current);
      stateRetryTimer.current = null;
    }
    if (!eligible || !dispatchState) return;

    const decision = getClassificationDispatchDecision(dispatchState);
    const key = [
      ideaId,
      dispatchState.status,
      dispatchState.source_stage_1_revision_id ?? "",
      dispatchState.source_stage_2_revision_id ?? "",
    ].join(":");
    if (decision.kind === "dispatch") {
      void Promise.resolve().then(() => dispatchClassification(key, sourceKey));
      return;
    }
    if (decision.kind === "wait") {
      stateRetryTimer.current = window.setTimeout(
        () => void loadClassificationRef.current(),
        decision.delayMs,
      );
    }
    return () => {
      if (stateRetryTimer.current !== null) {
        window.clearTimeout(stateRetryTimer.current);
        stateRetryTimer.current = null;
      }
    };
  }, [dispatchClassification, dispatchState, eligible, ideaId]);

  useEffect(
    () => () => {
      if (stateRetryTimer.current !== null) {
        window.clearTimeout(stateRetryTimer.current);
      }
      retryTimers.current.clearAll(window);
      networkRetryCounts.current.clear();
    },
    [],
  );

  useEffect(() => {
    if (triggerVersion === 0 || handledTriggerVersion.current === triggerVersion) {
      return;
    }
    handledTriggerVersion.current = triggerVersion;
    retryTimers.current.setSourceKey(
      `confirmation:${ideaId}:${triggerVersion}`,
      window,
    );
    networkRetryCounts.current.clear();
    void loadClassificationRef.current();
  }, [ideaId, triggerVersion]);

  const retryScheduled =
    dispatchState?.status === "retry_wait" ||
    dispatchState?.status === "retry_ready";

  return (
    <section
      aria-labelledby="idea-classification-title"
      dir="rtl"
      className="mt-6 rounded-2xl border border-foreground/10 bg-white p-5 shadow-sm dark:bg-neutral-950 sm:p-6"
    >
      <h3 id="idea-classification-title" className="text-lg font-semibold">
        دسته‌بندی موضوعی ایده
      </h3>
      <p className="mt-2 text-sm leading-7 text-foreground/65">
        این تحلیل پس از تأیید مرحله‌های ۱ و ۲ تهیه می‌شود. درصدها میزان ارتباط
        موضوعی ایده را نشان می‌دهند و امتیاز رقابتی یا امتیاز بازی‌وارسازی نیستند.
      </p>

      {status === "loading" && (
        <p role="status" className="mt-4 text-sm text-foreground/65">
          در حال دریافت وضعیت دسته‌بندی…
        </p>
      )}
      {status === "not_ready" && (
        <p role="status" className="mt-4 text-sm text-foreground/65">
          دسته‌بندی پس از تأیید هر دو مرحله نخست آماده می‌شود.
        </p>
      )}
      {status === "pending" && (
        <p role="status" className="mt-4 text-sm text-amber-800 dark:text-amber-200">
          دسته‌بندی در انتظار انجام یا به‌روزرسانی است.
        </p>
      )}
      {status === "processing" && (
        <p role="status" className="mt-4 text-sm text-amber-800 dark:text-amber-200">
          دسته‌بندی در حال آماده‌سازی است.
        </p>
      )}
      {status === "stale" && (
        <p role="status" className="mt-4 text-sm text-amber-800 dark:text-amber-200">
          اطلاعات تأییدشده تغییر کرده است؛ نتیجه قبلی نمایش داده نمی‌شود تا دسته‌بندی
          به‌روز شود.
        </p>
      )}
      {status === "failed" && (
        <p role="status" className="mt-4 text-sm text-amber-800 dark:text-amber-200">
          {retryScheduled
            ? "دسته‌بندی با خطای موقت روبه‌رو شد و پس از وقفه‌ای کوتاه دوباره تلاش می‌شود؛ تأیید مرحله‌ها و ادامه کار شما بدون تغییر باقی می‌ماند."
            : "دسته‌بندی فعلاً در دسترس نیست و تلاش خودکار بیشتری انجام نمی‌شود؛ تأیید مرحله‌ها و ادامه کار شما بدون تغییر باقی می‌ماند."}
        </p>
      )}
      {status === "unavailable" && (
        <p role="alert" className="mt-4 text-sm text-red-700 dark:text-red-300">
          وضعیت دسته‌بندی دریافت نشد؛ لطفاً بعداً دوباره صفحه را باز کنید.
        </p>
      )}
      {error && status !== "unavailable" && (
        <p role="status" className="mt-3 text-sm text-amber-800 dark:text-amber-200">
          {error}
        </p>
      )}

      {status === "current" && axes.length === 3 && (
        <div className="mt-5 space-y-4">
          {axes.map((axis) => (
            <article
              key={axis.id}
              className="rounded-xl border border-foreground/10 p-4"
            >
              <div className="flex flex-wrap items-start justify-between gap-2">
                <h4 className="max-w-3xl font-medium leading-7">
                  {axis.name}
                  {axis.primary && (
                    <span className="ms-2 rounded-full bg-foreground/10 px-2 py-1 text-xs">
                      محور اصلی
                    </span>
                  )}
                </h4>
                <span className="shrink-0 font-semibold tabular-nums">
                  {axis.percentage}٪
                </span>
              </div>
              <div
                role="img"
                aria-label={`میزان ارتباط موضوعی: ${axis.percentage} درصد`}
                className="mt-3 h-2 overflow-hidden rounded-full bg-foreground/10"
              >
                <div
                  className="h-full rounded-full bg-emerald-600 dark:bg-emerald-400"
                  style={{ width: `${axis.percentage}%` }}
                />
              </div>
              <p className="mt-3 text-sm leading-7 text-foreground/70">
                {axis.rationale}
              </p>
            </article>
          ))}
        </div>
      )}
    </section>
  );
}
