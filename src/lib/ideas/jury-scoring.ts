import { z } from "zod";

export const participantJuryScoreSchema = z.discriminatedUnion("state", [
  z.object({ state: z.literal("unpublished") }),
  z.object({
    state: z.literal("published"),
    final_score: z.number().min(0).max(300),
    maximum_points: z.literal(300),
    criterion_averages: z.record(z.string(), z.number().min(0)),
  }),
]);

export const juryAssignmentSchema = z.object({
  assignment_id: z.string().uuid(),
  idea_id: z.string().uuid(),
  dossier_revision: z.number().int().positive(),
  status: z.enum(["assigned", "recused", "submitted"]),
  conflict_declared: z.boolean(),
});

export const juryAssignmentsSchema = z.array(juryAssignmentSchema);

export type ParticipantJuryScore = z.infer<typeof participantJuryScoreSchema>;
