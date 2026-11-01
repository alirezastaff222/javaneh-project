import { z } from "zod";

export const classificationPromptVersion = "phase7.classification.v1";

export const classificationModelOutputSchema = z
  .object({
    primary_axis_id: z.string().min(1).max(80),
    secondary_axis_ids: z.array(z.string().min(1).max(80)).length(2),
    axes: z
      .array(
        z
          .object({
            axis_id: z.string().min(1).max(80),
            percentage: z.number().int().min(0).max(100),
            rationale: z.string().trim().min(1).max(700),
          })
          .strict(),
      )
      .length(3),
    confidence: z.number().min(0).max(1).optional(),
  })
  .strict();

export type ClassificationModelOutput = z.infer<
  typeof classificationModelOutputSchema
>;

export type ActiveClassificationAxis = {
  axis_id: string;
  official_name: string;
  official_definition: string;
  active: boolean;
};

export type ValidatedClassification = {
  primaryAxisId: string;
  secondaryAxisIds: [string, string];
  primaryPercentage: number;
  secondaryPercentages: [number, number];
  rationales: Record<string, string>;
  confidence?: number;
};

export class InvalidClassificationOutputError extends Error {
  constructor() {
    super("The classification response did not satisfy the output contract.");
    this.name = "InvalidClassificationOutputError";
  }
}

export function validateClassificationOutput(
  output: unknown,
  activeAxes: readonly ActiveClassificationAxis[],
): ValidatedClassification {
  const parsed = classificationModelOutputSchema.safeParse(output);
  if (!parsed.success || activeAxes.length !== 6) {
    throw new InvalidClassificationOutputError();
  }

  const axisIds = [
    parsed.data.primary_axis_id,
    ...parsed.data.secondary_axis_ids,
  ];
  const activeAxisIds = new Set(
    activeAxes.filter((axis) => axis.active).map((axis) => axis.axis_id),
  );
  const percentages = new Map(
    parsed.data.axes.map((entry) => [entry.axis_id, entry]),
  );

  if (
    activeAxisIds.size !== 6 ||
    new Set(axisIds).size !== 3 ||
    new Set(parsed.data.axes.map((entry) => entry.axis_id)).size !== 3 ||
    axisIds.some((axisId) => !activeAxisIds.has(axisId)) ||
    parsed.data.axes.some((entry) => !activeAxisIds.has(entry.axis_id)) ||
    parsed.data.axes.some((entry) => !axisIds.includes(entry.axis_id)) ||
    axisIds.some((axisId) => !percentages.has(axisId))
  ) {
    throw new InvalidClassificationOutputError();
  }

  const primary = percentages.get(parsed.data.primary_axis_id);
  const secondary1 = percentages.get(parsed.data.secondary_axis_ids[0]);
  const secondary2 = percentages.get(parsed.data.secondary_axis_ids[1]);
  if (
    !primary ||
    !secondary1 ||
    !secondary2 ||
    primary.percentage + secondary1.percentage + secondary2.percentage !== 100 ||
    primary.percentage <= secondary1.percentage ||
    primary.percentage <= secondary2.percentage ||
    axisIds.some((axisId) => !percentages.get(axisId)?.rationale.trim())
  ) {
    throw new InvalidClassificationOutputError();
  }

  return {
    primaryAxisId: parsed.data.primary_axis_id,
    secondaryAxisIds: [
      parsed.data.secondary_axis_ids[0],
      parsed.data.secondary_axis_ids[1],
    ],
    primaryPercentage: primary.percentage,
    secondaryPercentages: [secondary1.percentage, secondary2.percentage],
    rationales: {
      [parsed.data.primary_axis_id]: primary.rationale,
      [parsed.data.secondary_axis_ids[0]]: secondary1.rationale,
      [parsed.data.secondary_axis_ids[1]]: secondary2.rationale,
    },
    confidence: parsed.data.confidence,
  };
}
