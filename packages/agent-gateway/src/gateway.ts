/**
 * The gateway's HTTP, as its channel carries it: Anthropic's Messages API for each agent behind it, under the agent's
 * name — `POST /claude/v1/messages` answers a conversation, `GET /claude/v1/models` lists the models the agent offers.
 */
import { errorResponse, RequestSchema } from "./anthropic.ts";
import type { Handler } from "./channel.ts";
import type { Claude } from "./claude.ts";
import { matches, problemsOf } from "./schema.ts";

/** The agents the gateway answers for. */
export type Agents = { readonly claude: Claude };

/** The gateway's handler of `agents`. */
export function handlerOf(agents: Agents): Handler {
	return async (request) => {
		const path = new URL(request.url).pathname;
		if (path === "/claude/v1/messages" && request.method === "POST") return messages(agents.claude, request);
		if (path === "/claude/v1/models" && request.method === "GET") return models(agents.claude);
		return errorResponse("not_found_error", `No ${request.method} ${path} here.`);
	};
}

async function messages(claude: Claude, request: Request): Promise<Response> {
	const body: unknown = await request.json().catch(() => null);
	if (!matches(RequestSchema, body))
		return errorResponse("invalid_request_error", `The body is no request of the Messages API: ${problemsOf(RequestSchema, body).join("; ")}`);
	return claude.answer(body, request.signal);
}

/** The models, as the API lists them: each by the name Claude Code takes, and the name a person reads. */
async function models(claude: Claude): Promise<Response> {
	try {
		const offered = await claude.models();
		const data = offered.map((model) => ({ type: "model", id: model.value, display_name: model.displayName, created_at: "1970-01-01T00:00:00Z" }));
		return Response.json({ data, has_more: false, first_id: data[0]?.id ?? null, last_id: data.at(-1)?.id ?? null });
	} catch (error) {
		return errorResponse("api_error", error instanceof Error ? error.message : String(error));
	}
}
