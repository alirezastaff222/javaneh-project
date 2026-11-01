import assert from "node:assert/strict";
import { isValidElement, type ReactNode } from "react";
import test from "node:test";
import DossierHistoryInspector, {
  DossierHistoryEntryPoint,
} from "@/app/ideas/dossier-history-inspector";
import { parseDossierHistory } from "./dossier-history";

function snapshot(revision: number) {
  return {
    revision,
    created_at: `2026-11-01T10:0${revision}:00Z`,
    dossier: {
      stages: Array.from({ length: 6 }, (_, index) => ({
        stage_number: index + 1,
        stage_key: `stage_${index + 1}`,
        data: { content: `Revision ${revision}, stage ${index + 1}` },
        confirmed_at: "2026-11-01T09:00:00Z",
      })),
    },
  };
}

function textContent(node: ReactNode): string {
  if (Array.isArray(node)) return node.map(textContent).join("");
  if (typeof node === "string" || typeof node === "number") return String(node);
  return isValidElement(node)
    ? textContent((node.props as { children?: ReactNode }).children ?? null)
    : "";
}

function findElement(
  node: ReactNode,
  predicate: (type: unknown, props: Record<string, unknown>) => boolean,
): { type: unknown; props: Record<string, unknown> } | null {
  if (Array.isArray(node)) {
    for (const child of node) {
      const match = findElement(child, predicate);
      if (match) return match;
    }
    return null;
  }
  if (!isValidElement(node)) return null;

  const props = node.props as Record<string, unknown>;
  if (predicate(node.type, props)) return { type: node.type, props };
  return findElement((props.children as ReactNode) ?? null, predicate);
}

function render(state: Parameters<typeof DossierHistoryInspector>[0]["state"]) {
  return DossierHistoryInspector({
    currentRevision: 5,
    state,
    onRetry() {},
    onClose() {},
  });
}

test("only submitted ideas expose the history entry point", () => {
  assert.equal(
    DossierHistoryEntryPoint({
      status: "draft",
      isOpen: false,
      onClick() {},
    }),
    null,
  );

  let opened = 0;
  const submitted = DossierHistoryEntryPoint({
    status: "submitted",
    isOpen: false,
    onClick() {
      opened += 1;
    },
  });
  assert.ok(submitted);
  assert.match(textContent(submitted), /مشاهده سابقه نسخه‌ها/);
  if (!isValidElement(submitted)) throw new Error("Expected a history button.");
  (submitted.props as { onClick: () => void }).onClick();
  assert.equal(opened, 1);
});

test("renders loading and empty-history states without inventing an initial version", () => {
  assert.match(textContent(render({ kind: "loading" })), /در حال بارگذاری سابقه نسخه‌ها/);
  const empty = textContent(render({ kind: "loaded", history: [] }));
  assert.match(empty, /هیچ نسخه قبلی ذخیره‌شده‌ای/);
  assert.match(empty, /نسخه اولیه ثبت نهایی/);
});

test("renders chronological prior snapshots separately from the current dossier", () => {
  const history = parseDossierHistory([snapshot(4), snapshot(2)]);
  assert.ok(history);
  const originalHistory = structuredClone(history);
  const tree = render({ kind: "loaded", history });
  const content = textContent(tree);

  assert.ok(content.indexOf("نسخه قبلی 2") < content.indexOf("نسخه قبلی 4"));
  assert.match(content, /نسخه جاری 5 جدا از این فهرست است/);
  assert.match(content, /Revision 2, stage 1/);
  assert.doesNotMatch(content, /بازگردانی|بازگشایی|ویرایش نسخه/);
  assert.deepEqual(history, originalHistory);
});

test("renders a recoverable error and invokes its retry action", () => {
  let retries = 0;
  const tree = DossierHistoryInspector({
    currentRevision: 5,
    state: { kind: "error" },
    onRetry() {
      retries += 1;
    },
    onClose() {},
  });
  assert.ok(
    findElement(tree, (_type, props) => props.role === "alert"),
  );

  const retryButton = findElement(
    tree,
    (type, props) =>
      type === "button" && textContent(props.children as ReactNode) === "تلاش دوباره",
  );
  assert.ok(retryButton);
  const retry = retryButton.props.onClick as (() => void) | undefined;
  assert.ok(retry);
  retry();
  assert.equal(retries, 1);
});