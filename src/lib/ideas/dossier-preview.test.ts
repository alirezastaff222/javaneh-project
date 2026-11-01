import assert from "node:assert/strict";
import { isValidElement, type ReactNode } from "react";
import test from "node:test";
import DossierPreview, {
  buildDossierPreviewStages,
  DossierPreviewEntryPoint,
} from "@/app/ideas/dossier-preview";
import { IDEA_STAGES } from "./stages";

type PreviewProps = Parameters<typeof DossierPreview>[0];

function stages(idea: string) {
  return Array.from({ length: 7 }, (_, index) => ({
    stage_number: index + 1,
    data: {
      content: index === 6 ? `PRIVATE REVIEW ${idea}` : `${idea} stage ${index + 1}`,
      internal_evaluation_note: `INTERNAL ${idea}`,
    },
  }));
}

function render(props: Partial<PreviewProps> = {}) {
  return DossierPreview({
    ideaId: "idea-a1234567",
    stages: stages("idea-a"),
    drafts: {},
    syncStatus: "saved",
    pendingSaveStageNumber: null,
    conflictStageNumber: null,
    onClose() {},
    ...props,
  });
}

function textContent(node: ReactNode): string {
  if (Array.isArray(node)) return node.map(textContent).join("");
  if (typeof node === "string" || typeof node === "number") return String(node);
  return isValidElement(node)
    ? textContent((node.props as { children?: ReactNode }).children ?? null)
    : "";
}

test("renders all six participant stages in canonical order", () => {
  const content = textContent(render());
  const titles = IDEA_STAGES.slice(0, 6).map((stage) => stage.title);

  assert.equal((content.match(/مرحله [1-6]:/g) ?? []).length, 6);
  assert.ok(
    titles.every((title, index) =>
      index === 0
        ? content.indexOf(title) >= 0
        : content.indexOf(title) > content.indexOf(titles[index - 1]),
    ),
  );
});

test("excludes stage seven and internal evaluation fields", () => {
  const content = textContent(render());

  assert.doesNotMatch(content, /مرحله 7|PRIVATE REVIEW|INTERNAL/);
  assert.match(content, /idea-a stage 6/);
});

test("represents persisted empty stages and unsaved empty edits honestly", () => {
  const persistedEmpty = stages("idea-a");
  persistedEmpty[1].data.content = "";
  const savedContent = textContent(
    render({ stages: persistedEmpty }),
  );
  assert.match(savedContent, /هنوز محتوایی برای این مرحله ذخیره نشده است/);

  const unsavedEmpty = textContent(
    render({
      stages: stages("idea-a"),
      drafts: { 2: "" },
      syncStatus: "pending",
    }),
  );
  assert.match(unsavedEmpty, /محتوای فعلی این مرحله خالی است/);
  assert.match(unsavedEmpty, /تغییر محلی هنوز ذخیره نشده است/);
});

test("distinguishes server-persisted content from local edits", () => {
  const preview = buildDossierPreviewStages({
    stages: stages("idea-a"),
    drafts: { 1: "local edit" },
    syncStatus: "pending",
    pendingSaveStageNumber: null,
    conflictStageNumber: null,
  });

  assert.equal(preview[0].persistence, "unsaved");
  assert.equal(preview[1].persistence, "saved");
  const content = textContent(
    render({
      drafts: { 1: "local edit" },
      syncStatus: "pending",
    }),
  );
  assert.match(content, /تغییراتی است که هنوز در پایگاه داده ذخیره نشده‌اند/);
});

test("marks failed or unconfirmed synchronization as unknown, never saved", () => {
  const failed = buildDossierPreviewStages({
    stages: stages("idea-a"),
    drafts: { 1: "local edit" },
    syncStatus: "failed",
    pendingSaveStageNumber: null,
    conflictStageNumber: null,
  });
  const pendingRequest = buildDossierPreviewStages({
    stages: stages("idea-a"),
    drafts: { 1: "local edit" },
    syncStatus: "pending",
    pendingSaveStageNumber: 1,
    conflictStageNumber: null,
  });

  assert.equal(failed[0].persistence, "unknown");
  assert.equal(pendingRequest[0].persistence, "unknown");
  assert.match(textContent(render({
    drafts: { 1: "local edit" },
    syncStatus: "failed",
  })), /وضعیت ذخیره‌شدن آن مشخص نیست/);
});

test("opening the preview does not invoke saving", () => {
  const actions: string[] = [];
  const button = DossierPreviewEntryPoint({
    disabled: false,
    onClick() {
      actions.push("open");
    },
  });
  assert.ok(isValidElement(button));
  (button.props as { onClick: () => void }).onClick();

  const preview = render({
    onClose() {},
  });
  assert.deepEqual(actions, ["open"]);
  assert.match(textContent(preview), /پیش‌نمایش پرونده فعلی/);
});

test("stateless preview renders only the newly selected idea content", () => {
  const previous = render({
    ideaId: "idea-a1234567",
    stages: stages("previous"),
  });
  const current = render({
    ideaId: "idea-b1234567",
    stages: stages("current"),
  });

  assert.match(textContent(previous), /previous stage 1/);
  assert.doesNotMatch(textContent(current), /previous/);
  assert.match(textContent(current), /current stage 1/);
  assert.equal(
    (current.props as { "data-idea-id": string })["data-idea-id"],
    "idea-b1234567",
  );
});

test("current preview stays separate from immutable dossier history", () => {
  const content = textContent(render());

  assert.doesNotMatch(content, /سابقه نسخه‌ها|نسخه قبلی|بازگردانی|snapshot/i);
  assert.match(content, /پیش‌نمایش پرونده فعلی/);
});
