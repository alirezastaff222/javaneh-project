import { IDEA_STAGES } from "@/lib/ideas/stages";

export type DossierPreviewPersistence = "saved" | "unsaved" | "unknown";

type PreviewStage = {
  stage_number: number;
  data: { content?: string };
};

export function buildDossierPreviewStages({
  stages,
  drafts,
  syncStatus,
  pendingSaveStageNumber,
  conflictStageNumber,
}: {
  stages: readonly PreviewStage[];
  drafts: Readonly<Record<number, string>>;
  syncStatus: "saved" | "pending" | "failed";
  pendingSaveStageNumber: number | null;
  conflictStageNumber: number | null;
}) {
  return IDEA_STAGES.filter((stage) => stage.number <= 6).map((definition) => {
    const serverStage = stages.find(
      (stage) => stage.stage_number === definition.number,
    );
    const serverContent =
      typeof serverStage?.data.content === "string"
        ? serverStage.data.content
        : "";
    const content = drafts[definition.number] ?? serverContent;
    const persistence: DossierPreviewPersistence = !serverStage
      ? "unknown"
      : content === serverContent
        ? "saved"
        : syncStatus === "failed" ||
            pendingSaveStageNumber === definition.number ||
            conflictStageNumber === definition.number
          ? "unknown"
          : "unsaved";

    return {
      number: definition.number,
      title: definition.title,
      content,
      persistence,
    };
  });
}

function persistenceLabel(persistence: DossierPreviewPersistence): string {
  switch (persistence) {
    case "saved":
      return "محتوا در پایگاه داده ذخیره شده است";
    case "unsaved":
      return "تغییر محلی هنوز ذخیره نشده است";
    case "unknown":
      return "وضعیت ذخیره‌سازی مشخص نیست؛ محتوا را ذخیره‌شده در نظر نگیرید";
  }
}

export function DossierPreviewEntryPoint({
  disabled,
  onClick,
}: {
  disabled: boolean;
  onClick(): void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="min-h-10 rounded-lg border border-foreground/20 px-4 text-sm font-medium hover:bg-foreground/5 disabled:cursor-not-allowed disabled:opacity-50"
    >
      پیش‌نمایش پرونده فعلی
    </button>
  );
}

export default function DossierPreview({
  ideaId,
  stages,
  drafts,
  syncStatus,
  pendingSaveStageNumber,
  conflictStageNumber,
  onClose,
}: {
  ideaId: string;
  stages: readonly PreviewStage[];
  drafts: Readonly<Record<number, string>>;
  syncStatus: "saved" | "pending" | "failed";
  pendingSaveStageNumber: number | null;
  conflictStageNumber: number | null;
  onClose(): void;
}) {
  const previewStages = buildDossierPreviewStages({
    stages,
    drafts,
    syncStatus,
    pendingSaveStageNumber,
    conflictStageNumber,
  });
  const hasUnsavedContent = previewStages.some(
    (stage) => stage.persistence === "unsaved",
  );
  const hasUnknownContent = previewStages.some(
    (stage) => stage.persistence === "unknown",
  );

  return (
    <section
      aria-labelledby="dossier-preview-heading"
      data-idea-id={ideaId}
      className="mb-6 rounded-xl border border-foreground/10 bg-foreground/[0.02] p-4 sm:p-5"
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h3 id="dossier-preview-heading" className="font-semibold">
            پیش‌نمایش پرونده فعلی
          </h3>
          <p className="mt-1 text-sm leading-6 text-foreground/65">
            محتوای شش مرحله توسعه ایده {ideaId.slice(0, 8)} به ترتیب مراحل
          </p>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="min-h-10 rounded-lg border border-foreground/20 px-3 text-sm font-medium hover:bg-foreground/5"
        >
          بستن پیش‌نمایش
        </button>
      </div>

      {(hasUnsavedContent || hasUnknownContent) && (
        <p
          role="status"
          className="mt-4 rounded-lg border border-amber-500/30 bg-amber-50 p-3 text-sm leading-7 text-amber-950 dark:bg-amber-950/30 dark:text-amber-100"
        >
          {hasUnknownContent
            ? "این پیش‌نمایش شامل محتوایی است که وضعیت ذخیره‌شدن آن مشخص نیست؛ آن را ذخیره‌شده یا نهایی‌شده در نظر نگیرید."
            : "این پیش‌نمایش شامل تغییراتی است که هنوز در پایگاه داده ذخیره نشده‌اند."}
        </p>
      )}

      <ol className="mt-4 divide-y divide-foreground/10">
        {previewStages.map((stage) => (
          <li key={stage.number} className="py-4 first:pt-0 last:pb-0">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <h4 className="font-medium">
                مرحله {stage.number}: {stage.title}
              </h4>
              <span
                className={`rounded-full px-2 py-1 text-xs ${
                  stage.persistence === "saved"
                    ? "bg-green-100 text-green-900 dark:bg-green-950 dark:text-green-200"
                    : stage.persistence === "unsaved"
                      ? "bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200"
                      : "bg-red-100 text-red-900 dark:bg-red-950 dark:text-red-200"
                }`}
              >
                {persistenceLabel(stage.persistence)}
              </span>
            </div>
            {stage.content.trim() ? (
              <pre
                dir="auto"
                className="mt-3 whitespace-pre-wrap break-words rounded-lg bg-background p-3 font-sans text-sm leading-7"
              >
                {stage.content}
              </pre>
            ) : (
              <p className="mt-3 rounded-lg bg-background p-3 text-sm leading-7 text-foreground/60">
                {stage.persistence === "saved"
                  ? "هنوز محتوایی برای این مرحله ذخیره نشده است."
                  : "محتوای فعلی این مرحله خالی است؛ این تغییر هنوز در پایگاه داده ذخیره نشده است."}
              </p>
            )}
          </li>
        ))}
      </ol>
    </section>
  );
}
