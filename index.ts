import { gateway } from "@ai-sdk/gateway";
import { generateText } from "ai";

async function main() {
  const { text } = await generateText({
    model: gateway("moonshotai/kimi-k3"),
    prompt:
      "Invent a new holiday and describe its traditions. Keep the answer imaginative and concise.",
  });

  console.log(text);
}

main().catch((error: unknown) => {
  const errorName = error instanceof Error ? error.name : "UnknownError";
  const statusCode =
    error && typeof error === "object" && "statusCode" in error &&
    typeof error.statusCode === "number"
      ? error.statusCode
      : undefined;
  console.error(
    `AI Gateway example failed (${errorName}${statusCode ? `, status ${statusCode}` : ""}).`,
  );
  process.exitCode = 1;
});
