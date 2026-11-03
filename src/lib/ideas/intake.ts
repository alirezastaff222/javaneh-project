export type InitialIdeaIntakeAnswers = {
  title: string;
  initialDescription: string;
  problem: string;
  affectedPeople: string;
  observation: string;
};

export type IntakeRegistrationOperation = {
  createRequestId: string;
  saveRequestId: string;
  ideaId: string | null;
  expectedRevision: number | null;
};

export type IntakeRpcClient = {
  rpc(
    name: string,
    parameters: Record<string, unknown>,
  ): Promise<{ data: unknown; error: unknown }>;
  loadIdeaRevision(ideaId: string): Promise<number | null>;
};

export class IntakeRegistrationError extends Error {
  constructor(
    readonly phase: "create" | "save" | "confirm",
    readonly outcome: string,
  ) {
    super(`${phase}:${outcome}`);
    this.name = "IntakeRegistrationError";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function buildInitialIdeaContent(
  answers: InitialIdeaIntakeAnswers,
): string {
  const title = answers.title.trim().replace(/\s+/g, " ");
  const sections = [
    ["شرح اولیه ایده", answers.initialDescription],
    ["مسئله", answers.problem],
    ["افراد و گروه‌های متأثر", answers.affectedPeople],
    ["مشاهده یا شواهد اولیه", answers.observation],
  ] as const;

  return [
    title,
    ...sections.flatMap(([label, value]) => {
      const content = value.trim();
      return content ? [`${label}:\n${content}`] : [];
    }),
  ].join("\n\n");
}

export async function registerInitialIdea(
  client: IntakeRpcClient,
  content: string,
  operation: IntakeRegistrationOperation,
  onOperationChange: (operation: IntakeRegistrationOperation) => void,
): Promise<{ ideaId: string; revision: number }> {
  let activeOperation = operation;

  if (!activeOperation.ideaId) {
    const creation = await client.rpc("create_idea", {
      p_request_id: activeOperation.createRequestId,
    });
    if (creation.error) {
      throw new IntakeRegistrationError("create", "request_failed");
    }
    if (!isRecord(creation.data)) {
      throw new IntakeRegistrationError("create", "invalid_response");
    }
    if (creation.data.outcome === "quota_exceeded") {
      throw new IntakeRegistrationError("create", "quota_exceeded");
    }
    if (
      !["created", "already_exists"].includes(
        String(creation.data.outcome),
      ) ||
      typeof creation.data.idea_id !== "string"
    ) {
      throw new IntakeRegistrationError(
        "create",
        String(creation.data.outcome ?? "invalid_response"),
      );
    }

    const ideaId = creation.data.idea_id;
    const responseRevision = creation.data.revision;
    const expectedRevision =
      Number.isInteger(responseRevision) && Number(responseRevision) > 0
        ? Number(responseRevision)
        : await client.loadIdeaRevision(ideaId);
    if (!expectedRevision || expectedRevision < 1) {
      throw new IntakeRegistrationError("create", "revision_unavailable");
    }

    activeOperation = { ...activeOperation, ideaId, expectedRevision };
    onOperationChange(activeOperation);
  }

  const ideaId = activeOperation.ideaId;
  const expectedRevision = activeOperation.expectedRevision;
  if (!ideaId || !expectedRevision) {
    throw new IntakeRegistrationError("create", "operation_incomplete");
  }

  const save = await client.rpc("save_idea_content", {
    p_idea_id: ideaId,
    p_request_id: activeOperation.saveRequestId,
    p_expected_revision: expectedRevision,
    p_stage_updates: [{ stage_number: 1, data: { content } }],
  });
  if (save.error) {
    throw new IntakeRegistrationError("save", "request_failed");
  }
  if (
    !isRecord(save.data) ||
    !["applied", "no_op", "replayed"].includes(String(save.data.outcome)) ||
    !Number.isInteger(save.data.result_revision) ||
    Number(save.data.result_revision) < 1
  ) {
    throw new IntakeRegistrationError(
      "save",
      String(isRecord(save.data) ? save.data.outcome : "invalid_response"),
    );
  }
  const revision = Number(save.data.result_revision);

  const request = await client.rpc("request_idea_stage_confirmation", {
    p_idea_id: ideaId,
    p_stage_number: 1,
  });
  if (
    request.error ||
    !isRecord(request.data) ||
    !["requested", "already_requested"].includes(
      String(request.data.outcome),
    )
  ) {
    throw new IntakeRegistrationError(
      "confirm",
      String(isRecord(request.data) ? request.data.outcome : "request_failed"),
    );
  }

  const confirmation = await client.rpc("confirm_idea_stage", {
    p_idea_id: ideaId,
    p_stage_number: 1,
    p_expected_revision: revision,
  });
  if (
    confirmation.error ||
    !isRecord(confirmation.data) ||
    !["confirmed", "already_confirmed"].includes(
      String(confirmation.data.outcome),
    )
  ) {
    throw new IntakeRegistrationError(
      "confirm",
      String(
        isRecord(confirmation.data)
          ? confirmation.data.outcome
          : "confirmation_failed",
      ),
    );
  }

  return { ideaId, revision };
}