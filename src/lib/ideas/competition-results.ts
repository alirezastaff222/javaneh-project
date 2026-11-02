import { z } from "zod";

export const participantResultSchema = z.discriminatedUnion("state", [
  z.object({ state: z.literal("unpublished") }),
  z.object({
    state: z.literal("published"),
    competition_id: z.string().uuid(),
    result_version_id: z.string().uuid(),
    version_number: z.number().int().positive(),
    development_score: z.number().min(0).max(700),
    jury_score: z.number().min(0).max(300),
    final_score: z.number().min(0).max(1000),
    rank: z.number().int().positive(),
  }),
]);

export const adminResultEntrySchema = z.object({
  result_version_id: z.string().uuid(),
  idea_id: z.string().uuid(),
  development_score: z.number().min(0).max(700),
  jury_score: z.number().min(0).max(300).nullable(),
  final_score: z.number().min(0).max(1000).nullable(),
  eligibility: z.enum(["ranked", "pending"]),
  rank: z.number().int().positive().nullable(),
});

export const adminResultsSchema = z.object({
  competition_id: z.string().uuid(),
  status: z.string(),
  versions: z.array(z.object({
    result_version_id: z.string().uuid(),
    version_number: z.number().int().positive(),
    status: z.enum(["prepared", "approved", "published"]),
    prepared_at: z.string(),
    approved_at: z.string().nullable(),
    published_at: z.string().nullable(),
  })),
  entries: z.array(adminResultEntrySchema),
});

export type ParticipantResult = z.infer<typeof participantResultSchema>;
