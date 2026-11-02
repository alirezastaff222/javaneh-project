import { NextResponse, type NextRequest } from "next/server";
import { z } from "zod";
import { createSupabaseMentorCircuitBreaker } from "@/lib/ai/mentor/circuit-breaker";
import { classifyIdea, createSupabaseClassificationPersistence } from "@/lib/ai/mentor/classification-service";
import { createGoogleMentorProvider } from "@/lib/ai/mentor/provider";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";

const requestSchema = z.object({ ideaId: z.string().uuid() }).strict();
const ideaSchema = z.object({ id: z.string().uuid() }).strict();
const stageSchema = z
  .object({
    stage_number: z.union([z.literal(1), z.literal(2)]),
    stage_key: z.string(),
    status: z.string(),
    confirmed_version_id: z.string().uuid(),
    content: z.string().nullable(),
  })
  .strict();
const taxonomyVersionSchema = z.object({ version: z.string() }).strict();
const axisSchema = z
  .object({
    axis_id: z.string(),
    official_name: z.string(),
    official_definition: z.string(),
    active: z.boolean(),
  })
  .strict();

function response(status: string, httpStatus = 200) {
  return NextResponse.json(
    { status },
    { status: httpStatus, headers: { "Cache-Control": "no-store" } },
  );
}

function reportFailure(errorCategory: string): void {
  console.warn(
    JSON.stringify({
      event: "classification.request",
      status: "error",
      errorCategory,
    }),
  );
}

export async function POST(request: NextRequest) {
  try {
    const supabase = await createClient();
    const { data, error } = await supabase.auth.getUser();
    if (error || !data.user) return response("unauthenticated", 401);

    const rawBody = await request.text();
    if (Buffer.byteLength(rawBody, "utf8") > 2_000) {
      return response("invalid_request", 400);
    }

    let body: unknown;
    try {
      body = JSON.parse(rawBody);
    } catch {
      return response("invalid_request", 400);
    }
    const parsedRequest = requestSchema.safeParse(body);
    if (!parsedRequest.success) return response("invalid_request", 400);

    const { data: ideaRow, error: ideaError } = await supabase
      .from("ideas")
      .select("id")
      .eq("id", parsedRequest.data.ideaId)
      .eq("owner_id", data.user.id)
      .maybeSingle();
    if (ideaError) {
      reportFailure("idea_lookup_unavailable");
      return response("context_unavailable", 503);
    }
    const parsedIdea = ideaSchema.safeParse(ideaRow);
    if (!parsedIdea.success) return response("idea_unavailable", 404);

    const { data: stageRows, error: stagesError } = await supabase
      .from("idea_stages")
      .select("stage_number,stage_key,status,confirmed_version_id,content:data->>content")
      .eq("idea_id", parsedIdea.data.id)
      .in("stage_number", [1, 2]);
    if (stagesError || !Array.isArray(stageRows)) {
      reportFailure("confirmed_stages_unavailable");
      return response("context_unavailable", 503);
    }
    const stages = stageRows.flatMap((row) => {
      const parsed = stageSchema.safeParse(row);
      return parsed.success ? [parsed.data] : [];
    });
    const stage1 = stages.find((stage) => stage.stage_number === 1);
    const stage2 = stages.find((stage) => stage.stage_number === 2);
    if (
      !stage1 ||
      !stage2 ||
      stage1.stage_key !== "define_problem" ||
      stage2.stage_key !== "identify_social_capacities" ||
      stage1.status !== "confirmed" ||
      stage2.status !== "confirmed" ||
      !stage1.content?.trim() ||
      !stage2.content?.trim()
    ) {
      return response("not_ready");
    }

    const { data: taxonomyRow, error: taxonomyError } = await supabase
      .from("thematic_taxonomy_versions")
      .select("version")
      .eq("active", true)
      .maybeSingle();
    const parsedTaxonomy = taxonomyVersionSchema.safeParse(taxonomyRow);
    if (taxonomyError || !parsedTaxonomy.success) {
      reportFailure("taxonomy_version_unavailable");
      return response("taxonomy_unavailable", 503);
    }

    const { data: axisRows, error: axesError } = await supabase
      .from("thematic_axes")
      .select("axis_id,official_name,official_definition,active")
      .eq("taxonomy_version", parsedTaxonomy.data.version)
      .eq("active", true)
      .order("axis_id", { ascending: true });
    if (axesError || !Array.isArray(axisRows)) {
      reportFailure("taxonomy_axes_unavailable");
      return response("taxonomy_unavailable", 503);
    }
    const axes = axisRows.flatMap((row) => {
      const parsed = axisSchema.safeParse(row);
      return parsed.success ? [parsed.data] : [];
    });
    if (axes.length !== 6) {
      reportFailure("taxonomy_axis_count_invalid");
      return response("taxonomy_unavailable", 503);
    }

    const admin = createAdminClient();
    const status = await classifyIdea(
      {
        ideaId: parsedIdea.data.id,
        participantId: data.user.id,
        stage1: {
          revisionId: stage1.confirmed_version_id,
          content: stage1.content,
        },
        stage2: {
          revisionId: stage2.confirmed_version_id,
          content: stage2.content,
        },
        taxonomyVersion: parsedTaxonomy.data.version,
        axes,
      },
      {
        persistence: createSupabaseClassificationPersistence(admin),
        provider: createGoogleMentorProvider(),
        circuit: createSupabaseMentorCircuitBreaker(createAdminClient),
      },
    );
    return response(status);
  } catch {
    reportFailure("internal_error");
    return response("temporarily_unavailable", 503);
  }
}
