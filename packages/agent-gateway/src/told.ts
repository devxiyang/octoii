/**
 * What a session is given of a conversation past the message it stands after: the results of the calls that message
 * made, as results; what it has not seen — turns another model answered, the calls and results in them — as history
 * between `<conversation-checkpoint>` tags, each part marked with who said it, calls and results written out,
 * attachments as themselves and thinking left out; then the person's latest words as they are. A session that stands
 * after no message is given the whole conversation so.
 */
import { type Block, blocksOf, type Message, type ResultBlock } from "./anthropic.ts";

/** What a session is given: the results of its own last calls, then the rest, in one message. */
export type Told = { readonly results: readonly ResultBlock[]; readonly rest: readonly Block[] };

/** What a session standing after `messages[at]` — none, at -1 — is given of the conversation past it. */
export function toldAfter(messages: readonly Message[], at: number): Told {
	const standing = messages[at];
	const calls = new Set(standing?.role === "assistant" ? blocksOf(standing).flatMap((block) => (block.type === "tool_use" ? [block.id] : [])) : []);
	const past = messages.slice(at + 1).flatMap((message) => blocksOf(message).map((block) => ({ role: message.role, block })));
	const results: ResultBlock[] = [];
	let from = 0;
	while (from < past.length) {
		const part = past[from];
		if (part === undefined || part.role !== "user" || part.block.type !== "tool_result" || !calls.has(part.block.tool_use_id)) break;
		results.push(part.block);
		from += 1;
	}
	let to = past.length;
	while (to > from && isWords(past[to - 1])) to -= 1;
	const unseen = past.slice(from, to);
	const words = past.slice(to).map((part) => part.block);
	return { results, rest: [...(unseen.length === 0 ? [] : checkpointOf(unseen)), ...words] };
}

/** Whether `part` is the person's own words or an attachment of theirs. */
function isWords(part: { role: string; block: Block } | undefined): boolean {
	if (part === undefined || part.role !== "user") return false;
	return part.block.type === "text" || part.block.type === "image" || part.block.type === "document";
}

/** How history a session has not seen begins. */
const OPENING =
	"<conversation-checkpoint>\nThe following is conversation history you have not seen. Treat it as prior conversation, not a new request. Continue with the messages after this checkpoint.";

/** `parts`, history a session has not seen, as blocks of words between checkpoint tags. */
function checkpointOf(parts: readonly { role: string; block: Block }[]): Block[] {
	const blocks: Block[] = [{ type: "text", text: OPENING }];
	let role: string | undefined;
	for (const part of parts) {
		const told = toldBlock(part.block);
		if (told === undefined) continue;
		if (part.role !== role) {
			if (role !== undefined) blocks.push({ type: "text", text: `</${role}>` });
			blocks.push({ type: "text", text: `<${part.role}>` });
			role = part.role;
		}
		blocks.push(told);
	}
	if (role !== undefined) blocks.push({ type: "text", text: `</${role}>` });
	blocks.push({ type: "text", text: "</conversation-checkpoint>" });
	return blocks;
}

/** A block of history as a session reads it: words and attachments as they are, calls and results written out. */
function toldBlock(block: Block): Block | undefined {
	switch (block.type) {
		case "text":
		case "image":
		case "document":
			return block;
		case "tool_use":
			return { type: "text", text: `<tool-call>\n${JSON.stringify({ id: block.id, name: block.name, input: block.input })}\n</tool-call>` };
		case "tool_result":
			return {
				type: "text",
				text: `<tool-result>\n${JSON.stringify({ id: block.tool_use_id, is_error: block.is_error === true, content: block.content ?? "" })}\n</tool-result>`,
			};
		case "thinking":
		case "redacted_thinking":
			return undefined;
	}
}
