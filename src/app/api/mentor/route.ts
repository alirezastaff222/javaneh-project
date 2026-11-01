import type { NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";
import { createSupabaseMentorCircuitBreaker } from "@/lib/ai/mentor/circuit-breaker";
import { createSupabaseMentorRequestControls } from "@/lib/ai/mentor/controls";
import { createGatewayMentorProvider } from "@/lib/ai/mentor/provider";
import {
  createMentorAvailabilityHandler,
  createMentorPostHandler,
} from "@/lib/ai/mentor/route-handler";
import {
  createMentorResponse,
  createSupabaseMentorDataSource,
  getMentorAvailability,
} from "@/lib/ai/mentor/service";

const createCircuitBreaker = () =>
  createSupabaseMentorCircuitBreaker(createAdminClient);
const handleAvailability = createMentorAvailabilityHandler({
  async authenticate() {
    const supabase = await createClient();
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) return null;
    return { participantId: data.user.id, context: supabase };
  },
  async getAvailability() {
    return getMentorAvailability(createGatewayMentorProvider(), createCircuitBreaker());
  },
});

const handleMentorPost = createMentorPostHandler({
  async authenticate() {
    const supabase = await createClient();
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) return null;
    return { participantId: data.user.id, context: supabase };
  },
  execute(request, participantId, supabase) {
    return createMentorResponse(request, { id: participantId }, {
      data: createSupabaseMentorDataSource(supabase),
      controls: createSupabaseMentorRequestControls(supabase),
      provider: createGatewayMentorProvider(),
      circuit: createCircuitBreaker(),
    });
  },
});

export async function GET() {
  return handleAvailability();
}

export async function POST(request: NextRequest) {
  return handleMentorPost(request);
}