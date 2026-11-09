/**
 * The gateway's HTTP, as its channel carries it: Anthropic's Messages API for each agent behind it, under the agent's
 * name — `POST /claude/v1/messages` answers a conversation, the one its `conversation-id` names; `GET /claude/v1/models`
 * lists the models the agent offers; `GET /claude/v1/account` tells who the agent is signed in as;
 * `DELETE /claude/v1/conversations/{id}` lets go of what a conversation that ended holds.
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
		if (path === "/claude/v1/account" && request.method === "GET") return account(agents.claude);
		const ended = CONVERSATION.exec(path)?.[1];
		if (ended !== undefined && request.method === "DELETE") return forgotten(agents.claude, ended);
		return errorResponse("not_found_error", `No ${request.method} ${path} here.`);
	};
}

/** The path of a conversation of Claude's, its id escaped in it. */
const CONVERSATION = /^\/claude\/v1\/conversations\/([^/]+)$/;

/** The header that names the conversation a request is of. */
const CONVERSATION_HEADER = "conversation-id";

async function messages(claude: Claude, request: Request): Promise<Response> {
	const body: unknown = await request.json().catch(() => null);
	if (!matches(RequestSchema, body))
		return errorResponse("invalid_request_error", `The body is no request of the Messages API: ${problemsOf(RequestSchema, body).join("; ")}`);
	return claude.answer(body, request.signal, request.headers.get(CONVERSATION_HEADER) ?? undefined);
}

/** Lets go of what the conversation `escaped` names held, as it ended. */
async function forgotten(claude: Claude, escaped: string): Promise<Response> {
	const conversation = decodedOf(escaped);
	if (conversation === undefined) return errorResponse("invalid_request_error", "The conversation's id is not escaped as a path's is.");
	await claude.forget(conversation);
	return new Response(null, { status: 204 });
}

/** `escaped` as it was before it was escaped in a path; none where it was not escaped as a path's is. */
function decodedOf(escaped: string): string | undefined {
	try {
		return decodeURIComponent(escaped);
	} catch {
		return undefined;
	}
}

/** Who Claude Code is signed in as — its email, organization and plan — or that it is signed in as nobody. */
async function account(claude: Claude): Promise<Response> {
	try {
		const signed = await claude.account();
		if (signed === undefined) return errorResponse("authentication_error", "Claude Code is not signed in on this computer: run `claude` and sign in.");
		return Response.json({ email: signed.email, organization: signed.organization ?? null, subscription_type: signed.subscriptionType ?? null });
	} catch (error) {
		return errorResponse("api_error", error instanceof Error ? error.message : String(error));
	}
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
