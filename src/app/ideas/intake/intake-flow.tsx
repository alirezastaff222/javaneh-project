"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useState, useSyncExternalStore } from "react";
import {
  buildInitialIdeaContent,
  IntakeRegistrationError,
  registerInitialIdea,
  type InitialIdeaIntakeAnswers,
  type IntakeRegistrationOperation,
  type IntakeRpcClient,
} from "@/lib/ideas/intake";
import { createClient } from "@/lib/supabase/client";

type IntakeStep = 0 | 1;

type SavedIntake = {
  version: 1;
  answers: InitialIdeaIntakeAnswers;
  step: IntakeStep;
  operation: IntakeRegistrationOperation | null;
  registeredIdeaId: string | null;
};

const intakeStorageEvent = "javaneh:intake-storage-change";

const emptyAnswers: InitialIdeaIntakeAnswers = {
  title: "",
  initialDescription: "",
  problem: "",
  affectedPeople: "",
  observation: "",
};

function storageKey(participantId: string): string {
  return `javaneh.idea-intake.v1:${participantId}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseSavedIntake(value: string | null): SavedIntake | null {
  if (!value) return null;
  try {
    const parsed: unknown = JSON.parse(value);
    if (
      !isRecord(parsed) ||
      parsed.version !== 1 ||
      (parsed.step !== 0 && parsed.step !== 1) ||
      (parsed.registeredIdeaId !== null &&
        typeof parsed.registeredIdeaId !== "string")
    ) {
      return null;
    }

    const parsedAnswers = parsed.answers;
    if (!isRecord(parsedAnswers)) return null;
    const answerKeys = Object.keys(emptyAnswers) as Array<
      keyof InitialIdeaIntakeAnswers
    >;
    if (answerKeys.some((key) => typeof parsedAnswers[key] !== "string")) {
      return null;
    }

    let operation: IntakeRegistrationOperation | null = null;
    if (parsed.operation !== null) {
      const savedOperation = parsed.operation;
      if (
        !isRecord(savedOperation) ||
        typeof savedOperation.createRequestId !== "string" ||
        typeof savedOperation.saveRequestId !== "string" ||
        (savedOperation.ideaId !== null &&
          typeof savedOperation.ideaId !== "string") ||
        (savedOperation.expectedRevision !== null &&
          (!Number.isInteger(savedOperation.expectedRevision) ||
            Number(savedOperation.expectedRevision) < 1))
      ) {
        return null;
      }
      operation = {
        createRequestId: savedOperation.createRequestId,
        saveRequestId: savedOperation.saveRequestId,
        ideaId: savedOperation.ideaId,
        expectedRevision:
          savedOperation.expectedRevision === null
            ? null
            : Number(savedOperation.expectedRevision),
      };
    }

    return {
      version: 1,
      answers: Object.fromEntries(
        answerKeys.map((key) => [key, parsedAnswers[key]]),
      ) as InitialIdeaIntakeAnswers,
      step: parsed.step,
      operation,
      registeredIdeaId: parsed.registeredIdeaId,
    };
  } catch {
    return null;
  }
}

function createIntakeRpcClient(
  supabase: ReturnType<typeof createClient>,
): IntakeRpcClient {
  return {
    async rpc(name, parameters) {
      switch (name) {
        case "create_idea":
          return supabase.rpc("create_idea", {
            p_request_id: String(parameters.p_request_id),
          });
        case "save_idea_content":
          return supabase.rpc("save_idea_content", {
            p_idea_id: String(parameters.p_idea_id),
            p_request_id: String(parameters.p_request_id),
            p_expected_revision: Number(parameters.p_expected_revision),
            p_stage_updates: parameters.p_stage_updates as never,
          });
        case "request_idea_stage_confirmation":
          return supabase.rpc("request_idea_stage_confirmation", {
            p_idea_id: String(parameters.p_idea_id),
            p_stage_number: 1,
          });
        case "confirm_idea_stage":
          return supabase.rpc("confirm_idea_stage", {
            p_idea_id: String(parameters.p_idea_id),
            p_stage_number: 1,
            p_expected_revision: Number(parameters.p_expected_revision),
          });
        default:
          throw new Error("Unsupported intake operation");
      }
    },
    async loadIdeaRevision(ideaId) {
      const { data, error } = await supabase
        .from("ideas")
        .select("revision")
        .eq("id", ideaId)
        .maybeSingle();
      return !error && data && Number.isInteger(data.revision)
        ? data.revision
        : null;
    },
  };
}

function registrationErrorMessage(error: unknown): string {
  if (!(error instanceof IntakeRegistrationError)) {
    return "ارتباط با سامانه کامل نشد. همان ثبت با شناسهٔ امن قبلی قابل تلاش دوباره است.";
  }
  if (error.phase === "create" && error.outcome === "quota_exceeded") {
    return "سهمیهٔ سه ایدهٔ فعال شما تکمیل است. یک ایدهٔ قابل حذف را از فضای کار مدیریت کنید و سپس همین ثبت را دوباره انجام دهید.";
  }
  if (error.phase === "create") {
    return "ایده هنوز ایجاد نشد یا وضعیت ایجاد آن روشن نیست. برای جلوگیری از ثبت تکراری، همان درخواست را دوباره امتحان کنید.";
  }
  if (error.phase === "save") {
    return "ایده ایجاد شده، اما ذخیرهٔ شرح اولیه تأیید نشد. اطلاعات شما حفظ شده است؛ همان ثبت را دوباره امتحان کنید.";
  }
  if (error.outcome === "stale_revision") {
    return "نسخهٔ ایده تغییر کرده است. فضای کار را باز کنید و آخرین نسخه را بررسی کنید.";
  }
  return "ذخیرهٔ اولیه انجام شده، اما تأیید مرحله کامل نشد. همان درخواست را دوباره امتحان کنید.";
}

export default function IntakeFlow({
  initialIdea,
  participantId,
}: {
  initialIdea: string;
  participantId: string;
}) {
  const router = useRouter();
  const supabase = useMemo(() => createClient(), []);
  const rpcClient = useMemo(() => createIntakeRpcClient(supabase), [supabase]);
  const key = storageKey(participantId);
  const subscribe = useMemo(
    () => (notify: () => void) => {
      window.addEventListener(intakeStorageEvent, notify);
      window.addEventListener("storage", notify);
      return () => {
        window.removeEventListener(intakeStorageEvent, notify);
        window.removeEventListener("storage", notify);
      };
    },
    [],
  );
  const getSnapshot = useMemo(
    () => () => {
      try {
        return window.sessionStorage.getItem(key);
      } catch {
        return null;
      }
    },
    [key],
  );
  const savedValue = useSyncExternalStore(subscribe, getSnapshot, () => null);
  const [localOverride, setLocalOverride] = useState<SavedIntake | null>(null);
  const initialSession: SavedIntake = {
    version: 1,
    answers: {
      ...emptyAnswers,
      initialDescription: initialIdea.trim().slice(0, 1_200),
    },
    step: 0,
    operation: null,
    registeredIdeaId: null,
  };
  const session =
    localOverride ?? parseSavedIntake(savedValue) ?? initialSession;
  const { answers, step, operation, registeredIdeaId } = session;
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");
  const [storageError, setStorageError] = useState("");

  const operationLocked = operation?.ideaId !== null && operation !== null;
  const progress = step === 0 ? 50 : 100;

  function persistSession(nextSession: SavedIntake): boolean {
    setLocalOverride(nextSession);
    try {
      window.sessionStorage.setItem(key, JSON.stringify(nextSession));
      window.dispatchEvent(new Event(intakeStorageEvent));
      setStorageError("");
      return true;
    } catch {
      setStorageError(
        "ذخیرهٔ موقت این تب در دسترس نیست؛ برای محافظت از نوشته‌ها تا زمان ثبت، صفحه را نبندید.",
      );
      return false;
    }
  }

  function updateAnswer<K extends keyof InitialIdeaIntakeAnswers>(
    field: K,
    value: InitialIdeaIntakeAnswers[K],
  ): void {
    persistSession({
      ...session,
      answers: { ...answers, [field]: value },
    });
    setError("");
  }

  function validateStep(): boolean {
    if (step === 0) {
      if (answers.title.trim().length < 3) {
        setError("یک عنوان کوتاه و روشن برای ایده بنویسید.");
        return false;
      }
      if (!answers.initialDescription.trim()) {
        setError("در چند جمله بگویید ایدهٔ اولیه‌تان چیست.");
        return false;
      }
    } else if (answers.problem.trim().length < 10) {
      setError("مسئله‌ای را که می‌خواهید به آن پاسخ دهید کمی بیشتر توضیح دهید.");
      return false;
    }
    setError("");
    return true;
  }

  function moveNext(): void {
    if (!validateStep()) return;
    persistSession({ ...session, step: 1 });
  }

  function moveBack(): void {
    setError("");
    persistSession({ ...session, step: 0 });
  }

  async function submitInitialIdea(): Promise<void> {
    if (submitting || registeredIdeaId || !validateStep()) return;
    let activeOperation = operation;
    if (!activeOperation) {
      activeOperation = {
        createRequestId: globalThis.crypto.randomUUID(),
        saveRequestId: globalThis.crypto.randomUUID(),
        ideaId: null,
        expectedRevision: null,
      };
    }
    const content = buildInitialIdeaContent(answers);
    if (
      !persistSession({
        version: 1,
        answers,
        step,
        operation: activeOperation,
        registeredIdeaId: null,
      })
    ) {
      setError("ثبت تا وقتی ذخیرهٔ موقت این تب فعال نشده آغاز نمی‌شود.");
      return;
    }

    setSubmitting(true);
    setError("");
    try {
      const result = await registerInitialIdea(
        rpcClient,
        content,
        activeOperation,
        (nextOperation) => {
          if (
            !persistSession({
              version: 1,
              answers,
              step,
              operation: nextOperation,
              registeredIdeaId: null,
            })
          ) {
            throw new IntakeRegistrationError(
              "create",
              "recovery_storage_failed",
            );
          }
          activeOperation = nextOperation;
        },
      );
      persistSession({
        version: 1,
        answers,
        step,
        operation: activeOperation,
        registeredIdeaId: result.ideaId,
      });
      persistSession({
        version: 1,
        answers,
        step,
        operation: activeOperation,
        registeredIdeaId: result.ideaId,
      });
    } catch (registrationError) {
      setError(registrationErrorMessage(registrationError));
    } finally {
      setSubmitting(false);
    }
  }

  function continueWithMentor(): void {
    if (!registeredIdeaId) return;
    router.push(`/ideas?idea=${encodeURIComponent(registeredIdeaId)}`);
  }

  function continueLater(): void {
    if (!registeredIdeaId) return;
    router.push(`/ideas?idea=${encodeURIComponent(registeredIdeaId)}`);
  }

  function startAnotherIdea(): void {
    persistSession({
      version: 1,
      answers: emptyAnswers,
      step: 0,
      operation: null,
      registeredIdeaId: null,
    });
    setError("");
  }

  return (
    <main className="intake-shell min-h-screen px-4 py-4 sm:px-7 sm:py-6" dir="rtl">
      <div className="intake-backdrop" aria-hidden="true">
        <div className="home-light-ring" />
        <div className="home-dot-field" />
        <span className="auth-orb auth-orb-green" />
        <span className="auth-orb auth-orb-red" />
      </div>
      <div className="relative mx-auto flex min-h-[calc(100svh-2rem)] max-w-5xl flex-col">
        <header className="flex items-center justify-between gap-4">
          <Link href="/" className="inline-flex items-center gap-2.5" aria-label="بازگشت به جوانه">
            <span className="home-mark" aria-hidden="true">J</span>
            <span className="text-sm font-semibold text-white">جوانه</span>
          </Link>
          <Link href="/ideas" className="text-sm text-white/60 underline underline-offset-4 hover:text-white">
            ایده‌های من
          </Link>
        </header>

        <div className="my-7 flex flex-1 items-start justify-center sm:my-10">
          <section className="intake-card w-full max-w-3xl overflow-hidden rounded-[1.7rem]">
            <div className="border-b border-white/[0.08] px-5 py-5 sm:px-8 sm:py-6">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <p className="intake-eyebrow text-xs font-medium">
                    {registeredIdeaId
                      ? "ایده در فضای کار شما ذخیره شد"
                      : `شناخت اولیه · گام ${step + 1} از ۲`}
                  </p>
                  <h1 className="mt-1.5 text-lg font-semibold text-white sm:text-xl">
                    {registeredIdeaId
                      ? "از ایدهٔ اولیه تا قدم بعدی"
                      : step === 0
                        ? "ایدهٔ اولیه‌تان چیست؟"
                        : "می‌خواهید چه مسئله‌ای را بهتر کنید؟"}
                  </h1>
                </div>
                {!registeredIdeaId && (
                  <span className="shrink-0 text-xs text-white/50">حدود ۵ دقیقه</span>
                )}
              </div>
              {!registeredIdeaId && (
                <div
                  className="intake-progress mt-4"
                  role="progressbar"
                  aria-valuenow={progress}
                  aria-valuemin={0}
                  aria-valuemax={100}
                  aria-label="پیشرفت دو گام نخست"
                >
                  <span style={{ width: `${progress}%` }} />
                </div>
              )}
            </div>

            <div className="px-5 py-6 sm:px-8 sm:py-8">
              {registeredIdeaId ? (
                <div className="space-y-5">
                  <p className="text-sm leading-7 text-white/70">
                    «{answers.title.trim()}» ذخیره شد و تعریف اولیهٔ مسئله‌اش را تأیید کردید. این ثبت اولیه به معنی ارسال نهایی یا ارزیابی انسانی نیست.
                  </p>
                  <div className="intake-review rounded-xl p-4">
                    <p className="text-xs text-white/45">مرحلهٔ بعدی</p>
                    <p className="mt-1 text-sm leading-7 text-white/80">
                      شناسایی افراد، گروه‌ها، توانمندی‌ها و منابعی که می‌توانند به ایده کمک کنند.
                    </p>
                  </div>
                  <div className="grid gap-3">
                    <button
                      type="button"
                      onClick={continueWithMentor}
                      className="home-submit inline-flex min-h-12 items-center justify-center rounded-xl px-5 text-sm font-semibold text-[#07120d]"
                    >
                      ادامهٔ همین ایده با منتور هوشمند
                    </button>
                    <button
                      type="button"
                      onClick={continueLater}
                      className="intake-final-choice min-h-11"
                    >
                      بعداً ادامه می‌دهم
                    </button>
                    <button
                      type="button"
                      onClick={startAnotherIdea}
                      className="intake-final-choice min-h-11"
                    >
                      ثبت یک ایدهٔ جدید
                    </button>
                  </div>
                  <p className="text-xs leading-6 text-white/45">
                    ادامهٔ هوشمند اختیاری است؛ در فضای کار هم می‌توانید بدون AI پیش بروید.
                  </p>
                </div>
              ) : (
                <>
                  {step === 0 ? (
                    <div className="space-y-5">
                      <p className="text-sm leading-7 text-white/60">
                        لازم نیست ایده کامل باشد یا متن رسمی بنویسید. در دو گام اول، فقط هستهٔ ایده و مسئله را روشن می‌کنیم؛ جزئیات را بعداً با راهنمایی مرحله‌به‌مرحله تکمیل می‌کنید.
                      </p>
                      <div>
                        <label htmlFor="intake-title" className="intake-label">
                          عنوان کوتاه ایده
                        </label>
                        <input
                          id="intake-title"
                          value={answers.title}
                          onChange={(event) => updateAnswer("title", event.target.value)}
                          maxLength={120}
                          disabled={operationLocked || submitting}
                          className="intake-input"
                          placeholder="مثلاً: شبکهٔ همیاری محله"
                        />
                      </div>
                      <div>
                        <label htmlFor="intake-description" className="intake-label">
                          ایدهٔ اولیه در چند جمله
                        </label>
                        <textarea
                          id="intake-description"
                          value={answers.initialDescription}
                          onChange={(event) => updateAnswer("initialDescription", event.target.value)}
                          maxLength={1_200}
                          disabled={operationLocked || submitting}
                          rows={5}
                          dir="auto"
                          className="intake-input min-h-32 resize-y leading-7 placeholder:text-white/30"
                          placeholder="چه چیزی دوست دارید تغییر کند یا امکان‌پذیر شود؟"
                        />
                      </div>
                    </div>
                  ) : (
                    <div className="space-y-5">
                      <p className="text-sm leading-7 text-white/60">
                        تجربهٔ خودتان را بنویسید؛ اگر هنوز دربارهٔ بخشی مطمئن نیستید، می‌توانید آن را خالی بگذارید.
                      </p>
                      <div>
                        <label htmlFor="intake-problem" className="intake-label">
                          مسئله یا نیازی که ایده به آن پاسخ می‌دهد
                        </label>
                        <textarea
                          id="intake-problem"
                          value={answers.problem}
                          onChange={(event) => updateAnswer("problem", event.target.value)}
                          maxLength={1_000}
                          disabled={operationLocked || submitting}
                          rows={4}
                          dir="auto"
                          className="intake-input min-h-28 resize-y leading-7 placeholder:text-white/30"
                          placeholder="چه اتفاقی می‌افتد و چرا مهم است؟"
                        />
                      </div>
                      <div>
                        <label htmlFor="intake-affected" className="intake-label">
                          چه کسانی بیشتر با این مسئله روبه‌رو هستند؟ <span className="text-white/40">اختیاری</span>
                        </label>
                        <input
                          id="intake-affected"
                          value={answers.affectedPeople}
                          onChange={(event) => updateAnswer("affectedPeople", event.target.value)}
                          maxLength={600}
                          disabled={operationLocked || submitting}
                          className="intake-input"
                          placeholder="اگر می‌دانید، یک گروه یا موقعیت را نام ببرید"
                        />
                      </div>
                      <div>
                        <label htmlFor="intake-observation" className="intake-label">
                          چه مشاهده یا تجربه‌ای باعث شد به این موضوع فکر کنید؟ <span className="text-white/40">اختیاری</span>
                        </label>
                        <textarea
                          id="intake-observation"
                          value={answers.observation}
                          onChange={(event) => updateAnswer("observation", event.target.value)}
                          maxLength={700}
                          disabled={operationLocked || submitting}
                          rows={3}
                          dir="auto"
                          className="intake-input resize-y leading-7 placeholder:text-white/30"
                          placeholder="یک نمونهٔ واقعی یا چیزی که هنوز باید بررسی شود"
                        />
                      </div>
                      <div className="intake-demo-note rounded-xl px-4 py-3 text-xs leading-6">
                        با انتخاب «ثبت اولیه»، همین پاسخ‌ها به‌عنوان پیش‌نویس ایده ذخیره و مرحلهٔ تعریف مسئله برای ادامه باز می‌شود. هنوز چیزی برای ارزیابی انسانی ارسال نمی‌شود.
                      </div>
                    </div>
                  )}

                  {storageError && (
                    <p role="alert" className="intake-error mt-5">{storageError}</p>
                  )}
                  {error && (
                    <div role="alert" className="intake-error mt-5 space-y-3">
                      <p>{error}</p>
                      {error.includes("سهمیهٔ سه ایده") && (
                        <Link href="/ideas" className="inline-block underline underline-offset-4">
                          مدیریت ایده‌ها و حذف مورد مجاز
                        </Link>
                      )}
                    </div>
                  )}

                  <div className="mt-7 flex flex-col-reverse gap-3 border-t border-white/[0.08] pt-5 sm:flex-row sm:items-center sm:justify-between">
                    {step === 0 ? (
                      <span />
                    ) : (
                      <button
                        type="button"
                        onClick={moveBack}
                        disabled={operationLocked || submitting}
                        className="intake-back-button disabled:opacity-50"
                      >
                        گام قبل
                      </button>
                    )}
                    {step === 0 ? (
                      <button
                        type="button"
                        onClick={moveNext}
                        disabled={submitting}
                        className="home-submit inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-5 text-sm font-semibold text-[#07120d] disabled:opacity-50"
                      >
                        ادامه به شناخت مسئله <span aria-hidden="true">←</span>
                      </button>
                    ) : (
                      <button
                        type="button"
                        onClick={() => void submitInitialIdea()}
                        disabled={submitting || registeredIdeaId !== null}
                        className="home-submit inline-flex min-h-11 items-center justify-center rounded-xl px-5 text-sm font-semibold text-[#07120d] disabled:opacity-50"
                      >
                        {submitting
                          ? "در حال ذخیره و تأیید مرحله…"
                          : operation?.ideaId
                            ? "تلاش دوباره برای تکمیل ثبت"
                            : "ثبت اولیه و ادامه"}
                      </button>
                    )}
                  </div>
                </>
              )}
            </div>
          </section>
        </div>

        <footer className="flex flex-col gap-2 border-t border-white/10 py-4 text-[0.68rem] text-white/40 sm:flex-row sm:justify-between">
          <span>جوانه · همراه رشد ایده‌ها</span>
          <span>دو گام نخست حدود ۵ دقیقه؛ نسخهٔ اولیهٔ پرونده حدود ۱۵ دقیقه، با امکان مکث و ادامه</span>
        </footer>
      </div>
    </main>
  );
}