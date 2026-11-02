"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { User } from "@supabase/supabase-js";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import {
  IDEA_STAGE_FALLBACK_GUIDANCE,
  IDEA_STAGES,
  type IdeaStageKey,
} from "@/lib/ideas/stages";
import {
  IDEA_QUOTA_LIMIT,
  canCreateIdea,
  getAvailableIdeaSlots,
  isIdeaPortfolioItem,
  type HumanEvaluationStatus,
  type IdeaPortfolioItem,
  type StageStatus,
} from "@/lib/ideas/portfolio";
import type { ParticipantWorkspace } from "@/lib/ideas/participant-workspace";
import { parseDossierHistory } from "@/lib/ideas/dossier-history";
import {
  mentorFailureResponseSchema,
  mentorSuccessResponseSchema,
} from "@/lib/ai/mentor/contracts";
import { shouldDispatchAfterConfirmation } from "@/lib/ai/mentor/classification-dispatch";
import ClassificationPanel from "./classification-panel";
import ParticipantScorecard from "./participant-scorecard";
import MilestoneEvaluationControls from "./milestone-evaluation-controls";
import JuryScoreSummary from "./jury-score-summary";
import FinalResultSummary from "./final-result-summary";
import DossierPreview, {
  DossierPreviewEntryPoint,
} from "./dossier-preview";
import DossierHistoryInspector, {
  DossierHistoryEntryPoint,
  type DossierHistoryViewState,
} from "./dossier-history-inspector";

type Idea = IdeaPortfolioItem;

type IdeaDraftData = Record<string, unknown> & {
  content?: string;
};

type IdeaStage = {
  stage_number: number;
  stage_key: IdeaStageKey;
  data: IdeaDraftData;
  status: StageStatus;
  confirmed_at: string | null;
  updated_at: string;
};

type PendingSave = {
  ideaId: string;
  stageNumber: number;
  requestId: string;
  expectedRevision: number;
  content: string;
  stageData: IdeaDraftData;
  submittedEdit: boolean;
};

type LocalDraftRecovery = {
  stageNumber: number;
  content: string;
  revision: number;
};

type DraftConflict = {
  stageNumber: number;
  serverContent: string;
  serverRevision: number;
};

type Notice = {
  message: string;
  kind: "success" | "error" | "info";
};

type MentorUiStatus =
  | "checking"
  | "available"
  | "not_configured"
  | "temporarily_unavailable"
  | "recovery_eligible"
  | "recovery_in_progress"
  | "restored";

const knownStageStatuses = new Set<StageStatus>([
  "not_started",
  "in_progress",
  "pending_confirmation",
  "confirmed",
  "needs_revision",
  "locked",
]);
const dossierEditingWindowMs = 168 * 60 * 60 * 1000;

function localDraftKey(userId: string, ideaId: string): string {
  return `javaneh.unsynced_draft:${userId}:${ideaId}`;
}

function parseLocalDraftRecovery(value: string | null): LocalDraftRecovery | null {
  if (!value) return null;
  try {
    const parsed: unknown = JSON.parse(value);
    if (
      isRecord(parsed) &&
      Number.isInteger(parsed.stageNumber) &&
      Number(parsed.stageNumber) >= 1 &&
      Number(parsed.stageNumber) <= 6 &&
      typeof parsed.content === "string" &&
      Number.isInteger(parsed.revision) &&
      Number(parsed.revision) > 0
    ) {
      return {
        stageNumber: Number(parsed.stageNumber),
        content: parsed.content,
        revision: Number(parsed.revision),
      };
    }
  } catch {
    return null;
  }
  return null;
}

