//! The providers the node reaches models through, each by its own driver — reached by an API key, by a sign-in in a
//! browser, or as a server on this machine that takes none — and the variable of the login environment that holds each
//! keyed one's key, for a provider whose credential the node keeps none of.
const std = @import("std");
const ai = @import("siphon").ai;

pub const all = [_]ai.driver.Provider{
    .{ .id = "anthropic", .name = "Anthropic", .driver = &ai.drivers.anthropic.driver },
    .{ .id = "openai", .name = "OpenAI", .driver = &ai.drivers.openai.driver },
    .{ .id = "chatgpt", .name = "ChatGPT", .driver = &ai.drivers.chatgpt.driver },
    .{ .id = "deepseek", .name = "DeepSeek", .driver = &ai.drivers.deepseek.driver },
    .{ .id = "google", .name = "Google", .driver = &ai.drivers.google.driver },
    .{ .id = "meta", .name = "Meta", .driver = &ai.drivers.meta.driver },
    .{ .id = "xai", .name = "xAI", .driver = &ai.drivers.xai.driver },
    .{ .id = "openrouter", .name = "OpenRouter", .driver = &ai.drivers.openrouter.driver },
    .{ .id = "zai", .name = "Z.ai", .driver = &ai.drivers.zai.driver },
    .{ .id = "deepgram", .name = "Deepgram", .driver = &ai.drivers.deepgram.driver },
    .{ .id = "ollama", .name = "Ollama", .driver = &ai.drivers.ollama.driver },
    .{ .id = "lmstudio", .name = "LM Studio", .driver = &ai.drivers.lmstudio.driver },
};

/// Each provider the node knows a key of, with the variable of the login environment that holds it.
const key_variables = [_]struct { provider: []const u8, variable: []const u8 }{
    .{ .provider = "anthropic", .variable = "ANTHROPIC_API_KEY" },
    .{ .provider = "openai", .variable = "OPENAI_API_KEY" },
    .{ .provider = "deepseek", .variable = "DEEPSEEK_API_KEY" },
    .{ .provider = "google", .variable = "GEMINI_API_KEY" },
    .{ .provider = "meta", .variable = "META_API_KEY" },
    .{ .provider = "xai", .variable = "XAI_API_KEY" },
    .{ .provider = "openrouter", .variable = "OPENROUTER_API_KEY" },
    .{ .provider = "zai", .variable = "ZAI_API_KEY" },
    .{ .provider = "deepgram", .variable = "DEEPGRAM_API_KEY" },
};

/// The variable of the login environment that holds the key of `provider`; null for one the node knows no key of.
pub fn keyVariable(provider: []const u8) ?[]const u8 {
    for (key_variables) |each| if (std.mem.eql(u8, each.provider, provider)) return each.variable;
    return null;
}
