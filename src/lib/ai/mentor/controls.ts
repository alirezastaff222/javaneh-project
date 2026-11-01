import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

const reservationSchema = z.discriminatedUnion("outcome", [
  z.object({ outcome: z.literal("admitted") }).strict(),
  z
    .object({
      outcome: z.literal("duplicate"),
      state: z.enum(["processing", "completed", "failed"]),
    })
    .strict(),
  z
    .object({
      outcome: z.literal("rate_limited"),
      retry_after_seconds: z.number().int().positive(),
    })
    .strict(),
]);

const completionSchema = z.discriminatedUnion("outcome", [
  z
    .object({
      outcome: z.literal("finished"),
      state: z.enum(["completed", "failed"]),
    })
    .strict(),
  z
    .object({
      outcome: z.literal("already_finished"),
      state: z.enum(["completed", "failed"]),
    })
    .strict(),
]);

export type MentorRequestState = "processing" | "completed" | "failed";

export type MentorRequestReservation =
  | { outcome: "admitted" }
  | { outcome: "duplicate"; state: MentorRequestState }
  | { outcome: "rate_limited"; retryAfterSeconds: number };

export type MentorRequestControls = {
  reserve(requestId: string): Promise<MentorRequestReservation>;
  finish(
    requestId: string,
    succeeded: boolean,
  ): Promise<{ outcome: "finished" | "already_finished"; state: "completed" | "failed" }>;
};

export class MentorRequestControlError extends Error {
  constructor() {
    super("Mentor request controls are unavailable");
    this.name = "MentorRequestControlError";
  }
}

export function createSupabaseMentorRequestControls(
  supabase: SupabaseClient,
): MentorRequestControls {
  return {
    async reserve(requestId) {
      const { data, error } = await supabase.rpc("reserve_mentor_request", {
        p_request_id: requestId,
      });
      if (error) throw new MentorRequestControlError();
      const parsed = reservationSchema.safeParse(data);
      if (!parsed.success) throw new MentorRequestControlError();

      if (parsed.data.outcome === "rate_limited") {
        return {
          outcome: "rate_limited",
          retryAfterSeconds: parsed.data.retry_after_seconds,
        };
      }
      return parsed.data;
    },

    async finish(requestId, succeeded) {
      const { data, error } = await supabase.rpc("finish_mentor_request", {
        p_request_id: requestId,
        p_succeeded: succeeded,
      });
      if (error) throw new MentorRequestControlError();
      const parsed = completionSchema.safeParse(data);
      if (!parsed.success) throw new MentorRequestControlError();
      return parsed.data;
    },
  };
}