function isTransientSaveFailure(error: { code?: string; message?: string }): boolean {
  return (
    ["40001", "40P01", "55P03", "PGRST000", "PGRST002", "PGRST003"].includes(
      error.code ?? "",
    ) ||
    /fetch|network|connection|timeout|temporarily unavailable|gateway|server error/i.test(
      error.message ?? "",
    )
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseOutcome(value: unknown): Record<string, unknown> | null {
  return isRecord(value) && typeof value.outcome === "string" ? value : null;
}

function readContent(stage: IdeaStage): string {
  return stage.data.content ?? "";
}

function outcomeMessage(outcome: string): string {
  switch (outcome) {
    case "quota_exceeded":
      return "در حال حاضر حداکثر سه ایده فعال مجاز است. برای ایجاد ایده جدید، ابتدا یکی از ایده‌های قبلی را حذف کنید.";
    case "already_deleted":
      return "این درخواست قبلاً حذف شده است و امکان ایجاد دوباره آن وجود ندارد.";
    case "stale_revision":
      return "نسخه ایده در دستگاه دیگری تغییر کرده است. آخرین نسخه را بارگذاری کنید و تغییرات خود را دوباره بررسی کنید.";
    case "idempotency_key_reuse":
      return "شناسه این درخواست قبلاً برای محتوای دیگری استفاده شده است. صفحه را تازه‌سازی کنید و دوباره تلاش کنید.";
    case "not_found_or_not_owned":
      return "این ایده در دسترس نیست یا حذف شده است.";
    case "invalid_state":
      return "این مرحله در وضعیت فعلی قابل ویرایش یا تأیید نیست.";
    case "invalid_input":
      return "اطلاعات ارسالی معتبر نیست. متن مرحله را بررسی و دوباره تلاش کنید.";
    case "incomplete":
      return "همه شش مرحله باید پیش از ثبت نهایی تأیید شده باشند.";
    case "editing_window_expired":
      return "مهلت ویرایش معمول این پرونده به پایان رسیده است.";
    case "evaluation_history_exists":
      return "این ایده دارای سابقه ارزیابی یا امتیاز است و از این مسیر قابل حذف نیست.";
    default:
      return "پاسخ پایگاه داده قابل شناسایی نبود. وضعیت ایده را دوباره بارگذاری کنید.";
  }
}

function getErrorMessage(error: { message?: string; code?: string }): string {
  const message = error.message ?? "";
  if (
    /jwt|token.*expired|authentication required|unauthorized/i.test(message)
  ) {
    return "نشست شما معتبر نیست یا پایان یافته است. دوباره وارد حساب کاربری شوید و این صفحه را باز کنید.";
  }
  if (error.code === "42501") {
    return "پایگاه داده دسترسی این عملیات را رد کرد. نشست و دسترسی ایده را بررسی کنید.";
  }
  if (/fetch|network|connection|timeout/i.test(message)) {
    return "ارتباط با پایگاه داده برقرار نشد. اتصال را بررسی کنید و همان درخواست را دوباره امتحان کنید.";
  }
  return "پایگاه داده نتوانست این عملیات را انجام دهد. وضعیت را بررسی و دوباره تلاش کنید.";
}

function createRequestId(): string {
  return globalThis.crypto.randomUUID();
}

function updateIdeaLocation(ideaId: string, stageNumber?: number): void {
  const params = new URLSearchParams({ idea: ideaId });
  if (stageNumber !== undefined) {
    params.set("stage", String(stageNumber));
  }
  window.history.replaceState(null, "", `/ideas?${params.toString()}`);
}

function statusLabel(status: StageStatus): string {
  switch (status) {
    case "in_progress":
      return "در حال انجام";
    case "not_started":
      return "شروع‌نشده";
    case "pending_confirmation":
      return "در انتظار تأیید شما";
    case "confirmed":
      return "تأییدشده";
    case "needs_revision":
      return "نیازمند بازبینی";
    case "locked":
      return "قفل‌شده";
  }
}

function stageStatusLabel(stage: IdeaStage, idea: Idea): string {
  if (stage.stage_number === 7 && idea.status === "submitted") {
    return humanEvaluationStatusLabel(idea.evaluationStatus);
  }
  return statusLabel(stage.status);
}

function humanEvaluationStatusLabel(
  status: HumanEvaluationStatus | undefined,
): string {
  switch (status) {
    case "in_progress":
      return "ارزیابی انسانی در حال انجام است";
    case "completed":
      return "ارزیابی انسانی تکمیل شده است؛ این وضعیت اعلام نتیجه رقابت نیست";
    default:
      return "در انتظار تخصیص یا آغاز بررسی انسانی";
  }
}

function statusStyle(status: StageStatus): string {
  switch (status) {
    case "confirmed":
      return "bg-green-100 text-green-900 dark:bg-green-950 dark:text-green-200";
    case "in_progress":
      return "bg-blue-100 text-blue-900 dark:bg-blue-950 dark:text-blue-200";
    case "not_started":
      return "bg-slate-100 text-slate-800 dark:bg-slate-900 dark:text-slate-200";
    case "pending_confirmation":
      return "bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200";
    case "needs_revision":
      return "bg-orange-100 text-orange-900 dark:bg-orange-950 dark:text-orange-200";
    case "locked":
      return "border border-dashed border-foreground/20 bg-foreground/[0.03] text-foreground/60";
  }
}

export default function IdeasPage({
  initialWorkspace,
}: {
  initialWorkspace: ParticipantWorkspace;
}) {
  const supabase = useMemo(() => createClient(), []);
  const initialProfile =
    initialWorkspace.kind === "authenticated" ? initialWorkspace.profile : null;
  const [user, setUser] = useState<User | null>(null);
  const [authLoading, setAuthLoading] = useState(true);
  const [authError, setAuthError] = useState<string | null>(null);
  const [ideas, setIdeas] = useState<Idea[]>(
    initialWorkspace.kind === "authenticated" ? initialWorkspace.ideas : [],
  );
  const [ideasLoading, setIdeasLoading] = useState(false);
  const [ideasLoaded, setIdeasLoaded] = useState(
    initialWorkspace.kind === "authenticated",
  );
  const [ideasError, setIdeasError] = useState<string | null>(
    initialWorkspace.kind === "error"
      ? "فضای کار شما بارگذاری نشد. دوباره تلاش کنید."
      : null,
  );
  const [selectedIdea, setSelectedIdea] = useState<Idea | null>(null);
  const [dossierPreviewOpen, setDossierPreviewOpen] = useState(false);
  const [dossierHistoryOpen, setDossierHistoryOpen] = useState(false);
  const [dossierHistoryState, setDossierHistoryState] =
    useState<DossierHistoryViewState>({ kind: "loading" });
  const [stagesLoading, setStagesLoading] = useState(false);
  const [stagesError, setStagesError] = useState<string | null>(null);
  const [ideaStages, setIdeaStages] = useState<IdeaStage[]>([]);
  const [drafts, setDrafts] = useState<Record<number, string>>({});
  const [currentStage, setCurrentStage] = useState(1);
  const [revision, setRevision] = useState<number | null>(null);
  const [creating, setCreating] = useState(false);
  const [saving, setSaving] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [stepSaving, setStepSaving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [pendingCreateRequestId, setPendingCreateRequestId] = useState<
    string | null
  >(null);
  const [createRequestStorageReady, setCreateRequestStorageReady] =
    useState(false);
  const [pendingCreateStorageError, setPendingCreateStorageError] = useState<
    string | null
  >(null);
  const [pendingSave, setPendingSave] = useState<PendingSave | null>(null);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [syncStatus, setSyncStatus] = useState<
    "saved" | "pending" | "failed"
  >("saved");
  const [localRecoveryError, setLocalRecoveryError] = useState<string | null>(
    null,
  );
  const [draftConflict, setDraftConflict] = useState<DraftConflict | null>(null);
  const [isOnline, setIsOnline] = useState(true);
  const [clockNow, setClockNow] = useState(() => Date.now());
  const [editingWindowExpired, setEditingWindowExpired] = useState(false);
  const [mentorAvailability, setMentorAvailability] =
    useState<MentorUiStatus>("checking");
  const [mentorFallbackActive, setMentorFallbackActive] = useState(false);
  const [mentorRetryAfterSeconds, setMentorRetryAfterSeconds] = useState<
    number | null
  >(null);
  const [mentorQuestions, setMentorQuestions] = useState<Record<number, string>>(
    {},
  );
  const [mentorSuggestions, setMentorSuggestions] = useState<
    Record<number, string>
  >({});
  const [mentorErrors, setMentorErrors] = useState<Record<number, string>>({});
  const [mentorBusyStage, setMentorBusyStage] = useState<number | null>(null);
  const [classificationTriggerVersion, setClassificationTriggerVersion] =
    useState(0);

  const createRequestRef = useRef<string | null>(null);
  const createBusyRef = useRef(false);
  const saveBusyRef = useRef(false);
  const confirmBusyRef = useRef(false);
  const stepBusyRef = useRef(false);
  const deleteBusyRef = useRef(false);
  const submitBusyRef = useRef(false);
  const submissionRequestIds = useRef(new Map<string, string>());
  const pendingSaveRef = useRef<PendingSave | null>(null);
  const handledInitialSelection = useRef(false);
  const activeUserId = useRef<string | null>(
    initialWorkspace.kind === "authenticated"
      ? initialWorkspace.profile.id
      : null,
  );
  const stageLoadVersion = useRef(0);
  const dossierHistoryLoadVersion = useRef(0);

  const loadDossierHistory = useCallback(async (ideaId: string): Promise<void> => {
    const requestVersion = ++dossierHistoryLoadVersion.current;
    setDossierHistoryState({ kind: "loading" });
    try {
      const response = await fetch(
        `/api/ideas/history?ideaId=${encodeURIComponent(ideaId)}`,
        { method: "GET", cache: "no-store" },
      );
      if (!response.ok) throw new Error("History request failed.");
      const payload: unknown = await response.json();
      const history = isRecord(payload)
        ? parseDossierHistory(payload.history)
        : null;
      if (!history) throw new Error("History response was invalid.");
      if (requestVersion === dossierHistoryLoadVersion.current) {
        setDossierHistoryState({ kind: "loaded", history });
      }
    } catch {
      if (requestVersion === dossierHistoryLoadVersion.current) {
        setDossierHistoryState({ kind: "error" });
      }
    }
  }, []);

  function closeDossierHistory(): void {
    dossierHistoryLoadVersion.current += 1;
    setDossierHistoryOpen(false);
  }

  function toggleDossierHistory(): void {
    if (!selectedIdea || selectedIdea.status !== "submitted") return;
    if (dossierHistoryOpen) {
      closeDossierHistory();
      return;
    }
    setDossierHistoryOpen(true);
    void loadDossierHistory(selectedIdea.id);
  }

  const refreshMentorAvailability = useCallback(async () => {
    try {
      const response = await fetch("/api/mentor", {
        method: "GET",
        cache: "no-store",
      });
      const body: unknown = await response.json();
      const availableStatuses = [
        "available",
        "not_configured",
        "temporarily_unavailable",
        "recovery_eligible",
        "recovery_in_progress",
      ] as const;
      const status = isRecord(body)
        ? availableStatuses.find((candidate) => candidate === body.status)
        : undefined;
      if (
        isRecord(body) &&
        status
      ) {
        setMentorAvailability(status);
        setMentorRetryAfterSeconds(
          Number.isInteger(body.retryAfterSeconds)
            ? Number(body.retryAfterSeconds)
            : null,
        );
        if (body.status !== "available") setMentorFallbackActive(true);
        return;
      }
      setMentorAvailability("temporarily_unavailable");
      setMentorFallbackActive(true);
    } catch {
      setMentorAvailability("temporarily_unavailable");
      setMentorFallbackActive(true);
    }
  }, []);

  useEffect(() => {
    if (!user?.id) return;
    const timer = window.setTimeout(() => {
      void refreshMentorAvailability();
    }, 0);
    return () => window.clearTimeout(timer);
  }, [user?.id, refreshMentorAvailability]);

  const refreshIdeas = useCallback(async (): Promise<Idea[] | null> => {
    const requestUserId = activeUserId.current;
    if (!requestUserId) return null;
    setIdeasLoading(true);
    setIdeasError(null);
    try {
      const response = await fetch("/api/ideas", {
        method: "GET",
        cache: "no-store",
      });
      if (activeUserId.current !== requestUserId) return null;
      if (!response.ok) {
        setIdeasLoaded(false);
        setIdeasError(
          response.status === 401
            ? "نشست شما معتبر نیست یا پایان یافته است. صفحه را تازه‌سازی کنید."
            : "فضای کار شما از پایگاه داده بارگذاری نشد. دوباره تلاش کنید.",
        );
        return null;
      }

      const payload: unknown = await response.json();
      if (
        !isRecord(payload) ||
        !isRecord(payload.profile) ||
        payload.profile.id !== requestUserId ||
        (payload.profile.email !== null &&
          typeof payload.profile.email !== "string") ||
        !Array.isArray(payload.ideas) ||
        !payload.ideas.every(isIdeaPortfolioItem)
      ) {
        setIdeasLoaded(false);
        setIdeasError("اطلاعات فضای کار از سرور معتبر نبود.");
        return null;
      }

      const ownedIdeas = payload.ideas;
      setIdeas(ownedIdeas);
      setIdeasLoaded(true);
      return ownedIdeas;
    } catch {
      setIdeasLoaded(false);
      setIdeasError("ارتباط با سرور برقرار نشد. اتصال را بررسی و دوباره تلاش کنید.");
      return null;
    } finally {
      if (activeUserId.current === requestUserId) setIdeasLoading(false);
    }
  }, []);

  const loadStages = useCallback(
    async (idea: Idea): Promise<IdeaStage[] | null> => {
      const requestVersion = ++stageLoadVersion.current;
      setStagesLoading(true);
      setStagesError(null);
      setDraftConflict(null);
      setEditingWindowExpired(false);
      setSyncStatus("saved");
      setIdeaStages([]);
      setDrafts({});
      setRevision(idea.revision);

      const { data, error } = await supabase
        .from("idea_stages")
        .select("stage_number,stage_key,data,status,confirmed_at,updated_at")
        .eq("idea_id", idea.id)
        .order("stage_number", { ascending: true });
      if (requestVersion !== stageLoadVersion.current) return null;
      setStagesLoading(false);

      if (error) {
        setStagesError(getErrorMessage(error));
        return null;
      }

      if (
        !Array.isArray(data) ||
        data.length !== 7 ||
        data.some(
          (stage, index) =>
            !isRecord(stage) ||
            stage.stage_number !== index + 1 ||
            stage.stage_key !== IDEA_STAGES[index]?.key ||
            !isRecord(stage.data) ||
            (stage.data.content !== undefined &&
              typeof stage.data.content !== "string") ||
            typeof stage.status !== "string" ||
            !knownStageStatuses.has(stage.status as StageStatus) ||
            (stage.confirmed_at !== null &&
              typeof stage.confirmed_at !== "string") ||
            typeof stage.updated_at !== "string",
        )
      ) {
        setStagesError("وضعیت مراحل ایده معتبر نیست. لطفاً صفحه را تازه‌سازی کنید.");
        return null;
      }

      const loadedStages = data as IdeaStage[];
      if (
        loadedStages[6].status !== "locked" ||
        Object.keys(loadedStages[6].data).length !== 0
      ) {
        setStagesError("مرحله هفتم باید قفل و خالی باقی بماند.");
        return null;
      }

      const loadedDrafts = Object.fromEntries(
        loadedStages.map((stage) => [
          stage.stage_number,
          readContent(stage),
        ]),
      );
      let recoveredStage = idea.current_step;
      const recoveryKey = activeUserId.current
        ? localDraftKey(activeUserId.current, idea.id)
        : null;
      try {
        const recovery = parseLocalDraftRecovery(
          recoveryKey ? window.localStorage.getItem(recoveryKey) : null,
        );
        if (recovery) {
          const serverStage = loadedStages[recovery.stageNumber - 1];
          if (readContent(serverStage) === recovery.content) {
            if (recoveryKey) window.localStorage.removeItem(recoveryKey);
          } else if (recovery.revision === idea.revision) {
            loadedDrafts[recovery.stageNumber] = recovery.content;
            recoveredStage = recovery.stageNumber;
            setSyncStatus("pending");
          } else {
            loadedDrafts[recovery.stageNumber] = recovery.content;
            recoveredStage = recovery.stageNumber;
            setDraftConflict({
              stageNumber: recovery.stageNumber,
              serverContent: readContent(serverStage),
              serverRevision: idea.revision,
            });
            setSyncStatus("failed");
          }
        }
        setLocalRecoveryError(null);
      } catch {
        setLocalRecoveryError(
          "پیش‌نویس محلی خوانده نشد؛ تغییرات همگام‌نشده ممکن است بازیابی نشوند.",
        );
        setSyncStatus("failed");
      }

      setIdeaStages(loadedStages);
      setDrafts(loadedDrafts);
      const activeStage =
        loadedDrafts[recoveredStage] !== undefined
          ? loadedStages[recoveredStage - 1]
          : null;
      const selectedActiveStage = activeStage ??
        loadedStages.find(
          (stage) =>
            stage.stage_number === idea.current_step &&
            (stage.status !== "locked" || stage.stage_number === 7),
        ) ??
        loadedStages.find((stage) => stage.status === "in_progress") ??
        loadedStages.find((stage) => stage.status !== "locked") ??
        loadedStages[0];
      setCurrentStage(selectedActiveStage.stage_number);
      updateIdeaLocation(idea.id, selectedActiveStage.stage_number);
      return loadedStages;
    },
    [supabase],
  );

  useEffect(() => {
    let active = true;
    function updateAuthenticatedUser(nextUser: User | null): void {
      if (activeUserId.current !== (nextUser?.id ?? null)) {
        const previousUserId = activeUserId.current;
        if (previousUserId) {
          try {
            const prefix = `javaneh.unsynced_draft:${previousUserId}:`;
            for (const key of Object.keys(window.localStorage)) {
              if (key.startsWith(prefix)) window.localStorage.removeItem(key);
            }
            setLocalRecoveryError(null);
          } catch {
            setLocalRecoveryError(
              "پیش‌نویس محلی هنگام خروج پاک نشد؛ داده‌های مرورگر را پاک کنید.",
            );
          }
        }
        activeUserId.current = nextUser?.id ?? null;
        stageLoadVersion.current += 1;
        setIdeas([]);
        setIdeasLoading(false);
        setIdeasLoaded(false);
        setIdeasError(null);
        setSelectedIdea(null);
        setDossierPreviewOpen(false);
        dossierHistoryLoadVersion.current += 1;
        setDossierHistoryOpen(false);
        setDossierHistoryState({ kind: "loading" });
        setStagesLoading(false);
        setIdeaStages([]);
        setDrafts({});
        setRevision(null);
        setPendingCreateRequestId(null);
        setCreateRequestStorageReady(false);
        setPendingCreateStorageError(null);
        setPendingSave(null);
        setSyncStatus("saved");
        setDraftConflict(null);
        createRequestRef.current = null;
        pendingSaveRef.current = null;
        createBusyRef.current = false;
        saveBusyRef.current = false;
        confirmBusyRef.current = false;
        setCreating(false);
        setSaving(false);
        setConfirming(false);
        setStepSaving(false);
        setDeleting(false);
        setSubmitting(false);
        stepBusyRef.current = false;
        deleteBusyRef.current = false;
        submitBusyRef.current = false;
        submissionRequestIds.current.clear();
        handledInitialSelection.current = false;
        window.history.replaceState(null, "", "/ideas");
      }
      setUser(nextUser);
    }

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      if (!active) return;
      updateAuthenticatedUser(session?.user ?? null);
      setAuthLoading(false);
      setAuthError(null);
    });

    void supabase.auth
      .getUser()
      .then(({ data, error }) => {
        if (!active) return;
        if (error) {
          setAuthError(getErrorMessage(error));
          updateAuthenticatedUser(null);
        } else {
          setAuthError(null);
          updateAuthenticatedUser(data.user);
        }
        setAuthLoading(false);
      })
      .catch(() => {
        if (!active) return;
        setAuthError("وضعیت ورود بررسی نشد. اتصال را بررسی و صفحه را تازه‌سازی کنید.");
        setAuthLoading(false);
      });

    return () => {
      active = false;
      subscription.unsubscribe();
    };
  }, [supabase]);

  useEffect(() => {
    function updateOnlineStatus(): void {
      setIsOnline(window.navigator.onLine);
    }
    updateOnlineStatus();
    window.addEventListener("online", updateOnlineStatus);
    window.addEventListener("offline", updateOnlineStatus);
    const clockTimer = window.setInterval(() => setClockNow(Date.now()), 30_000);
    return () => {
      window.removeEventListener("online", updateOnlineStatus);
      window.removeEventListener("offline", updateOnlineStatus);
      window.clearInterval(clockTimer);
    };
  }, []);

  useEffect(() => {
    if (!user) return;
    const storageKey = `javaneh.pending_create_request_id:${user.id}`;
    let active = true;
    void Promise.resolve().then(() => {
      if (!active) return;
      try {
        const storedRequestId = window.sessionStorage.getItem(storageKey);
        createRequestRef.current = storedRequestId;
        setPendingCreateRequestId(storedRequestId);
        setPendingCreateStorageError(null);
      } catch {
        setPendingCreateStorageError(
          "ذخیره امن شناسه تلاش ایجاد در این مرورگر در دسترس نیست؛ برای جلوگیری از ایجاد تکراری، فعلاً امکان ایجاد ایده وجود ندارد.",
        );
      } finally {
        setCreateRequestStorageReady(true);
      }
    });
    return () => {
      active = false;
    };
  }, [user]);

  useEffect(() => {
    if (!user) return;
    if (ideasLoaded) return;
    let active = true;
    void Promise.resolve().then(() => {
      if (active) void refreshIdeas();
    });
    return () => {
      active = false;
    };
  }, [user, ideasLoaded, refreshIdeas]);

  useEffect(() => {
    if (!user || !ideasLoaded || ideasLoading || handledInitialSelection.current) return;
    handledInitialSelection.current = true;
    let active = true;
    void Promise.resolve().then(() => {
      if (!active) return;
      const requestedId = new URLSearchParams(window.location.search).get("idea");
      if (!requestedId) return;
      const ownedIdea = ideas.find((idea) => idea.id === requestedId);
      if (ownedIdea) {
        setSelectedIdea(ownedIdea);
      } else {
        setNotice({
          kind: "error",
          message: "این ایده در دسترس نیست یا حذف شده است.",
        });
        window.history.replaceState(null, "", "/ideas");
      }
    });
    return () => {
      active = false;
    };
  }, [user, ideas, ideasLoaded, ideasLoading]);

  useEffect(() => {
    if (!selectedIdea) return;
    void Promise.resolve().then(() => loadStages(selectedIdea));
  }, [selectedIdea, loadStages]);

  const selectedStage = ideaStages.find(
    (stage) => stage.stage_number === currentStage,
  );
  const confirmedStageCount = ideaStages.filter(
    (stage) => stage.stage_number <= 6 && stage.status === "confirmed",
  ).length;
  const remainingStageCount = 6 - confirmedStageCount;
  const isDirty =
    selectedStage !== undefined &&
    drafts[currentStage] !== readContent(selectedStage);
  const submittedDeadline =
    selectedIdea?.submitted_at === null ||
    selectedIdea?.submitted_at === undefined
      ? null
      : Date.parse(selectedIdea.submitted_at) + dossierEditingWindowMs;
  const remainingEditingMs =
    submittedDeadline === null
      ? 0
      : Math.max(0, submittedDeadline - clockNow);
  const editingWindowActive =
    selectedIdea?.status === "submitted" &&
    submittedDeadline !== null &&
    Number.isFinite(submittedDeadline) &&
    !editingWindowExpired &&
    remainingEditingMs > 0;
  const stageEditable =
    selectedStage !== undefined &&
    ["not_started", "in_progress", "pending_confirmation", "confirmed"].includes(
      selectedStage.status,
    ) &&
    currentStage >= 1 &&
    currentStage <= 6 &&
    (selectedIdea?.status !== "submitted" || editingWindowActive);
  const selectedStageDefinition = IDEA_STAGES[currentStage - 1];
  const currentMentorGuidance =
    selectedStageDefinition && selectedStageDefinition.number <= 6
      ? IDEA_STAGE_FALLBACK_GUIDANCE[
          selectedStageDefinition.key as Exclude<IdeaStageKey, "human_review">
        ]
      : undefined;
  const canRetrySave =
    pendingSave !== null &&
    pendingSave.ideaId === selectedIdea?.id &&
    pendingSave.stageNumber === currentStage;
  const allDevelopmentStagesConfirmed =
    ideaStages.filter((stage) => stage.stage_number <= 6).length === 6 &&
    ideaStages
      .filter((stage) => stage.stage_number <= 6)
      .every((stage) => stage.status === "confirmed");

  useEffect(() => {
    if (!isDirty) return;
    function warnBeforeLeaving(event: BeforeUnloadEvent): void {
      event.preventDefault();
      event.returnValue = "";
    }
    window.addEventListener("beforeunload", warnBeforeLeaving);
    return () => window.removeEventListener("beforeunload", warnBeforeLeaving);
  }, [isDirty]);

  function selectIdea(idea: Idea): void {
    if (pendingSaveRef.current) {
      setNotice({
        kind: "error",
        message: "پیش از جابه‌جایی، درخواست ذخیره نامشخص را دوباره ارسال کنید.",
      });
      return;
    }
    stageLoadVersion.current += 1;
    dossierHistoryLoadVersion.current += 1;
    setDossierPreviewOpen(false);
    setDossierHistoryOpen(false);
    setDossierHistoryState({ kind: "loading" });
    setNotice(null);
    setIdeaStages([]);
    setDrafts({});
    setStagesLoading(true);
    setSelectedIdea(idea);
    window.history.replaceState(
      null,
      "",
      `/ideas?idea=${encodeURIComponent(idea.id)}`,
    );
  }

  function returnToIdeas(): void {
    if (pendingSaveRef.current || isDirty || stepBusyRef.current) {
      setNotice({
        kind: "error",
        message: pendingSaveRef.current
          ? "پیش از ترک ایده، درخواست ذخیره نامشخص را دوباره ارسال کنید."
          : isDirty
            ? "پیش از ترک ایده، تغییرات فعلی را ذخیره کنید."
            : "پیش از ترک ایده، منتظر ذخیره مرحله بمانید.",
      });
      return;
    }
    stageLoadVersion.current += 1;
    dossierHistoryLoadVersion.current += 1;
    setDossierPreviewOpen(false);
    setDossierHistoryOpen(false);
    setDossierHistoryState({ kind: "loading" });
    setSelectedIdea(null);
    setIdeaStages([]);
    setDrafts({});
    setStagesLoading(false);
    setNotice(null);
    setStagesError(null);
    window.history.replaceState(null, "", "/ideas");
    void refreshIdeas();
  }

  async function persistCurrentStep(
    idea: Idea,
    stageNumber: number,
  ): Promise<boolean> {
    if (stepBusyRef.current) return false;
    const requestUserId = activeUserId.current;
    stepBusyRef.current = true;
    setStepSaving(true);
    try {
      const { data, error } = await supabase.rpc("set_idea_current_step", {
        p_idea_id: idea.id,
        p_current_step: stageNumber,
      });
      if (activeUserId.current !== requestUserId) {
        return false;
      }
      if (error) {
        setNotice({ kind: "error", message: getErrorMessage(error) });
        return false;
      }
      const result = parseOutcome(data);
      if (
        !result ||
        !["saved", "already_current"].includes(String(result.outcome)) ||
        result.current_step !== stageNumber
      ) {
        setNotice({
          kind: "error",
          message: outcomeMessage(String(result?.outcome ?? "invalid_state")),
        });
        return false;
      }
      setSelectedIdea((existing) =>
        existing?.id === idea.id
          ? { ...existing, current_step: stageNumber }
          : existing,
      );
      setIdeas((existing) =>
        existing.map((item) =>
          item.id === idea.id ? { ...item, current_step: stageNumber } : item,
        ),
      );
      setCurrentStage(stageNumber);
      updateIdeaLocation(idea.id, stageNumber);
      return true;
    } catch {
      setNotice({
        kind: "error",
        message: "مرحله ذخیره نشد. اتصال را بررسی و دوباره انتخاب کنید.",
      });
      return false;
    } finally {
      setStepSaving(false);
      stepBusyRef.current = false;
    }
  }

  async function selectStage(stageNumber: number): Promise<void> {
    const stage = ideaStages.find((item) => item.stage_number === stageNumber);
    if (
      !selectedIdea ||
      !stage ||
      stage.status === "locked" ||
      pendingSave !== null ||
      saving ||
      confirming ||
      stepSaving ||
      submitting
    ) {
      return;
    }
    if (isDirty) {
      setNotice({
        kind: "error",
        message: "پیش از جابه‌جایی، تغییرات فعلی را ذخیره کنید.",
      });
      return;
    }
    if (selectedIdea.status === "submitted") {
      setCurrentStage(stageNumber);
      updateIdeaLocation(selectedIdea.id, stageNumber);
      return;
    }
    if (stageNumber !== currentStage) {
      await persistCurrentStep(selectedIdea, stageNumber);
    }
  }

  async function createIdea(): Promise<void> {
    if (
      createBusyRef.current ||
      !createRequestStorageReady ||
      pendingCreateStorageError ||
      !user
    ) {
      return;
    }
    createBusyRef.current = true;
    setCreating(true);
    setNotice({ kind: "info", message: "در حال ایجاد ایده…" });

    let requestId = createRequestRef.current;
    if (!requestId) {
      requestId = createRequestId();
      try {
        window.sessionStorage.setItem(
          `javaneh.pending_create_request_id:${user.id}`,
          requestId,
        );
      } catch {
        setPendingCreateStorageError(
          "شناسه تلاش در این مرورگر ذخیره نشد. برای جلوگیری از ایجاد تکراری، درخواست ارسال نشد.",
        );
        setCreating(false);
        createBusyRef.current = false;
        return;
      }
      createRequestRef.current = requestId;
      setPendingCreateRequestId(requestId);
    }

    try {
      const { data, error } = await supabase.rpc("create_idea", {
        p_request_id: requestId,
      });
      if (activeUserId.current !== user.id) return;
      if (error) {
        setNotice({ kind: "error", message: getErrorMessage(error) });
        return;
      }

      const result = parseOutcome(data);
      if (!result) {
        setNotice({
          kind: "error",
          message: "پاسخ ایجاد ایده معتبر نبود. برای تلاش مجدد از همان شناسه استفاده کنید.",
        });
        return;
      }

      const outcome = result.outcome as string;
      if (outcome === "created" || outcome === "already_exists") {
        if (typeof result.idea_id !== "string") {
          setNotice({
            kind: "error",
            message: "شناسه ایده در پاسخ پایگاه داده وجود ندارد.",
          });
          return;
        }

        window.sessionStorage.removeItem(
          `javaneh.pending_create_request_id:${user.id}`,
        );
        createRequestRef.current = null;
        setPendingCreateRequestId(null);
        const refreshedIdeas = await refreshIdeas();
        const createdIdea = refreshedIdeas?.find(
          (idea) => idea.id === result.idea_id,
        );
        if (!createdIdea) {
          setNotice({
            kind: "error",
            message: "ایده ایجاد شد، اما در فهرست شما بارگذاری نشد. فهرست را تازه‌سازی کنید.",
          });
          return;
        }
        setNotice({
          kind: "success",
          message:
            outcome === "created"
              ? "ایده و هفت مرحله آن با موفقیت ایجاد شد."
              : "درخواست قبلی بازیابی شد.",
        });
        selectIdea(createdIdea);
        return;
      }

      if (
        outcome === "quota_exceeded" ||
        outcome === "already_deleted"
      ) {
        window.sessionStorage.removeItem(
          `javaneh.pending_create_request_id:${user.id}`,
        );
        createRequestRef.current = null;
        setPendingCreateRequestId(null);
      }
      setNotice({ kind: "error", message: outcomeMessage(outcome) });
    } catch {
      setNotice({
        kind: "error",
        message:
          "پاسخ شبکه دریافت نشد. با تلاش دوباره، همان درخواست ایجاد ارسال می‌شود.",
      });
    } finally {
      setCreating(false);
      createBusyRef.current = false;
    }
  }

  async function deleteIdea(ideaToDelete: Idea | null = selectedIdea): Promise<void> {
    if (
      deleteBusyRef.current ||
      !user ||
      !ideaToDelete ||
      ideaToDelete.status === "submitted" ||
      saving ||
      confirming ||
      stepSaving ||
      pendingSaveRef.current
    ) {
      return;
    }
    if (
      !window.confirm(
        "حذف دائمی ایده و همه محتوای ذخیره‌شده آن؟ این عمل قابل بازگشت نیست.",
      )
    ) {
      return;
    }

    deleteBusyRef.current = true;
    setDeleting(true);
    setNotice({ kind: "info", message: "در حال حذف دائمی ایده…" });
    const ideaId = ideaToDelete.id;
    try {
      const { data, error } = await supabase.rpc("delete_own_idea", {
        p_idea_id: ideaId,
      });
      if (activeUserId.current !== user.id) return;
      if (error) {
        setNotice({ kind: "error", message: getErrorMessage(error) });
        return;
      }
      const result = parseOutcome(data);
      if (!result) {
        setNotice({
          kind: "error",
          message: "پاسخ حذف معتبر نبود. فهرست را تازه‌سازی و وضعیت ایده را بررسی کنید.",
        });
        return;
      }
      if (result.outcome === "not_found_or_already_deleted") {
        const refreshedIdeas = await refreshIdeas();
        if (!refreshedIdeas) {
          setNotice({
            kind: "error",
            message:
              "وضعیت حذف قطعی نیست و فهرست به‌روز نشد؛ ظرفیت باقی‌مانده تا دریافت اطلاعات تازه تغییر نمی‌کند.",
          });
        } else if (!refreshedIdeas.some((idea) => idea.id === ideaId)) {
          setSelectedIdea((existing) =>
            existing?.id === ideaId ? null : existing,
          );
          setIdeaStages([]);
          setDrafts({});
          setRevision(null);
          window.history.replaceState(null, "", "/ideas");
          setNotice({
            kind: "info",
            message: "این ایده دیگر در فهرست شما نیست؛ فهرست به‌روز شد.",
          });
        } else {
          setNotice({
            kind: "error",
            message: outcomeMessage(String(result.outcome)),
          });
        }
        return;
      }
      if (result.outcome === "deleted" || result.outcome === "already_deleted") {
        setSelectedIdea((existing) =>
          existing?.id === ideaId ? null : existing,
        );
        setIdeaStages([]);
        setDrafts({});
        setRevision(null);
        window.history.replaceState(null, "", "/ideas");
        await refreshIdeas();
        setNotice({
          kind: "success",
          message:
            result.outcome === "deleted"
              ? "ایده و محتوای وابسته آن حذف شد."
              : "این ایده قبلاً حذف شده بود؛ فهرست به‌روز شد.",
        });
        return;
      }
      setNotice({
        kind: "error",
        message: outcomeMessage(String(result.outcome)),
      });
    } catch {
      setNotice({
        kind: "error",
        message: "پاسخ حذف دریافت نشد. دوباره تلاش کنید؛ حذف تکراری امن است.",
      });
    } finally {
      setDeleting(false);
      deleteBusyRef.current = false;
    }
  }

  async function submitIdea(): Promise<void> {
    if (
      submitBusyRef.current ||
      !user ||
      !selectedIdea ||
      selectedIdea.status === "submitted" ||
      revision === null ||
      !allDevelopmentStagesConfirmed ||
      isDirty ||
      pendingSaveRef.current ||
      saving ||
      confirming ||
      stepSaving
    ) {
      return;
    }

    const storageKey = `javaneh.idea_submission_request_id:${user.id}:${selectedIdea.id}`;
    let requestId = submissionRequestIds.current.get(selectedIdea.id) ?? null;
    if (!requestId) {
      try {
        requestId = window.sessionStorage.getItem(storageKey);
      } catch {
        setNotice({
          kind: "error",
          message: "شناسه امن ارسال ذخیره نشد؛ برای جلوگیری از ارسال تکراری درخواست ارسال نشد.",
        });
        return;
      }
    }
    if (!requestId) {
      requestId = createRequestId();
      try {
        window.sessionStorage.setItem(storageKey, requestId);
      } catch {
        setNotice({
          kind: "error",
          message: "شناسه امن ارسال ذخیره نشد؛ برای جلوگیری از ارسال تکراری درخواست ارسال نشد.",
        });
        return;
      }
    }
    submissionRequestIds.current.set(selectedIdea.id, requestId);

    submitBusyRef.current = true;
    setSubmitting(true);
    setNotice({ kind: "info", message: "در حال ثبت نهایی ایده…" });
    try {
      const { data, error } = await supabase.rpc("submit_idea", {
        p_idea_id: selectedIdea.id,
        p_request_id: requestId,
        p_expected_revision: revision,
      });
      if (activeUserId.current !== user.id) return;
      if (error) {
        setNotice({ kind: "error", message: getErrorMessage(error) });
        return;
      }
      const result = parseOutcome(data);
      if (!result) {
        setNotice({
          kind: "error",
          message: "پاسخ ثبت نهایی معتبر نبود. با تلاش دوباره همان درخواست ارسال می‌شود.",
        });
        return;
      }
      if (result.outcome === "submitted" || result.outcome === "replayed") {
        window.sessionStorage.removeItem(storageKey);
        submissionRequestIds.current.delete(selectedIdea.id);
        const submittedIdea = {
          ...selectedIdea,
          status: "submitted" as const,
          evaluationStatus: "awaiting_review" as const,
          current_step:
            typeof result.current_step === "number" &&
            Number.isInteger(result.current_step)
              ? result.current_step
              : 7,
          revision:
            typeof result.revision === "number" &&
            Number.isInteger(result.revision)
              ? result.revision
              : revision,
          submitted_at:
            typeof result.submitted_at === "string"
              ? result.submitted_at
              : selectedIdea.submitted_at,
        };
        setSelectedIdea(submittedIdea);
        setIdeas((existing) =>
          existing.map((idea) =>
            idea.id === submittedIdea.id ? submittedIdea : idea,
          ),
        );
        setRevision(submittedIdea.revision);
        setCurrentStage(submittedIdea.current_step);
        updateIdeaLocation(submittedIdea.id, submittedIdea.current_step);
        setNotice({
          kind: "success",
          message:
            result.outcome === "submitted"
              ? "ایده با موفقیت ثبت نهایی شد."
              : "نتیجه ثبت نهایی قبلی بازیابی شد.",
        });
        return;
      }
      if (result.outcome === "already_submitted") {
        window.sessionStorage.removeItem(storageKey);
        submissionRequestIds.current.delete(selectedIdea.id);
        const refreshedIdeas = await refreshIdeas();
        const refreshedIdea = refreshedIdeas?.find(
          (idea) => idea.id === selectedIdea.id,
        );
        setSelectedIdea((existing) =>
          existing?.id === selectedIdea.id && refreshedIdea
            ? refreshedIdea
            : existing,
        );
        setRevision(refreshedIdea?.revision ?? revision);
        setCurrentStage(refreshedIdea?.current_step ?? 7);
        updateIdeaLocation(
          selectedIdea.id,
          refreshedIdea?.current_step ?? 7,
        );
        setNotice({
          kind: "success",
          message: "این ایده قبلاً ثبت نهایی شده است.",
        });
        return;
      }
      if (
        result.outcome === "not_found_or_not_owned" ||
        result.outcome === "invalid_state" ||
        result.outcome === "idempotency_key_reuse"
      ) {
        window.sessionStorage.removeItem(storageKey);
        submissionRequestIds.current.delete(selectedIdea.id);
      }
      setNotice({
        kind: "error",
        message: outcomeMessage(String(result.outcome)),
      });
    } catch {
      setNotice({
        kind: "error",
        message: "پاسخ ثبت نهایی دریافت نشد. دوباره تلاش کنید؛ همان درخواست به‌صورت ایمن تکرار می‌شود.",
      });
    } finally {
      setSubmitting(false);
      submitBusyRef.current = false;
    }
  }

  const saveStage = useCallback(async (retry = false): Promise<void> => {
    if (
      saveBusyRef.current ||
      !user ||
      !selectedIdea ||
      revision === null ||
      !selectedStage ||
      (!stageEditable && !retry) ||
      stepSaving
    ) {
      return;
    }

    let request = retry ? pendingSaveRef.current : null;
    if (
      retry &&
      (!request ||
        request.ideaId !== selectedIdea.id ||
        request.stageNumber !== currentStage)
    ) {
      setNotice({
        kind: "error",
        message: "درخواست قابل بازیابی برای این مرحله وجود ندارد.",
      });
      return;
    }

    if (!request) {
      if (pendingSaveRef.current) {
        setNotice({
          kind: "error",
          message: "ابتدا درخواست ذخیره نامشخص قبلی را دوباره ارسال کنید.",
        });
        return;
      }
      request = {
        ideaId: selectedIdea.id,
        stageNumber: currentStage,
        requestId: createRequestId(),
        expectedRevision: revision,
        content: drafts[currentStage] ?? "",
        stageData: {
          ...selectedStage.data,
          content: drafts[currentStage] ?? "",
        },
        submittedEdit: selectedIdea.status === "submitted",
      };
      pendingSaveRef.current = request;
      setPendingSave(request);
    }

    try {
      window.localStorage.setItem(
        localDraftKey(user.id, request.ideaId),
        JSON.stringify({
          stageNumber: request.stageNumber,
          content: drafts[request.stageNumber] ?? request.content,
          revision: revision ?? request.expectedRevision,
        } satisfies LocalDraftRecovery),
      );
      setLocalRecoveryError(null);
    } catch {
      setLocalRecoveryError(
        "تغییرات در حافظه محلی این مرورگر نگهداری نشدند؛ تا دریافت تأیید پایگاه داده صفحه را نبندید.",
      );
    }

    if (!window.navigator.onLine) {
      setSyncStatus("pending");
      setNotice({
        kind: "info",
        message: "اتصال برقرار نیست؛ تغییرات محلی نگه داشته شد و پس از اتصال دوباره همگام می‌شود.",
      });
      return;
    }

    saveBusyRef.current = true;
    setSaving(true);
    setSyncStatus("pending");
    setNotice({
      kind: "info",
      message: retry ? "در حال تکرار همان درخواست ذخیره…" : "در حال ذخیره مرحله…",
    });

    let responseData: unknown;
    let responseError: { code?: string; message?: string } | null = null;
    try {
      for (let attempt = 0; attempt < 3; attempt += 1) {
        try {
          const result = request.submittedEdit
            ? await supabase.rpc("edit_submitted_idea", {
                p_idea_id: request.ideaId,
                p_request_id: request.requestId,
                p_expected_revision: request.expectedRevision,
                p_stage_updates: [
                  {
                    stage_number: request.stageNumber,
                    data: request.stageData,
                  },
                ],
              })
            : await supabase.rpc("save_idea_content", {
                p_idea_id: request.ideaId,
                p_request_id: request.requestId,
                p_expected_revision: request.expectedRevision,
                p_stage_updates: [
                  {
                    stage_number: request.stageNumber,
                    data: request.stageData,
                  },
                ],
              });
          if (!result.error) {
            responseData = result.data;
            responseError = null;
            break;
          }
          responseError = result.error;
          if (!isTransientSaveFailure(result.error) || attempt === 2) break;
        } catch (error) {
          responseError = {
            message:
              error instanceof Error ? error.message : "Network request failed",
          };
          if (!isTransientSaveFailure(responseError) || attempt === 2) break;
        }
        await new Promise<void>((resolve) =>
          window.setTimeout(resolve, 500 * 2 ** attempt),
        );
      }

      if (activeUserId.current !== user.id) return;
      if (responseError) {
        const transient = isTransientSaveFailure(responseError);
        if (!transient) {
          pendingSaveRef.current = null;
          setPendingSave(null);
        }
        setSyncStatus("failed");
        setNotice({
          kind: "error",
          message: transient
            ? `${getErrorMessage(responseError)} تغییرات محلی باقی مانده‌اند؛ با اتصال پایدار دوباره تلاش کنید.`
            : getErrorMessage(responseError),
        });
        return;
      }

      const result = parseOutcome(responseData);
      if (!result) {
        setSyncStatus("failed");
        setNotice({
          kind: "error",
          message: "پاسخ ذخیره معتبر نبود. همان درخواست را دوباره ارسال کنید.",
        });
        return;
      }

      const outcome = result.outcome as string;
      if (["applied", "no_op", "replayed"].includes(outcome)) {
        if (!Number.isInteger(result.result_revision)) {
          setNotice({
            kind: "error",
            message: "پاسخ ذخیره فاقد نسخه معتبر است. وضعیت را دوباره بارگذاری کنید.",
          });
          return;
        }
        const resultRevision = result.result_revision as number;
        setRevision(resultRevision);
        setSelectedIdea((idea) =>
          idea ? { ...idea, revision: resultRevision } : idea,
        );
        setIdeas((existing) =>
          existing.map((idea) =>
            idea.id === request?.ideaId
              ? { ...idea, revision: resultRevision }
              : idea,
          ),
        );
        const contentApplied =
          outcome === "applied" ||
          (outcome === "replayed" &&
            result.original_outcome === "applied");
        if (contentApplied && !request.submittedEdit) {
          setSelectedIdea((idea) =>
            idea && idea.status === "draft"
              ? { ...idea, status: "in_progress" }
              : idea,
          );
          setIdeas((existing) =>
            existing.map((idea) =>
              idea.id === request?.ideaId && idea.status === "draft"
                ? { ...idea, status: "in_progress" }
                : idea,
            ),
          );
        }
        setIdeaStages((existing) =>
          existing.map((stage) =>
            stage.stage_number === request?.stageNumber
              ? {
                    ...stage,
                    data: request?.stageData ?? stage.data,
                    status:
                      contentApplied && !request?.submittedEdit
                        ? stage.status === "confirmed" ||
                          stage.status === "not_started" ||
                          stage.status === "pending_confirmation"
                          ? "in_progress"
                          : stage.status
                        : stage.status,
                    confirmed_at:
                      contentApplied &&
                      !request?.submittedEdit &&
                      stage.status === "confirmed"
                        ? null
                        : stage.confirmed_at,
                  }
                : stage,
            ),
        );
        pendingSaveRef.current = null;
        setPendingSave(null);
        let newerLocalContent = false;
        try {
            const recoveryKey = localDraftKey(user.id, request.ideaId);
            const recovery = parseLocalDraftRecovery(
              window.localStorage.getItem(recoveryKey),
            );
            newerLocalContent =
              recovery?.stageNumber === request.stageNumber &&
              recovery.content !== request.content;
            if (newerLocalContent && recovery) {
              window.localStorage.setItem(
                recoveryKey,
                JSON.stringify({
                  ...recovery,
                  revision: resultRevision,
                } satisfies LocalDraftRecovery),
              );
            } else if (recovery?.stageNumber === request.stageNumber) {
              window.localStorage.removeItem(recoveryKey);
            }
            setLocalRecoveryError(null);
        } catch {
            setLocalRecoveryError(
              "ذخیره محلی همگام‌سازی شد اما پاک‌سازی آن ناموفق بود.",
            );
            setSyncStatus("failed");
        }
        setSyncStatus(newerLocalContent ? "pending" : "saved");
        setNotice({
            kind: "success",
            message:
              newerLocalContent
                ? "یک نسخه ذخیره شد؛ تغییرات جدیدتر در صف ذخیره قرار دارند."
                : outcome === "no_op"
                ? "محتوا تغییری نداشت؛ نسخه افزایش نیافت."
                : outcome === "replayed"
                  ? "نتیجه ذخیره قبلی بازیابی شد."
                : "مرحله با موفقیت ذخیره شد.",
        });
        return;
      }

      if (outcome === "stale_revision") {
        pendingSaveRef.current = null;
        setPendingSave(null);
        setSyncStatus("failed");
        const [{ data: latestIdea, error: ideaError }, { data: latestStage, error: stageError }] =
          await Promise.all([
            supabase
              .from("ideas")
              .select("revision")
              .eq("id", request.ideaId)
              .maybeSingle(),
            supabase
              .from("idea_stages")
              .select("data")
              .eq("idea_id", request.ideaId)
              .eq("stage_number", request.stageNumber)
              .maybeSingle(),
          ]);
        if (
          !ideaError &&
          !stageError &&
          isRecord(latestIdea) &&
          Number.isInteger(latestIdea.revision) &&
          isRecord(latestStage) &&
          isRecord(latestStage.data) &&
          (latestStage.data.content === undefined ||
            typeof latestStage.data.content === "string")
        ) {
          const serverRevision = Number(latestIdea.revision);
          const serverContent =
            typeof latestStage.data.content === "string"
              ? latestStage.data.content
              : "";
          setRevision(serverRevision);
          setSelectedIdea((idea) =>
            idea?.id === request?.ideaId
              ? { ...idea, revision: serverRevision }
              : idea,
          );
          setIdeaStages((existing) =>
            existing.map((stage) =>
              stage.stage_number === request?.stageNumber
                ? { ...stage, data: latestStage.data as IdeaDraftData }
                : stage,
            ),
          );
          setDraftConflict({
            stageNumber: request.stageNumber,
            serverContent,
            serverRevision,
          });
        }
        setNotice({
          kind: "error",
          message: "نسخه پایگاه داده تغییر کرده است. تغییر محلی حفظ شد؛ نسخه‌ها را مقایسه و تعارض را حل کنید.",
        });
      } else if (
        outcome === "idempotency_key_reuse" ||
        outcome === "not_found_or_not_owned" ||
        outcome === "invalid_state" ||
        outcome === "invalid_input" ||
        outcome === "editing_window_expired"
      ) {
        pendingSaveRef.current = null;
        setPendingSave(null);
        setSyncStatus("failed");
      } else {
        setSyncStatus("failed");
      }
      if (outcome === "editing_window_expired") {
        setEditingWindowExpired(true);
      }
      setNotice({ kind: "error", message: outcomeMessage(outcome) });
    } catch {
      setSyncStatus("failed");
      setNotice({
        kind: "error",
        message:
          "پاسخ شبکه دریافت نشد. تغییرات محلی حفظ شده‌اند؛ تلاش دوباره همان شناسه و محتوای درخواست را نگه می‌دارد.",
      });
    } finally {
      setSaving(false);
      saveBusyRef.current = false;
    }
  }, [
    currentStage,
    drafts,
    revision,
    selectedIdea,
    selectedStage,
    stageEditable,
    stepSaving,
    supabase,
    user,
  ]);

  function updateDraftContent(content: string): void {
    if (!selectedIdea || !user || revision === null) return;
    setDrafts((existing) => ({ ...existing, [currentStage]: content }));
    setSyncStatus("pending");
    try {
      window.localStorage.setItem(
        localDraftKey(user.id, selectedIdea.id),
        JSON.stringify({
          stageNumber: currentStage,
          content,
          revision,
        } satisfies LocalDraftRecovery),
      );
      setLocalRecoveryError(null);
    } catch {
      setLocalRecoveryError(
        "این مرورگر نتوانست تغییرات محلی را نگه دارد؛ تا تأیید ذخیره پایگاه داده صفحه را نبندید.",
      );
      setSyncStatus("failed");
    }
  }

  async function requestMentorGuidance(): Promise<void> {
    const stage = IDEA_STAGES[currentStage - 1];
    const message = mentorQuestions[currentStage]?.trim() ?? "";
    if (
      !user ||
      !selectedIdea ||
      !stage ||
      currentStage < 1 ||
      currentStage > 6 ||
      selectedIdea.status === "submitted" ||
      !message ||
      mentorBusyStage !== null
    ) {
      return;
    }
    if (!isOnline) {
      setMentorFallbackActive(true);
      setMentorAvailability("temporarily_unavailable");
      setMentorErrors((existing) => ({
        ...existing,
        [currentStage]: "بدون اتصال شبکه، از راهنمای بدون هوش مصنوعی این مرحله استفاده کنید؛ نوشته شما حفظ می‌شود.",
      }));
      return;
    }

    setMentorBusyStage(currentStage);
    setMentorErrors((existing) => ({ ...existing, [currentStage]: "" }));
    const wasUsingFallback = mentorFallbackActive;
    try {
      const response = await fetch("/api/mentor", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          ideaId: selectedIdea.id,
          requestId: createRequestId(),
          stageKey: stage.key,
          message,
        }),
      });
      const body: unknown = await response.json();
      if (!response.ok) {
        const failure = mentorFailureResponseSchema.safeParse(body);
        const code = failure.success ? failure.data.error.code : "provider_unavailable";
        const fallbackMessage =
          code === "not_configured"
            ? "دستیار هوش مصنوعی پیکربندی نشده است؛ راهنمای بدون هوش مصنوعی همین مرحله در دسترس است."
            : code === "circuit_open"
              ? "دستیار هوش مصنوعی موقتاً متوقف شده است؛ می‌توانید کار را ذخیره و ادامه دهید."
              : "دستیار هوش مصنوعی موقتاً در دسترس نیست؛ نوشته شما حفظ شده و می‌توانید با راهنمای همین مرحله ادامه دهید.";
        setMentorErrors((existing) => ({
          ...existing,
          [currentStage]: fallbackMessage,
        }));
        setMentorFallbackActive(true);
        setMentorAvailability(
          code === "not_configured" ? "not_configured" : "temporarily_unavailable",
        );
        const retryAfter = Number(response.headers.get("retry-after"));
        setMentorRetryAfterSeconds(
          Number.isInteger(retryAfter) && retryAfter > 0 ? retryAfter : null,
        );
        return;
      }

      const success = mentorSuccessResponseSchema.safeParse(body);
      if (!success.success) {
        setMentorErrors((existing) => ({
          ...existing,
          [currentStage]: "پاسخ راهنما معتبر نبود؛ از راهنمای بدون هوش مصنوعی استفاده کنید.",
        }));
        setMentorFallbackActive(true);
        setMentorAvailability("temporarily_unavailable");
        return;
      }
      setMentorSuggestions((existing) => ({
        ...existing,
        [currentStage]: [
          success.data.suggestion.message,
          ...success.data.suggestion.followUpQuestions,
        ].join("\n\n"),
      }));
      setMentorAvailability(wasUsingFallback ? "restored" : "available");
      setMentorFallbackActive(false);
      setMentorRetryAfterSeconds(null);
    } catch {
      setMentorErrors((existing) => ({
        ...existing,
        [currentStage]: "به دستیار هوش مصنوعی دسترسی برقرار نشد؛ نوشته شما حفظ شده و راهنمای بدون هوش مصنوعی در دسترس است.",
      }));
      setMentorFallbackActive(true);
      setMentorAvailability("temporarily_unavailable");
    } finally {
      setMentorBusyStage(null);
    }
  }

  function useDatabaseVersion(): void {
    if (!draftConflict) return;
    setDrafts((existing) => ({
      ...existing,
      [draftConflict.stageNumber]: draftConflict.serverContent,
    }));
    try {
      if (user && selectedIdea) {
        window.localStorage.removeItem(
          localDraftKey(user.id, selectedIdea.id),
        );
      }
      setLocalRecoveryError(null);
    } catch {
      setLocalRecoveryError("نسخه محلی پاک نشد؛ داده‌های مرورگر را پاک کنید.");
      setSyncStatus("failed");
    }
    setDraftConflict(null);
    setSyncStatus("saved");
  }

  function keepLocalVersion(): void {
    if (!draftConflict || !selectedIdea || !user) return;
    setRevision(draftConflict.serverRevision);
    setSelectedIdea((idea) =>
      idea?.id === selectedIdea.id
        ? { ...idea, revision: draftConflict.serverRevision }
        : idea,
    );
    setDraftConflict(null);
    setSyncStatus("pending");
    try {
      window.localStorage.setItem(
        localDraftKey(user.id, selectedIdea.id),
        JSON.stringify({
          stageNumber: draftConflict.stageNumber,
          content: drafts[draftConflict.stageNumber] ?? "",
          revision: draftConflict.serverRevision,
        } satisfies LocalDraftRecovery),
      );
      setLocalRecoveryError(null);
    } catch {
      setLocalRecoveryError(
        "تغییر محلی را برای همگام‌سازی ذخیره نکردیم؛ تا نتیجه پایگاه داده صفحه را نبندید.",
      );
      setSyncStatus("failed");
    }
  }

  useEffect(() => {
    if (
      !selectedIdea ||
      !selectedStage ||
      !user ||
      !isDirty ||
      !stageEditable ||
      pendingSave ||
      saving ||
      stepSaving ||
      draftConflict ||
      syncStatus === "failed" ||
      !isOnline
    ) {
      return;
    }
    const timer = window.setTimeout(() => void saveStage(), 800);
    return () => window.clearTimeout(timer);
  }, [
    currentStage,
    draftConflict,
    isDirty,
    isOnline,
    pendingSave,
    saving,
    selectedIdea,
    selectedStage,
    stageEditable,
    stepSaving,
    syncStatus,
    user,
    drafts,
    saveStage,
  ]);

  useEffect(() => {
    if (isOnline && pendingSave && user) {
      const timer = window.setTimeout(() => void saveStage(true), 250);
      return () => window.clearTimeout(timer);
    }
  }, [isOnline, pendingSave, user, saveStage]);

  async function confirmStage(): Promise<void> {
    if (
      confirmBusyRef.current ||
      !user ||
      !selectedIdea ||
      revision === null ||
      !selectedStage ||
      currentStage < 1 ||
      currentStage > 6 ||
      selectedIdea.status === "submitted" ||
      stepSaving ||
      !["in_progress", "pending_confirmation"].includes(selectedStage.status)
    ) {
      return;
    }
    if (isDirty || pendingSave) {
      setNotice({
        kind: "error",
        message: "پیش از تأیید مرحله، ابتدا تغییرات را ذخیره کنید.",
      });
      return;
    }

    confirmBusyRef.current = true;
    setConfirming(true);
    setNotice({ kind: "info", message: "در حال ثبت تأیید مرحله…" });
    try {
      const requestResult = await supabase.rpc(
        "request_idea_stage_confirmation",
        {
          p_idea_id: selectedIdea.id,
          p_stage_number: currentStage,
        },
      );
      if (activeUserId.current !== user.id) return;
      if (requestResult.error) {
        setNotice({
          kind: "error",
          message: getErrorMessage(requestResult.error),
        });
        return;
      }

      const requested = parseOutcome(requestResult.data);
      if (
        !requested ||
        !["requested", "already_requested"].includes(
          String(requested.outcome),
        )
      ) {
        setNotice({
          kind: "error",
          message: outcomeMessage(String(requested?.outcome ?? "invalid_state")),
        });
        return;
      }

      const confirmationResult = await supabase.rpc("confirm_idea_stage", {
        p_idea_id: selectedIdea.id,
        p_stage_number: currentStage,
        p_expected_revision: revision,
      });
      if (activeUserId.current !== user.id) return;
      if (confirmationResult.error) {
        setNotice({
          kind: "error",
          message: getErrorMessage(confirmationResult.error),
        });
        return;
      }

      const confirmed = parseOutcome(confirmationResult.data);
      const outcome = String(confirmed?.outcome ?? "invalid_state");
      if (outcome === "confirmed" || outcome === "already_confirmed") {
        if (
          shouldDispatchAfterConfirmation({
            stageNumber: currentStage,
            outcome,
            otherStageConfirmed: ideaStages.some(
              (stage) =>
                stage.stage_number === (currentStage === 1 ? 2 : 1) &&
                stage.status === "confirmed",
            ),
          })
        ) {
          setClassificationTriggerVersion((version) => version + 1);
        }
        const nextStep =
          typeof confirmed?.current_step === "number" &&
          Number.isInteger(confirmed.current_step)
            ? confirmed.current_step
            : currentStage;
        const progressedIdea = {
          ...selectedIdea,
          current_step: nextStep,
        };
        setSelectedIdea(progressedIdea);
        setIdeas((existing) =>
          existing.map((idea) =>
            idea.id === progressedIdea.id ? progressedIdea : idea,
          ),
        );
        if (nextStep !== currentStage) {
          setCurrentStage(nextStep);
          updateIdeaLocation(selectedIdea.id, nextStep);
        }
        await loadStages(progressedIdea);
        setNotice({ kind: "success", message: "مرحله با موفقیت تأیید شد." });
      } else {
        setNotice({ kind: "error", message: outcomeMessage(outcome) });
      }
    } catch {
      setNotice({
        kind: "error",
        message: "پاسخ تأیید دریافت نشد. وضعیت مرحله را تازه‌سازی و دوباره بررسی کنید.",
      });
    } finally {
      setConfirming(false);
      confirmBusyRef.current = false;
    }
  }

  async function reloadSelectedIdea(): Promise<void> {
    if (!selectedIdea) return;
    if (pendingSaveRef.current) {
      setNotice({
        kind: "error",
        message:
          "برای جلوگیری از تکرار ناخواسته، ابتدا همان درخواست ذخیره را دوباره ارسال کنید.",
      });
      return;
    }
    const refreshedIdeas = await refreshIdeas();
    const latestIdea = refreshedIdeas?.find(
      (idea) => idea.id === selectedIdea.id,
    );
    if (!latestIdea) {
      setNotice({
        kind: "error",
        message: "این ایده دیگر در فهرست شما نیست یا دسترسی به آن وجود ندارد.",
      });
      setSelectedIdea(null);
      window.history.replaceState(null, "", "/ideas");
      return;
    }
    setSelectedIdea(latestIdea);
    await loadStages(latestIdea);
    setPendingSave(null);
    pendingSaveRef.current = null;
    setNotice({
      kind: "info",
      message: "آخرین نسخه پایگاه داده بارگذاری شد؛ پیش‌نویس محلی احتمالی حفظ و برای بررسی تعارض نشان داده می‌شود.",
    });
  }

  if (authLoading) {
    return (
      <main className="flex flex-1 items-center justify-center px-6 py-16">
        <p role="status" className="text-foreground/70">
          در حال بررسی وضعیت ورود…
        </p>
      </main>
    );
  }

  if (!user) {
    return (
      <main className="flex flex-1 items-center justify-center px-6 py-16">
        <section className="w-full max-w-xl rounded-2xl border border-foreground/10 bg-white p-8 text-center shadow-sm dark:bg-neutral-950">
          <h1 className="text-2xl font-semibold">ثبت و توسعه ایده</h1>
          <p className="mt-4 leading-8 text-foreground/70">
            برای مشاهده یا ثبت ایده، ابتدا با حساب کاربری خود وارد شوید و سپس
            دوباره به این صفحه بازگردید.
          </p>
          {authError && (
            <p role="alert" className="mt-4 text-sm text-red-700 dark:text-red-300">
              {authError}
            </p>
          )}
          {localRecoveryError && (
            <p role="alert" className="mt-4 text-sm text-amber-800 dark:text-amber-200">
              {localRecoveryError}
            </p>
          )}
          <Link
            href="/"
            className="mt-6 inline-flex min-h-11 items-center rounded-lg border border-foreground/20 px-4 font-medium hover:bg-foreground/5 focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            بازگشت به صفحه اصلی
          </Link>
        </section>
      </main>
    );
  }

  return (
    <main className="flex w-full flex-1 justify-center px-4 py-8 sm:px-6 sm:py-12">
      <div className="w-full max-w-5xl">
        <header className="mb-8">
          <div className="flex flex-col gap-4 rounded-2xl border border-foreground/10 bg-white p-5 shadow-sm dark:bg-neutral-950 sm:flex-row sm:items-center sm:justify-between sm:p-7">
            <div>
              <p className="text-sm font-medium text-foreground/60">جوانه · فضای مشارکت‌کننده</p>
              <h1 className="mt-2 text-3xl font-semibold tracking-tight">
                فضای کار من
              </h1>
              <p className="mt-2 text-sm leading-6 text-foreground/70">
                ایده‌های من <span aria-hidden="true">/</span> مدیریت و ادامه مسیر ایده‌ها
              </p>
            </div>
            <div className="min-w-0 rounded-xl bg-foreground/[0.04] px-4 py-3 sm:max-w-xs">
              <p className="text-xs text-foreground/60">حساب مشارکت‌کننده</p>
              <p className="mt-1 break-all text-sm font-medium" dir="ltr">
                {user.email ??
                  (user.id === initialProfile?.id
                    ? initialProfile.email
                    : null) ??
                  user.id}
              </p>
            </div>
          </div>

          <section
            aria-label="خلاصه سهمیه ایده‌ها"
            className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-3"
          >
            <div className="rounded-xl border border-foreground/10 bg-white p-4 dark:bg-neutral-950">
              <p className="text-sm text-foreground/60">ایده‌های استفاده‌شده</p>
              <p className="mt-1 text-2xl font-semibold">
                {ideasLoaded ? ideas.length : "—"}
              </p>
            </div>
            <div className="rounded-xl border border-foreground/10 bg-white p-4 dark:bg-neutral-950">
              <p className="text-sm text-foreground/60">حداکثر ایده مجاز</p>
              <p className="mt-1 text-2xl font-semibold">{IDEA_QUOTA_LIMIT}</p>
            </div>
            <div className="rounded-xl border border-foreground/10 bg-white p-4 dark:bg-neutral-950">
              <p className="text-sm text-foreground/60">ظرفیت باقی‌مانده</p>
              <p className="mt-1 text-2xl font-semibold">
                {getAvailableIdeaSlots(ideas.length, ideasLoaded) ?? "—"}
              </p>
            </div>
          </section>
        </header>

        {notice && (
          <div
            role={notice.kind === "error" ? "alert" : "status"}
            className={`mb-6 rounded-xl border p-4 text-sm leading-7 ${
              notice.kind === "error"
                ? "border-red-300 bg-red-50 text-red-900 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200"
                : notice.kind === "success"
                  ? "border-green-300 bg-green-50 text-green-900 dark:border-green-900 dark:bg-green-950/40 dark:text-green-200"
                  : "border-foreground/10 bg-foreground/[0.03] text-foreground/80"
            }`}
          >
            {notice.message}
          </div>
        )}

        {pendingCreateStorageError && (
          <p role="alert" className="mb-6 rounded-xl bg-red-50 p-4 text-sm text-red-900">
            {pendingCreateStorageError}
          </p>
        )}

        {!selectedIdea ? (
          <section
            aria-labelledby="ideas-heading"
            className="rounded-2xl border border-foreground/10 bg-white p-5 shadow-sm dark:bg-neutral-950 sm:p-8"
          >
            <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-center">
              <div>
                <h2 id="ideas-heading" className="text-xl font-semibold">
                  ایده‌های من
                </h2>
                <p className="mt-2 text-sm text-foreground/60">
                  برای هر ایده، مرحله فعلی و اقدام بعدی را دنبال کنید. ایده‌های
                  ثبت‌شده نیز تا بررسی انسانی سهمیه شما را اشغال می‌کنند.
                </p>
              </div>
              <button
                type="button"
                onClick={() => void createIdea()}
                disabled={
                  creating ||
                  !createRequestStorageReady ||
                  pendingCreateStorageError !== null ||
                  ideasLoading ||
                  !canCreateIdea(
                    ideas.length,
                    ideasLoaded,
                    pendingCreateRequestId !== null,
                  )
                }
                className="inline-flex min-h-11 items-center justify-center rounded-lg bg-foreground px-5 font-medium text-background transition-opacity hover:opacity-85 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {creating
                  ? "در حال ایجاد…"
                  : pendingCreateRequestId
                    ? "تلاش دوباره برای ایجاد"
                    : "ایجاد ایده جدید"}
              </button>
            </div>

            {ideasError && (
              <div className="mt-6 flex flex-col gap-3 rounded-xl bg-red-50 p-4 text-sm text-red-900 dark:bg-red-950/40 dark:text-red-200 sm:flex-row sm:items-center sm:justify-between">
                <p role="alert">{ideasError}</p>
                <button
                  type="button"
                  onClick={() => void refreshIdeas()}
                  className="min-h-10 rounded-lg border border-current px-4 font-medium"
                >
                  تلاش دوباره
                </button>
              </div>
            )}

            {ideasLoading ? (
              <p role="status" className="py-12 text-center text-foreground/60">
                در حال بارگذاری ایده‌ها…
              </p>
            ) : ideas.length === 0 && !ideasError ? (
              <div className="mt-8 rounded-xl border border-dashed border-foreground/20 px-5 py-12 text-center">
                <h3 className="text-lg font-medium">هنوز ایده‌ای ثبت نشده است</h3>
                <p className="mt-2 text-sm text-foreground/60">
                  با ایجاد ایده، مرحله اول برای شما فعال می‌شود.
                </p>
              </div>
            ) : (
              <ul className="mt-6 divide-y divide-foreground/10">
                {ideas.map((idea) => (
                  <li
                    key={idea.id}
                    className="py-5"
                  >
                    <article className="rounded-xl border border-foreground/10 p-4 sm:p-5">
                      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                        <div className="min-w-0">
                          <h3 className="font-semibold">
                            ایده {idea.id.slice(0, 8)}
                          </h3>
                          <p className="mt-1 text-sm text-foreground/60">
                            شناسه: <span dir="ltr">{idea.id}</span> · نسخه {idea.revision}
                          </p>
                          <p className="mt-3 inline-flex rounded-full bg-foreground/[0.06] px-3 py-1 text-sm font-medium">
                            {idea.status === "submitted"
                              ? "ثبت نهایی‌شده"
                              : idea.completedStageCount === 6
                                ? "مراحل توسعه کامل · آماده ثبت نهایی"
                                : idea.status === "draft"
                                  ? "پیش‌نویس در حال توسعه"
                                  : "در حال توسعه"}
                          </p>
                        </div>
                        <div className="flex flex-wrap gap-2">
                          <button
                            type="button"
                            onClick={() => selectIdea(idea)}
                            className="inline-flex min-h-10 items-center rounded-lg border border-foreground/20 px-4 font-medium hover:bg-foreground/5 focus-visible:outline-2 focus-visible:outline-offset-2"
                          >
                            ادامه کار
                          </button>
                          {idea.status !== "submitted" && (
                            <button
                              type="button"
                              onClick={() => void deleteIdea(idea)}
                              disabled={deleting}
                              className="min-h-10 rounded-lg border border-red-300 px-4 text-sm font-medium text-red-800 hover:bg-red-50 disabled:opacity-50 dark:border-red-900 dark:text-red-200"
                            >
                              حذف دائمی
                            </button>
                          )}
                        </div>
                      </div>

                      <div className="mt-5 grid gap-3 sm:grid-cols-2">
                        <p className="text-sm leading-6">
                          مرحله فعلی:{" "}
                          <span className="font-medium">
                            {IDEA_STAGES[idea.current_step - 1]?.title ??
                              `مرحله ${idea.current_step}`}
                          </span>
                        </p>
                        <p className="text-sm leading-6">
                          وضعیت مرحله:{" "}
                          <span className="font-medium">
                            {idea.status === "submitted"
                              ? "در انتظار بررسی انسانی"
                              : statusLabel(idea.currentStageStatus)}
                          </span>
                        </p>
                        <p className="text-sm leading-6">
                          اقدام بعدی:{" "}
                          <span className="font-medium">
                            {idea.nextAction === "awaiting_review"
                              ? humanEvaluationStatusLabel(
                                  idea.evaluationStatus,
                                )
                              : idea.nextAction === "submit"
                                ? "ثبت نهایی ایده"
                                : idea.nextAction === "confirm"
                                  ? `تأیید مرحله ${idea.current_step}`
                                  : idea.nextAction === "revise"
                                    ? `بازبینی مرحله ${idea.current_step}`
                                    : `ادامه مرحله ${idea.current_step}`}
                          </span>
                        </p>
                      </div>

                      <div className="mt-4">
                        <div className="mb-2 flex items-center justify-between gap-3 text-sm">
                          <span>
                            {idea.completedStageCount} از ۶ مرحله توسعه تکمیل شده
                          </span>
                          {idea.status === "submitted" && (
                            <span className="text-foreground/60">
                              مرحله ۷: بررسی انسانی
                            </span>
                          )}
                        </div>
                        <div
                          role="progressbar"
                          aria-label={`پیشرفت ایده ${idea.id.slice(0, 8)}`}
                          aria-valuemin={0}
                          aria-valuemax={6}
                          aria-valuenow={idea.completedStageCount}
                          className="h-2 overflow-hidden rounded-full bg-foreground/10"
                        >
                          <div
                            className="h-full rounded-full bg-foreground"
                            style={{
                              width: `${(idea.completedStageCount / 6) * 100}%`,
                            }}
                          />
                        </div>
                      </div>
                    </article>
                  </li>
                ))}
              </ul>
            )}
          </section>
        ) : (
          <section className="rounded-2xl border border-foreground/10 bg-white p-5 shadow-sm dark:bg-neutral-950 sm:p-8">
            <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
              <div>
                <button
                  type="button"
                  onClick={returnToIdeas}
                  className="text-sm font-medium text-foreground/65 underline underline-offset-4 hover:text-foreground"
                >
                  بازگشت به ایده‌های من
                </button>
                <h2 className="mt-3 text-xl font-semibold">
                  ایده {selectedIdea.id.slice(0, 8)}
                </h2>
                <p className="mt-1 text-sm text-foreground/60">
                  نسخه پایگاه داده: {revision ?? "—"}
                </p>
                <p
                  role="status"
                  aria-live="polite"
                  className={`mt-1 text-sm ${
                    syncStatus === "failed"
                      ? "text-red-700 dark:text-red-300"
                      : syncStatus === "pending"
                        ? "text-amber-700 dark:text-amber-300"
                        : "text-green-700 dark:text-green-300"
                  }`}
                >
                  {syncStatus === "saved" && !isDirty && pendingSave === null
                    ? "ذخیره‌شده در پایگاه داده"
                    : syncStatus === "pending"
                      ? isOnline
                        ? localRecoveryError
                          ? "در حال تلاش برای ذخیره در پایگاه داده؛ نتیجه هنوز تأیید نشده است"
                          : "در انتظار همگام‌سازی با پایگاه داده؛ نسخه محلی نگه داشته شده است"
                        : localRecoveryError
                          ? "آفلاین؛ تغییرات هنوز با پایگاه داده تأیید نشده و در حافظه محلی نگهداری نشدند"
                          : "آفلاین؛ تغییرات محلی هنوز با پایگاه داده همگام نشده‌اند"
                      : "همگام‌سازی ناموفق است؛ تغییرات محلی نگه داشته شده‌اند و نیاز به بررسی دارند"}
                </p>
              </div>
              <div className="flex flex-wrap gap-2">
                <DossierPreviewEntryPoint
                  disabled={
                    stagesLoading ||
                    stagesError !== null ||
                    ideaStages.length !== 7
                  }
                  onClick={() => setDossierPreviewOpen(true)}
                />
                <DossierHistoryEntryPoint
                  status={selectedIdea.status}
                  isOpen={dossierHistoryOpen}
                  onClick={toggleDossierHistory}
                />
                <button
                  type="button"
                  onClick={() => void reloadSelectedIdea()}
                  disabled={stagesLoading || pendingSave !== null || saving}
                  className="min-h-10 rounded-lg border border-foreground/20 px-4 text-sm font-medium hover:bg-foreground/5 disabled:opacity-50"
                >
                  بارگذاری آخرین نسخه
                </button>
                {selectedIdea.status !== "submitted" && (
                  <button
                    type="button"
                    onClick={() => void deleteIdea()}
                    disabled={
                      deleting ||
                      saving ||
                      confirming ||
                      pendingSave !== null
                    }
                    className="min-h-10 rounded-lg border border-red-300 px-4 text-sm font-medium text-red-800 hover:bg-red-50 disabled:opacity-50 dark:border-red-900 dark:text-red-200"
                  >
                    {deleting ? "در حال حذف…" : "حذف دائمی ایده"}
                  </button>
                )}
              </div>
            </div>

            {dossierPreviewOpen &&
              !stagesLoading &&
              stagesError === null &&
              ideaStages.length === 7 && (
                <DossierPreview
                  key={selectedIdea.id}
                  ideaId={selectedIdea.id}
                  stages={ideaStages}
                  drafts={drafts}
                  syncStatus={syncStatus}
                  pendingSaveStageNumber={
                    pendingSave?.ideaId === selectedIdea.id
                      ? pendingSave.stageNumber
                      : null
                  }
                  conflictStageNumber={draftConflict?.stageNumber ?? null}
                  onClose={() => setDossierPreviewOpen(false)}
                />
              )}

            {selectedIdea.status === "submitted" && (
              <>
                <div
                  role="status"
                  className="mb-4 rounded-xl border border-foreground/10 bg-foreground/[0.03] p-4 text-sm leading-7"
                >
                  {editingWindowActive && selectedIdea.submitted_at ? (
                    <>
                      ویرایش معمول پرونده فعال است؛{" "}
                      {remainingEditingMs < 60_000
                        ? "کمتر از یک دقیقه"
                        : `${Math.floor(remainingEditingMs / 3_600_000)} ساعت و ${Math.floor((remainingEditingMs % 3_600_000) / 60_000)} دقیقه`}{" "}
                      باقی مانده است. این بازه از زمان ثبت نهایی محاسبه می‌شود.
                    </>
                  ) : (
                    "مهلت ویرایش معمول این پرونده پایان یافته است. محتوای آن قفل است و امکان بازگشایی از این مسیر وجود ندارد."
                  )}
                </div>
                <div
                  role="status"
                  className="mb-6 rounded-xl border border-foreground/10 bg-foreground/[0.03] p-4 text-sm leading-7"
                >
                  <p className="font-semibold">وضعیت ارزیابی انسانی</p>
                  <p>{humanEvaluationStatusLabel(selectedIdea.evaluationStatus)}</p>
                </div>
                {selectedIdea.publishedFeedback && (
                  <div className="mb-6 rounded-xl border border-foreground/10 bg-foreground/[0.03] p-4 text-sm leading-7">
                    <p className="mb-2 font-semibold">بازخورد منتشرشده</p>
                    <p className="whitespace-pre-wrap text-foreground/90">
                      {selectedIdea.publishedFeedback.content}
                    </p>
                    <div className="mt-3 flex flex-wrap gap-3 text-xs text-foreground/60">
                      <span>
                        تاریخ انتشار: {new Date(selectedIdea.publishedFeedback.published_at).toLocaleDateString("fa-IR", {
                          dateStyle: "medium",
                        })}
                      </span>
                      <span>
                        نسخه: {selectedIdea.publishedFeedback.version_number}
                      </span>
                    </div>
                  </div>
                )}
              </>
            )}

            {dossierHistoryOpen && selectedIdea.status === "submitted" && (
              <DossierHistoryInspector
                currentRevision={revision ?? selectedIdea.revision}
                state={dossierHistoryState}
                onRetry={() => void loadDossierHistory(selectedIdea.id)}
                onClose={closeDossierHistory}
              />
            )}

            <ParticipantScorecard key={selectedIdea.id} ideaId={selectedIdea.id} />
            <JuryScoreSummary ideaId={selectedIdea.id} />
            <FinalResultSummary ideaId={selectedIdea.id} />
            <MilestoneEvaluationControls ideaId={selectedIdea.id} />

            {stagesError && (
              <div className="mb-6 rounded-xl bg-red-50 p-4 text-sm leading-7 text-red-900 dark:bg-red-950/40 dark:text-red-200">
                <p role="alert">{stagesError}</p>
                <button
                  type="button"
                  onClick={() => void loadStages(selectedIdea)}
                  className="mt-3 min-h-10 rounded-lg border border-current px-4 font-medium"
                >
                  بارگذاری دوباره مراحل
                </button>
              </div>
            )}

            {localRecoveryError && (
              <p
                role="alert"
                className="mb-6 rounded-xl bg-amber-50 p-4 text-sm leading-7 text-amber-950 dark:bg-amber-950/40 dark:text-amber-200"
              >
                {localRecoveryError}
              </p>
            )}

            {draftConflict && (
              <div
                role="alert"
                className="mb-6 rounded-xl border border-amber-500/40 bg-amber-50 p-4 text-sm leading-7 text-amber-950 dark:bg-amber-950/30 dark:text-amber-100"
              >
                <p className="font-semibold">
                  نسخه پایگاه داده از زمان آخرین ذخیره محلی تغییر کرده است.
                  نسخه محلی حفظ شده؛ پیش از ادامه یکی را انتخاب کنید.
                </p>
                <p className="mt-3 font-medium">نسخه پایگاه داده:</p>
                <pre className="mt-1 max-h-48 overflow-auto whitespace-pre-wrap rounded-lg bg-white/70 p-3 font-sans dark:bg-black/20">
                  {draftConflict.serverContent || "محتوا خالی است."}
                </pre>
                <div className="mt-3 flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={useDatabaseVersion}
                    className="min-h-10 rounded-lg border border-current px-4 font-medium"
                  >
                    استفاده از نسخه پایگاه داده
                  </button>
                  <button
                    type="button"
                    onClick={keepLocalVersion}
                    disabled={!stageEditable}
                    className="min-h-10 rounded-lg bg-foreground px-4 font-medium text-background disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    نگه‌داشتن نسخه محلی و همگام‌سازی
                  </button>
                </div>
              </div>
            )}

            {stagesLoading ? (
              <p role="status" className="py-12 text-center text-foreground/60">
                در حال بارگذاری مراحل ایده…
              </p>
            ) : (
              <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,2fr)]">
                <nav aria-label="مراحل ایده">
                  <div className="mb-4 rounded-xl border border-foreground/10 p-4">
                    <p className="text-sm font-medium">پیشرفت مراحل مشارکت‌کننده</p>
                    <p className="mt-1 text-sm text-foreground/65">
                      {confirmedStageCount} از ۶ مرحله تکمیل‌شده ·{" "}
                      {remainingStageCount} باقی‌مانده
                    </p>
                    <p className="mt-1 text-sm text-foreground/65">
                  موقعیت فعلی: مرحله {currentStage} از ۷
                    </p>
                  </div>
                  <ol className="space-y-2">
                    {IDEA_STAGES.map((definition) => {
                      const { number, title } = definition;
                      const stage = ideaStages.find(
                        (item) => item.stage_number === number,
                      );
                      const locked = !stage || stage.status === "locked";
                      const active = currentStage === number;
                      return (
                        <li key={title}>
                          <button
                            type="button"
                            disabled={
                              locked ||
                              pendingSave !== null ||
                              saving ||
                              confirming ||
                              stepSaving
                            }
                            aria-current={active ? "step" : undefined}
                            onClick={() => void selectStage(number)}
                            className={`w-full rounded-xl border p-3 text-start transition-colors disabled:cursor-not-allowed disabled:opacity-50 ${
                              active
                                ? "border-foreground bg-foreground/[0.04]"
                                : "border-foreground/10 hover:bg-foreground/[0.03]"
                            }`}
                          >
                            <span className="flex items-start gap-3">
                              <span className="flex size-8 shrink-0 items-center justify-center rounded-full border border-foreground/20 text-sm font-semibold">
                                {number}
                              </span>
                              <span className="min-w-0">
                                <span className="block leading-6">
                                  {title}
                                  {active && (
                                    <span className="ms-2 text-xs font-medium text-foreground/60">
                                      (مرحله انتخاب‌شده)
                                    </span>
                                  )}
                                </span>
                                <span className="mt-1 block text-xs leading-5 text-foreground/60">
                                  {definition.outcome}
                                </span>
                                <span
                                  className={`mt-2 inline-flex rounded-full px-2 py-0.5 text-xs ${stage ? statusStyle(stage.status) : "bg-foreground/5 text-foreground/60"}`}
                                >
                                  {stage
                                    ? stageStatusLabel(stage, selectedIdea)
                                    : "بارگذاری…"}
                                </span>
                                {stage?.status === "locked" && (
                                  <span className="mt-1 block text-xs leading-5 text-foreground/60">
                                    {number === 7
                                      ? "ویژه بررسی انسانی است و برای شرکت‌کننده قفل می‌ماند."
                                      : "پس از تأیید مرحله پیشین فعال می‌شود."}
                                  </span>
                                )}
                              </span>
                            </span>
                          </button>
                        </li>
                      );
                    })}
                  </ol>
                </nav>

                <div className="min-w-0">
                  {selectedStage ? (
                    <>
                      <div className="mb-5">
                        <p className="text-sm text-foreground/60">
                          مرحله {currentStage} از ۷
                        </p>
                        <h3 className="mt-1 text-xl font-semibold">
                          {
                            IDEA_STAGES.find(
                              (stage) => stage.number === currentStage,
                            )?.title
                          }
                        </h3>
                        <p className="mt-2 text-sm text-foreground/60">
                          وضعیت: {stageStatusLabel(selectedStage, selectedIdea)}
                        </p>
                      </div>

                      {currentStage === 7 ? (
                        <div className="rounded-xl border border-foreground/10 bg-foreground/[0.03] p-5 leading-7 text-foreground/70">
                          {selectedIdea.status === "submitted"
                            ? "مراحل مشارکت‌کننده تکمیل شده‌اند. این ایده در انتظار بررسی انسانی است؛ مرحله هفتم فرم قابل ویرایش نیست."
                            : "این مرحله برای بررسی و ارزیابی انسانی محفوظ است و برای شرکت‌کننده قفل می‌ماند. پس از تأیید شش مرحله و ثبت نهایی، وضعیت آن به انتظار بررسی انسانی تغییر می‌کند."}
                        </div>
                      ) : selectedStage.status === "locked" ? (
                        <p role="status" className="rounded-xl bg-foreground/[0.03] p-5">
                          این مرحله تا تأیید مرحله قبلی قفل است.
                        </p>
                      ) : selectedStage.status === "needs_revision" ? (
                        <p role="status" className="rounded-xl bg-foreground/[0.03] p-5 leading-7">
                          وضعیت این مرحله نیازمند بازبینی است. امکان ویرایش آن
                          تا مشخص شدن فرایند مربوطه فعال نیست.
                        </p>
                      ) : (
                        <>
                          <label
                            htmlFor="stage-content"
                            className="mb-2 block font-medium"
                          >
                            محتوای مرحله
                          </label>
                          <textarea
                            id="stage-content"
                            value={drafts[currentStage] ?? ""}
                            onChange={(event) =>
                              updateDraftContent(event.target.value)
                            }
                            disabled={
                              !stageEditable ||
                              confirming ||
                              stepSaving ||
                              submitting
                            }
                            rows={10}
                            dir="auto"
                            className="w-full resize-y rounded-xl border border-foreground/20 bg-transparent p-4 leading-7 outline-none transition focus:border-foreground/50 focus:ring-2 focus:ring-foreground/10 disabled:cursor-not-allowed disabled:opacity-60"
                            placeholder="محتوای این مرحله را وارد کنید…"
                          />
                          <p className="mt-2 text-xs leading-6 text-foreground/55">
                            {selectedIdea.status === "submitted"
                              ? "تغییرات این پرونده به‌صورت خودکار ذخیره می‌شوند؛ مهلت ویرایش از زمان ثبت نهایی محاسبه می‌شود."
                              : "تغییرات پیش‌نویس پس از مکث کوتاه به‌صورت خودکار ذخیره می‌شوند؛ تأیید مرحله اقدامی جداگانه است."}
                          </p>

                          {currentStage <= 6 && currentMentorGuidance && (
                            <section
                              aria-labelledby="mentor-guidance-title"
                              className="mt-5 rounded-xl border border-foreground/15 bg-foreground/[0.025] p-4 sm:p-5"
                            >
                              <div className="flex flex-wrap items-start justify-between gap-3">
                                <div>
                                  <h4
                                    id="mentor-guidance-title"
                                    className="font-semibold"
                                  >
                                    راهنمای ادامه کار
                                  </h4>
                                  <p className="mt-1 text-sm leading-6 text-foreground/70">
                                    {mentorFallbackActive
                                      ? "حالت فعلی: ادامه بدون هوش مصنوعی"
                                      : mentorAvailability === "restored"
                                        ? "دستیار هوش مصنوعی بازیابی شد"
                                        : mentorAvailability === "checking"
                                          ? "در حال بررسی وضعیت دستیار هوش مصنوعی…"
                                          : mentorAvailability === "not_configured"
                                            ? "دستیار هوش مصنوعی پیکربندی نشده؛ راهنمای بدون هوش مصنوعی آماده است."
                                            : mentorAvailability === "temporarily_unavailable"
                                              ? "دستیار هوش مصنوعی موقتاً در دسترس نیست؛ دسترسی شما به سامانه و ذخیره کارتان ادامه دارد."
                                              : mentorAvailability === "recovery_eligible"
                                                ? "زمان تلاش کنترل‌شده برای بازیابی رسیده است؛ درخواست شما یک probe کم‌هزینه اجرا می‌کند و در صورت موفقیت راهنمای AI را می‌گیرد."
                                                : mentorAvailability === "recovery_in_progress"
                                                  ? "بررسی بازیابی در حال انجام است؛ در همین حال کارتان را ذخیره و ادامه دهید."
                                                  : "حالت فعلی: AI-assisted"}
                                  </p>
                                  {mentorRetryAfterSeconds !== null &&
                                    mentorRetryAfterSeconds > 0 && (
                                      <p className="mt-1 text-xs text-foreground/60">
                                        تلاش دوباره پس از حدود {mentorRetryAfterSeconds} ثانیه ممکن است.
                                      </p>
                                    )}
                                </div>
                                <button
                                  type="button"
                                  onClick={() => void refreshMentorAvailability()}
                                  disabled={mentorAvailability === "checking"}
                                  className="min-h-9 rounded-lg border border-foreground/20 px-3 text-sm hover:bg-foreground/5 disabled:opacity-50"
                                >
                                  بررسی وضعیت AI
                                </button>
                              </div>

                              <p className="mt-3 text-sm leading-7 text-foreground/70">
                                {currentMentorGuidance.summary}
                              </p>
                              <ul className="mt-2 list-disc space-y-1 pe-5 text-sm leading-6 text-foreground/65">
                                {currentMentorGuidance.questions.map((question) => (
                                  <li key={question}>{question}</li>
                                ))}
                              </ul>

                              {mentorSuggestions[currentStage] && (
                                <div
                                  role="status"
                                  className="mt-4 whitespace-pre-line rounded-lg border border-foreground/10 bg-background p-3 text-sm leading-7"
                                >
                                  {mentorSuggestions[currentStage]}
                                </div>
                              )}
                              {mentorErrors[currentStage] && (
                                <p
                                  role="status"
                                  className="mt-3 text-sm leading-6 text-amber-800 dark:text-amber-200"
                                >
                                  {mentorErrors[currentStage]}
                                </p>
                              )}

                              {selectedIdea.status !== "submitted" &&
                                (mentorAvailability === "available" ||
                                  mentorAvailability === "restored" ||
                                  mentorAvailability === "recovery_eligible") && (
                                  <div className="mt-4">
                                    <label
                                      htmlFor="mentor-question"
                                      className="mb-2 block text-sm font-medium"
                                    >
                                      پرسش اختیاری از راهنمای هوش مصنوعی
                                    </label>
                                    <textarea
                                      id="mentor-question"
                                      value={mentorQuestions[currentStage] ?? ""}
                                      onChange={(event) =>
                                        setMentorQuestions((existing) => ({
                                          ...existing,
                                          [currentStage]: event.target.value,
                                        }))
                                      }
                                      maxLength={4_000}
                                      rows={3}
                                      dir="auto"
                                      className="w-full resize-y rounded-lg border border-foreground/20 bg-transparent p-3 leading-6 outline-none focus:border-foreground/50 disabled:opacity-60"
                                      placeholder="پرسش خود را بنویسید؛ محتوای مرحله و پیش‌نویس ذخیره‌شده تغییر نمی‌کند."
                                    />
                                    <div className="mt-3 flex flex-wrap items-center gap-3">
                                      <button
                                        type="button"
                                        onClick={() => void requestMentorGuidance()}
                                        disabled={
                                          !mentorQuestions[currentStage]?.trim() ||
                                          mentorBusyStage !== null ||
                                          !isOnline
                                        }
                                        className="min-h-10 rounded-lg bg-foreground px-4 text-sm font-medium text-background disabled:opacity-50"
                                      >
                                        {mentorBusyStage === currentStage
                                          ? mentorAvailability === "recovery_eligible"
                                            ? "در حال بررسی بازیابی…"
                                            : "در حال دریافت راهنما…"
                                          : mentorAvailability === "recovery_eligible"
                                            ? "آزمودن بازیابی و دریافت راهنما"
                                            : "دریافت راهنمای AI"}
                                      </button>
                                      <p className="text-xs leading-5 text-foreground/55">
                                        پرسش و پاسخ در پرونده ذخیره نمی‌شوند. پیش‌نویس شما از مسیر ذخیره معمول خودکار می‌شود.
                                      </p>
                                    </div>
                                  </div>
                                )}
                            </section>
                          )}

                          <div className="mt-5 flex flex-wrap gap-3">
                            {canRetrySave ? (
                              <button
                                type="button"
                                onClick={() => void saveStage(true)}
                                disabled={saving}
                                className="min-h-11 rounded-lg bg-foreground px-5 font-medium text-background disabled:opacity-50"
                              >
                                {saving ? "در حال تلاش…" : "تلاش دوباره برای ذخیره"}
                              </button>
                            ) : (
                              <button
                                type="button"
                                onClick={() => void saveStage()}
                                disabled={
                                  !stageEditable ||
                                  !isDirty ||
                                  saving ||
                                  pendingSave !== null
                                }
                                className="min-h-11 rounded-lg bg-foreground px-5 font-medium text-background disabled:cursor-not-allowed disabled:opacity-45"
                              >
                                {saving ? "در حال ذخیره…" : "ذخیره تغییرات"}
                              </button>
                            )}

                              {["in_progress", "pending_confirmation"].includes(
                              selectedStage.status,
                            ) && (
                              <button
                                type="button"
                                onClick={() => void confirmStage()}
                                disabled={
                                  isDirty ||
                                  pendingSave !== null ||
                                  confirming ||
                                  saving ||
                                  stepSaving
                                }
                                className="min-h-11 rounded-lg border border-foreground/20 px-5 font-medium hover:bg-foreground/5 disabled:cursor-not-allowed disabled:opacity-45"
                              >
                                {confirming
                                  ? "در حال تأیید…"
                                  : "تأیید و رفتن به مرحله بعد"}
                              </button>
                            )}
                            {currentStage === 6 &&
                              allDevelopmentStagesConfirmed && (
                                  <button
                                    type="button"
                                    onClick={() => void submitIdea()}
                                    disabled={
                                      submitting ||
                                      isDirty ||
                                      pendingSave !== null ||
                                      saving ||
                                      confirming ||
                                      stepSaving
                                    }
                                    className="min-h-11 rounded-lg bg-green-700 px-5 font-medium text-white hover:bg-green-800 disabled:cursor-not-allowed disabled:opacity-50"
                                  >
                                    {submitting
                                      ? "در حال ثبت نهایی…"
                                      : "ثبت نهایی ایده"}
                                  </button>
                              )}
                          </div>

                          {selectedStage.status === "pending_confirmation" && (
                            <p role="status" className="mt-4 text-sm text-foreground/65">
                                  این مرحله در انتظار تأیید نهایی شماست. محتوای
                                  ذخیره‌شده را بازبینی کنید و برای تکمیل مرحله، آن
                                  را تأیید کنید.
                                </p>
                              )}
                        </>
                      )}
                    </>
                  ) : (
                    <p role="status" className="rounded-xl bg-foreground/[0.03] p-5">
                      برای مشاهده محتوای مرحله، آن را از فهرست انتخاب کنید.
                    </p>
                  )}
                </div>
              </div>
            )}
            {(selectedIdea.current_step >= 2 ||
              ideaStages.some(
                (stage) => stage.stage_number === 2 && stage.status !== "locked",
              )) && (
              <ClassificationPanel
                supabase={supabase}
                ideaId={selectedIdea.id}
                eligible={
                  ideaStages.some(
                    (stage) =>
                      stage.stage_number === 1 && stage.status === "confirmed",
                  ) &&
                  ideaStages.some(
                    (stage) =>
                      stage.stage_number === 2 && stage.status === "confirmed",
                  )
                }
                triggerVersion={classificationTriggerVersion}
              />
            )}
          </section>
        )}
      </div>
    </main>
  );
}
