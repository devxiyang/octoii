/** The directory the model's chip, its list and a thread's details read: the models the node lists, and its providers, each with how it is connected. */
import type { Directory } from "../../core/models.ts";
import { useRead } from "../effects/read.ts";

/** The directory as the node answers it, read as the component that asks first draws; none before the node answered. */
export function useDirectory(): Directory | undefined {
	const models = useRead("models.list", {});
	const listed = useRead("providers.list", {});
	return models === undefined || listed === undefined ? undefined : { models: models.models, providers: listed.providers };
}
