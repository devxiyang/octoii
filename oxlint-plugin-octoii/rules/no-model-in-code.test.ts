import { ruleTester } from "../test/harness.ts";

const rule = ruleTester("no-model-in-code");
const MESSAGE = "No code names a model: read what sets it apart from its facts (octoii.features, supported_parameters), not from its id.";

rule.valid("the id going onto the wire", "const body = { model: model.id, stream: true };");
rule.valid("the id in an address", "const url = `${baseUrl}/models/${model.id}:stream`;");
rule.valid("the id passed as a value", "send(model.id, params);");
rule.valid("a fact read from the model", "const fast = model.octoii.features?.service_tiers?.includes('fast');");
rule.valid("another object's id compared", "const same = item.id === response.id;");
rule.valid("a model named by its reference", "const mine = item.octoii?.model === modelReference(model);");

rule.invalid("an id compared with ===", "const flash = model.id === 'deepseek-flash';", MESSAGE);
rule.invalid("an id compared with !== on the left", "if ('claude-opus-5' !== model.id) run();", 1);
rule.invalid("an optional id compared", "const flash = this.model?.id === 'x';", 1);
rule.invalid("an id of a model named otherwise compared", "const same = textModel.id == 'x';", 1);
rule.invalid("a part of an id tested", "const claude = model.id.startsWith('claude-');", 1);
rule.invalid("an id matched", "const pro = model.id.endsWith('-pro') || model.id.includes('opus');", 2);
rule.invalid("a pattern tested on an id", "const opus = /opus/.test(model.id);", 1);
rule.invalid("an id looked up in a set", "const fast = FAST_MODELS.has(model.id);", 1);
rule.invalid("an id looked up in a list", "const fast = ['a', 'b'].includes(context.model.id);", 1);
rule.invalid("an id looked up in a table", "const limit = LIMITS[model.id];", 1);
rule.invalid("a switch on an id", "switch (model.id) { case 'a': break; }", 1);
