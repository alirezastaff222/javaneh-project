"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { User } from "@supabase/supabase-js";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

const stages = [
  "تعریف مسئله",
  "شناسایی ظرفیت‌های اجتماعی",
  "توسعه و گسترش ایده",
  "طراحی برنامه اجرا",
  "ارزیابی اولیه امکان‌پذیری و تاب‌آوری",
  "آماده‌سازی پرونده ایده",
  "بررسی و ارزیابی انسانی",
] as const;

type IdeaStatus = "draft" | "in_progress" | "submitted";
type StageStatus =
  | "not_started"
  | "in_progress"
  | "pending_confirmation"
  | "confirmed"
  | "needs_revision"
  | "locked";

type Idea = {
  id: string;
  status: IdeaStatus;
  revision: number;
  created_at: string;
  updated_at: string;
};

type IdeaStage = {
  stage_number: number;
  data: Record<string, unknown>;
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
  stageData: Record<string, unknown>;
};

type Notice = {
  message: string;
  kind: "success" | "error" | "info";
};

const knownStageStatuses = new Set<StageStatus>([
  "not_started",
  "in_progress",
  "pending_confirmation",
  "confirmed",
  "needs_revision",
  "locked",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseOutcome(value: unknown): Record<string, unknown> | null {
  return isRecord(value) && typeof value.outcome === "string" ? value : null;
}

function readContent(stage: IdeaStage): string {
  return typeof stage.data.content === "string" ? stage.data.content : "";
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

function statusLabel(status: StageStatus): string {
  switch (status) {
    case "in_progress":
    case "not_started":
      return "در حال انجام";
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

function statusStyle(status: StageStatus): string {
  switch (status) {
    case "confirmed":
      return "bg-green-100 text-green-900 dark:bg-green-950 dark:text-green-200";
    case "in_progress":
    case "not_started":
      return "bg-blue-100 text-blue-900 dark:bg-blue-950 dark:text-blue-200";
    case "pending_confirmation":
      return "bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200";
    case "needs_revision":
      return "bg-orange-100 text-orange-900 dark:bg-orange-950 dark:text-orange-200";
    case "locked":
      return "bg-foreground/5 text-foreground/60";
  }
}

export default function IdeasPage() {
  const supabase = useMemo(() => createClient(), []);
  const [user, setUser] = useState<User | null>(null);
  const [authLoading, setAuthLoading] = useState(true);
  const [authError, setAuthError] = useState<string | null>(null);
  const [ideas, setIdeas] = useState<Idea[]>([]);
  const [ideasLoading, setIdeasLoading] = useState(false);
  const [ideasLoaded, setIdeasLoaded] = useState(false);
  const [ideasError, setIdeasError] = useState<string | null>(null);
  const [selectedIdea, setSelectedIdea] = useState<Idea | null>(null);
  const [stagesLoading, setStagesLoading] = useState(false);
  const [stagesError, setStagesError] = useState<string | null>(null);
  const [ideaStages, setIdeaStages] = useState<IdeaStage[]>([]);
  const [drafts, setDrafts] = useState<Record<number, string>>({});
  const [currentStage, setCurrentStage] = useState(1);
  const [revision, setRevision] = useState<number | null>(null);
  const [creating, setCreating] = useState(false);
  const [saving, setSaving] = useState(false);
  const [confirming, setConfirming] = useState(false);
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

  const createRequestRef = useRef<string | null>(null);
  const createBusyRef = useRef(false);
  const saveBusyRef = useRef(false);
  const confirmBusyRef = useRef(false);
  const pendingSaveRef = useRef<PendingSave | null>(null);
  const handledInitialSelection = useRef(false);
  const activeUserId = useRef<string | null>(null);
  const stageLoadVersion = useRef(0);

  const refreshIdeas = useCallback(async (): Promise<Idea[] | null> => {
    const requestUserId = activeUserId.current;
    if (!requestUserId) return null;
    setIdeasLoading(true);
    setIdeasError(null);
    const { data, error } = await supabase
      .from("ideas")
      .select("id,status,revision,created_at,updated_at")
      .order("updated_at", { ascending: false });
    if (activeUserId.current !== requestUserId) return null;
    setIdeasLoading(false);

    if (error) {
      setIdeasLoaded(false);
      setIdeasError(getErrorMessage(error));
      return null;
    }

    if (
      !Array.isArray(data) ||
      data.some(
        (idea) =>
          !isRecord(idea) ||
          typeof idea.id !== "string" ||
          !["draft", "in_progress", "submitted"].includes(
            String(idea.status),
          ) ||
          !Number.isInteger(idea.revision) ||
          typeof idea.created_at !== "string" ||
          typeof idea.updated_at !== "string",
      )
    ) {
      setIdeasLoaded(false);
      setIdeasError("اطلاعات ایده‌ها از پایگاه داده معتبر نیست.");
      return null;
    }

    const ownedIdeas = data as Idea[];
    setIdeas(ownedIdeas);
    setIdeasLoaded(true);
    return ownedIdeas;
  }, [supabase]);

  const loadStages = useCallback(
    async (idea: Idea): Promise<void> => {
      const requestVersion = ++stageLoadVersion.current;
      setStagesLoading(true);
      setStagesError(null);
      setIdeaStages([]);
      setDrafts({});
      setRevision(idea.revision);

      const { data, error } = await supabase
        .from("idea_stages")
        .select("stage_number,data,status,confirmed_at,updated_at")
        .eq("idea_id", idea.id)
        .order("stage_number", { ascending: true });
      if (requestVersion !== stageLoadVersion.current) return;
      setStagesLoading(false);

      if (error) {
        setStagesError(getErrorMessage(error));
        return;
      }

      if (
        !Array.isArray(data) ||
        data.length !== 7 ||
        data.some(
          (stage, index) =>
            !isRecord(stage) ||
            stage.stage_number !== index + 1 ||
            !isRecord(stage.data) ||
            typeof stage.status !== "string" ||
            !knownStageStatuses.has(stage.status as StageStatus) ||
            (stage.confirmed_at !== null &&
              typeof stage.confirmed_at !== "string") ||
            typeof stage.updated_at !== "string",
        )
      ) {
        setStagesError("وضعیت مراحل ایده معتبر نیست. لطفاً صفحه را تازه‌سازی کنید.");
        return;
      }

      const loadedStages = data as IdeaStage[];
      if (
        loadedStages[6].status !== "locked" ||
        Object.keys(loadedStages[6].data).length !== 0
      ) {
        setStagesError("مرحله هفتم باید قفل و خالی باقی بماند.");
        return;
      }

      setIdeaStages(loadedStages);
      setDrafts(
        Object.fromEntries(
          loadedStages.map((stage) => [
            stage.stage_number,
            readContent(stage),
          ]),
        ),
      );
      setCurrentStage((current) => {
        const selected = loadedStages.find(
          (stage) => stage.stage_number === current && stage.status !== "locked",
        );
        if (selected) return current;
        const firstOpen = loadedStages.find((stage) => stage.status !== "locked");
        return firstOpen?.stage_number ?? 1;
      });
    },
    [supabase],
  );

  useEffect(() => {
    let active = true;
    function updateAuthenticatedUser(nextUser: User | null): void {
      if (activeUserId.current !== (nextUser?.id ?? null)) {
        activeUserId.current = nextUser?.id ?? null;
        stageLoadVersion.current += 1;
        setIdeas([]);
        setIdeasLoading(false);
        setIdeasLoaded(false);
        setIdeasError(null);
        setSelectedIdea(null);
        setStagesLoading(false);
        setIdeaStages([]);
        setDrafts({});
        setRevision(null);
        setPendingCreateRequestId(null);
        setCreateRequestStorageReady(false);
        setPendingCreateStorageError(null);
        setPendingSave(null);
        createRequestRef.current = null;
        pendingSaveRef.current = null;
        createBusyRef.current = false;
        saveBusyRef.current = false;
        confirmBusyRef.current = false;
        setCreating(false);
        setSaving(false);
        setConfirming(false);
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
    void Promise.resolve().then(() => refreshIdeas());
  }, [user, refreshIdeas]);

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
  const isDirty =
    selectedStage !== undefined &&
    drafts[currentStage] !== readContent(selectedStage);
  const stageEditable =
    selectedStage !== undefined &&
    ["not_started", "in_progress", "pending_confirmation", "confirmed"].includes(
      selectedStage.status,
    ) &&
    currentStage >= 1 &&
    currentStage <= 6 &&
    selectedIdea?.status !== "submitted";
  const canRetrySave =
    pendingSave !== null &&
    pendingSave.ideaId === selectedIdea?.id &&
    pendingSave.stageNumber === currentStage;

  function selectIdea(idea: Idea): void {
    if (pendingSaveRef.current) {
      setNotice({
        kind: "error",
        message: "پیش از جابه‌جایی، درخواست ذخیره نامشخص را دوباره ارسال کنید.",
      });
      return;
    }
    stageLoadVersion.current += 1;
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
    if (pendingSaveRef.current) {
      setNotice({
        kind: "error",
        message: "پیش از ترک ایده، درخواست ذخیره نامشخص را دوباره ارسال کنید.",
      });
      return;
    }
    stageLoadVersion.current += 1;
    setSelectedIdea(null);
    setIdeaStages([]);
    setDrafts({});
    setStagesLoading(false);
    setNotice(null);
    setStagesError(null);
    window.history.replaceState(null, "", "/ideas");
    void refreshIdeas();
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

  async function saveStage(retry = false): Promise<void> {
    if (
      saveBusyRef.current ||
      !user ||
      !selectedIdea ||
      revision === null ||
      !selectedStage ||
      !stageEditable
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
      };
      pendingSaveRef.current = request;
      setPendingSave(request);
    }

    saveBusyRef.current = true;
    setSaving(true);
    setNotice({
      kind: "info",
      message: retry ? "در حال تکرار همان درخواست ذخیره…" : "در حال ذخیره مرحله…",
    });

    try {
      const { data, error } = await supabase.rpc("save_idea_content", {
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

      if (activeUserId.current !== user.id) return;
      if (error) {
        setNotice({ kind: "error", message: getErrorMessage(error) });
        return;
      }

      const result = parseOutcome(data);
      if (!result) {
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
        const contentApplied =
          outcome === "applied" ||
          (outcome === "replayed" &&
            result.original_outcome === "applied");
        if (contentApplied) {
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
                    status: contentApplied
                      ? stage.status === "confirmed" ||
                        stage.status === "not_started" ||
                        stage.status === "pending_confirmation"
                        ? "in_progress"
                        : stage.status
                      : stage.status,
                    confirmed_at:
                      contentApplied && stage.status === "confirmed"
                        ? null
                        : stage.confirmed_at,
                }
              : stage,
          ),
        );
        pendingSaveRef.current = null;
        setPendingSave(null);
        setNotice({
          kind: "success",
          message:
            outcome === "no_op"
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
      } else if (
        outcome === "idempotency_key_reuse" ||
        outcome === "not_found_or_not_owned" ||
        outcome === "invalid_state" ||
        outcome === "invalid_input"
      ) {
        pendingSaveRef.current = null;
        setPendingSave(null);
      }
      setNotice({ kind: "error", message: outcomeMessage(outcome) });
    } catch {
      setNotice({
        kind: "error",
        message:
          "پاسخ شبکه دریافت نشد. دکمه تلاش مجدد همان شناسه و محتوای درخواست را حفظ می‌کند.",
      });
    } finally {
      setSaving(false);
      saveBusyRef.current = false;
    }
  }

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
        await loadStages(selectedIdea);
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
      message: "آخرین نسخه پایگاه داده بارگذاری شد؛ تغییرات ذخیره‌نشده جایگزین شدند.",
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
          <p className="text-sm font-medium text-foreground/60">جوانه</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight">
            ثبت و توسعه ایده
          </h1>
          <p className="mt-3 max-w-3xl leading-7 text-foreground/70">
            ایده‌ها و مراحل ذخیره‌شده شما از پایگاه داده بارگذاری می‌شوند. هر
            تغییر با نسخه‌بندی و کنترل هم‌زمانی ذخیره خواهد شد.
          </p>
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
                  ایجاد ایده و محدودیت تعداد، در پایگاه داده کنترل می‌شود.
                </p>
              </div>
              <button
                type="button"
                onClick={() => void createIdea()}
                disabled={
                  creating ||
                  !createRequestStorageReady ||
                  pendingCreateStorageError !== null ||
                  ideasLoading
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
                    className="flex flex-col gap-3 py-5 sm:flex-row sm:items-center sm:justify-between"
                  >
                    <div>
                      <p className="font-medium">
                        ایده {idea.id.slice(0, 8)}
                      </p>
                      <p className="mt-1 text-sm text-foreground/60">
                        نسخه {idea.revision} ·{" "}
                        {idea.status === "draft"
                          ? "پیش‌نویس"
                          : idea.status === "in_progress"
                            ? "در حال توسعه"
                            : "ثبت‌شده"}
                      </p>
                    </div>
                    <button
                      type="button"
                      onClick={() => selectIdea(idea)}
                      className="min-h-10 rounded-lg border border-foreground/20 px-4 font-medium hover:bg-foreground/5 focus-visible:outline-2 focus-visible:outline-offset-2"
                    >
                      باز کردن ایده
                    </button>
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
              </div>
              <button
                type="button"
                onClick={() => void reloadSelectedIdea()}
                disabled={stagesLoading || pendingSave !== null || saving}
                className="min-h-10 rounded-lg border border-foreground/20 px-4 text-sm font-medium hover:bg-foreground/5 disabled:opacity-50"
              >
                بارگذاری آخرین نسخه
              </button>
            </div>

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

            {stagesLoading ? (
              <p role="status" className="py-12 text-center text-foreground/60">
                در حال بارگذاری مراحل ایده…
              </p>
            ) : (
              <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,2fr)]">
                <nav aria-label="مراحل ایده">
                  <ol className="space-y-2">
                    {stages.map((title, index) => {
                      const number = index + 1;
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
                              confirming
                            }
                            aria-current={active ? "step" : undefined}
                            onClick={() => setCurrentStage(number)}
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
                                <span className="block leading-6">{title}</span>
                                <span
                                  className={`mt-2 inline-flex rounded-full px-2 py-0.5 text-xs ${stage ? statusStyle(stage.status) : "bg-foreground/5 text-foreground/60"}`}
                                >
                                  {stage ? statusLabel(stage.status) : "بارگذاری…"}
                                </span>
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
                          {stages[currentStage - 1]}
                        </h3>
                        <p className="mt-2 text-sm text-foreground/60">
                          وضعیت: {statusLabel(selectedStage.status)}
                        </p>
                      </div>

                      {currentStage === 7 ? (
                        <div className="rounded-xl border border-foreground/10 bg-foreground/[0.03] p-5 leading-7 text-foreground/70">
                          این مرحله برای بررسی و ارزیابی انسانی محفوظ است و در
                          این نسخه برای شرکت‌کننده قفل می‌ماند.
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
                              setDrafts((existing) => ({
                                ...existing,
                                [currentStage]: event.target.value,
                              }))
                            }
                            disabled={
                              !stageEditable ||
                              saving ||
                              pendingSave !== null ||
                              confirming
                            }
                            rows={10}
                            dir="auto"
                            className="w-full resize-y rounded-xl border border-foreground/20 bg-transparent p-4 leading-7 outline-none transition focus:border-foreground/50 focus:ring-2 focus:ring-foreground/10 disabled:cursor-not-allowed disabled:opacity-60"
                            placeholder="محتوای این مرحله را وارد کنید…"
                          />
                          <p className="mt-2 text-xs leading-6 text-foreground/55">
                            محتوای هر مرحله به‌صورت پیش‌نویس ذخیره می‌شود؛
                            تأیید مرحله اقدامی جداگانه است.
                          </p>

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
                                  saving
                                }
                                className="min-h-11 rounded-lg border border-foreground/20 px-5 font-medium hover:bg-foreground/5 disabled:cursor-not-allowed disabled:opacity-45"
                              >
                                {confirming
                                  ? "در حال تأیید…"
                                  : "تأیید و رفتن به مرحله بعد"}
                              </button>
                            )}
                          </div>

                          {selectedStage.status === "pending_confirmation" && (
                            <p role="status" className="mt-4 text-sm text-foreground/65">
                              درخواست تأیید قبلاً ثبت شده است. پس از بازبینی
                              محتوای ذخیره‌شده، مرحله را دوباره تأیید کنید.
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
          </section>
        )}
      </div>
    </main>
  );
}
