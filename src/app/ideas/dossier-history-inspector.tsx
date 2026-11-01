import type { DossierHistorySnapshot } from "@/lib/ideas/dossier-history";
import type { IdeaStatus } from "@/lib/ideas/portfolio";
import { IDEA_STAGES } from "@/lib/ideas/stages";

export type DossierHistoryViewState =
  | { kind: "loading" }
  | { kind: "error" }
  | { kind: "loaded"; history: DossierHistorySnapshot[] };

export function DossierHistoryEntryPoint({
  status,
  isOpen,
  onClick,
}: {
  status: IdeaStatus;
  isOpen: boolean;
  onClick(): void;
}) {
  if (status !== "submitted") return null;

  return (
    <button
      type="button"
      onClick={onClick}
      className="min-h-10 rounded-lg border border-foreground/20 px-4 text-sm font-medium hover:bg-foreground/5"
    >
      {isOpen ? "بستن سابقه نسخه‌ها" : "مشاهده سابقه نسخه‌ها"}
    </button>
  );
}

export default function DossierHistoryInspector({
  currentRevision,
  state,
  onRetry,
  onClose,
}: {
  currentRevision: number;
  state: DossierHistoryViewState;
  onRetry(): void;
  onClose(): void;
}) {
  return (
    <section
      aria-labelledby="dossier-history-heading"
      className="mb-6 rounded-xl border border-foreground/10 p-4 sm:p-5"
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 id="dossier-history-heading" className="font-semibold">
            سابقه نسخه‌های قبلی پرونده
          </h3>
          <p className="mt-1 text-sm leading-6 text-foreground/65">
            نسخه جاری {currentRevision} جدا از این فهرست است؛ موارد زیر فقط
            تصویرهای پیش از ویرایش‌های موفق هستند.
          </p>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="min-h-10 rounded-lg border border-foreground/20 px-3 text-sm font-medium hover:bg-foreground/5"
        >
          بستن سابقه
        </button>
      </div>

      {state.kind === "loading" ? (
        <p role="status" className="mt-4 py-5 text-sm text-foreground/65">
          در حال بارگذاری سابقه نسخه‌ها…
        </p>
      ) : state.kind === "error" ? (
        <div className="mt-4 flex flex-col gap-3 rounded-lg bg-red-50 p-4 text-sm text-red-900 dark:bg-red-950/40 dark:text-red-200 sm:flex-row sm:items-center sm:justify-between">
          <p role="alert">سابقه نسخه‌ها بارگذاری نشد. دوباره تلاش کنید.</p>
          <button
            type="button"
            onClick={onRetry}
            className="min-h-10 rounded-lg border border-current px-4 font-medium"
          >
            تلاش دوباره
          </button>
        </div>
      ) : state.history.length === 0 ? (
        <p
          role="status"
          className="mt-4 rounded-lg bg-foreground/[0.03] p-4 text-sm leading-7 text-foreground/70"
        >
          هیچ نسخه قبلی ذخیره‌شده‌ای برای نمایش وجود ندارد. نسخه اولیه ثبت نهایی
          به‌صورت خودکار در این سابقه ساخته نمی‌شود.
        </p>
      ) : (
        <ol className="mt-4 divide-y divide-foreground/10">
          {state.history.map((snapshot) => (
            <li key={snapshot.revision} className="py-3 first:pt-0 last:pb-0">
              <details>
                <summary className="cursor-pointer rounded-md py-2 font-medium focus-visible:outline-2 focus-visible:outline-offset-2">
                  نسخه قبلی {snapshot.revision} · ثبت تصویر در{" "}
                  {new Intl.DateTimeFormat("fa-IR", {
                    dateStyle: "medium",
                    timeStyle: "short",
                  }).format(new Date(snapshot.created_at))}
                </summary>
                <ol className="mt-3 space-y-3 border-s-2 border-foreground/10 ps-4">
                  {snapshot.dossier.stages.map((stage) => (
                    <li key={stage.stage_number}>
                      <h4 className="text-sm font-semibold">
                        {IDEA_STAGES[stage.stage_number - 1]?.title ??
                          `مرحله ${stage.stage_number}`}
                      </h4>
                      <pre
                        dir="auto"
                        className="mt-1 whitespace-pre-wrap break-words rounded-lg bg-foreground/[0.03] p-3 font-sans text-sm leading-7"
                      >
                        {typeof stage.data.content === "string"
                          ? stage.data.content || "محتوای این مرحله خالی است."
                          : JSON.stringify(stage.data, null, 2)}
                      </pre>
                    </li>
                  ))}
                </ol>
              </details>
            </li>
          ))}
        </ol>
      )}
    </section>
  );
}
