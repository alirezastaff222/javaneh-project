import { z } from "zod";

const configurationSchema = z.object({
  configuration_id: z.string().uuid(),
  configuration_key: z.string(),
  version_id: z.string().uuid(),
  version_number: z.number().int(),
  status: z.enum(["draft", "approved", "active", "retired"]),
  ready: z.boolean(),
  development_max_points: z.number().int(),
  human_jury_max_points: z.number().int(),
  overall_max_points: z.number().int(),
  rounding_policy: z.string(),
  competition: z.object({
    id: z.string().uuid(),
    key: z.string(),
    name: z.string(),
    status: z.enum(["draft", "active", "retired"]),
  }).nullable(),
  milestones: z.array(z.object({
    milestone_key: z.string(),
    stage_number: z.number().int(),
    definition: z.string().nullable(),
    validation_mode: z.string().nullable(),
    point_value: z.number().int().nullable(),
    is_active: z.boolean(),
  })),
  pending_evaluations: z.number().int(),
  awarded_development_points: z.number().int(),
});

export const scoringOperationsSummarySchema = z.object({
  configurations: z.array(configurationSchema),
});

export type ScoringOperationsSummary = z.infer<typeof scoringOperationsSummarySchema>;
