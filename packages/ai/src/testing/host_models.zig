//! Models of kinds the catalogue lists none of in its window, as a host passes them in its own list, from their
//! providers' model pages and price lists; the tests of the media kinds use them.
const std = @import("std");
const foundation = @import("foundation");
const ModelFacts = @import("../catalogue/facts.zig").ModelFacts;

/// OpenAI's: gpt-4o-mini-tts, at $0.60 a million text tokens read and $12 a million audio tokens made; whisper-1, at
/// $0.006 a minute of the recording, which answers in `verbose_json` with timestamps and does not stream; and
/// gpt-live-transcribe, at $0.017 a minute of a session, which tells no speakers apart.
const openai_json =
    \\[{"id":"gpt-4o-mini-tts","name":"GPT-4o mini TTS","architecture":{"input_modalities":["text"],"output_modalities":["speech"]},
    \\  "supported_voices":["alloy","ash","ballad","coral","echo","fable","onyx","nova","sage","shimmer","verse","marin","cedar"],
    \\  "pricing":{"prompt":"0.0000006","completion":"0","audio_output":"0.000012"},
    \\  "octoii":{"kinds":["speech"],"release_date":"2025-03-20","instructions":true}},
    \\ {"id":"whisper-1","name":"Whisper","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]},
    \\  "pricing":{"prompt":"0","completion":"0","octoii":{"second":"0.0001"}},
    \\  "octoii":{"kinds":["transcription"],"release_date":"2023-03-01","speakers":false}},
    \\ {"id":"gpt-live-transcribe","name":"GPT-Live-Transcribe","architecture":{"input_modalities":["audio","text"],"output_modalities":["transcription"]},
    \\  "pricing":{"prompt":"0","completion":"0","octoii":{"second":"0.00028333333333333335"}},
    \\  "octoii":{"kinds":["realtime-transcription"],"speakers":false}}]
;

/// xAI's, released before the catalogue's window: grok-imagine-image, at $0.02 an image, up to ten a request and five
/// to edit; grok-imagine-video, at $0.05 a second, and its first frame; grok-imagine-video-1.5, at $0.08 a second, its
/// first and last frames, references and voices; and its speech, which its API names no model for, at $15 a million
/// characters.
const xai_json =
    \\[{"id":"grok-imagine-image","name":"Grok Imagine Image","architecture":{"input_modalities":["text","image"],"output_modalities":["image"]},
    \\  "pricing":{"prompt":"0","completion":"0","image_output":"0.02"},"supports_streaming":false,
    \\  "octoii":{"kinds":["image"],"release_date":"2026-01-28","image_parameters":{"n":{"type":"range","min":1,"max":10},"input_references":{"type":"range","min":0,"max":5}}}},
    \\ {"id":"grok-imagine-video","name":"Grok Imagine Video","architecture":{"input_modalities":["text","image","video"],"output_modalities":["video"]},
    \\  "supported_aspect_ratios":["1:1","16:9","9:16","4:3","3:4","3:2","2:3","21:9","5:2"],"supported_resolutions":["480p","720p"],
    \\  "supported_durations":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],"supported_frame_images":["first_frame"],"generate_audio":true,"seed":false,
    \\  "pricing_skus":{"duration_seconds":"0.05"},"octoii":{"kinds":["video"],"release_date":"2026-01-28"}},
    \\ {"id":"grok-imagine-video-1.5","name":"Grok Imagine Video 1.5","architecture":{"input_modalities":["text","image","audio"],"output_modalities":["video"]},
    \\  "supported_aspect_ratios":["1:1","16:9","9:16","4:3","3:4","3:2","2:3","21:9","5:2"],"supported_resolutions":["480p","720p","1080p"],
    \\  "supported_durations":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],"supported_frame_images":["first_frame","last_frame"],"generate_audio":true,"seed":false,
    \\  "pricing_skus":{"duration_seconds":"0.08"},"octoii":{"kinds":["video"],"release_date":"2026-05-30"}},
    \\ {"id":"grok-voice-tts-1.0","name":"Grok Voice TTS","architecture":{"input_modalities":["text"],"output_modalities":["speech"]},
    \\  "supported_voices":["eve","ara","leo","rex","sal","carina","zagan","helix","orion","luna","iris","altair","zenith","perseus","helios","lux","kepler","rigel","cosmo","celeste","ursa","sirius","lumen","castor","naksh","atlas"],
    \\  "pricing":{"prompt":"0","completion":"0","octoii":{"character":"0.000015"}},
    \\  "octoii":{"kinds":["speech"],"release_date":"2026-03-01","instructions":false}}]
;

/// OpenAI's models a host passes, in `arena`.
pub fn openai(arena: std.mem.Allocator) ![]const ModelFacts {
    return foundation.json.decode([]const ModelFacts, arena, openai_json);
}

/// xAI's models a host passes, in `arena`.
pub fn xai(arena: std.mem.Allocator) ![]const ModelFacts {
    return foundation.json.decode([]const ModelFacts, arena, xai_json);
}

/// Deepgram's Nova-3, which tells speakers apart, at $0.0043 a minute of a recording and $0.0077 a minute of a stream,
/// by the second.
const deepgram_json =
    \\[{"id":"nova-3","name":"Nova-3","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]},
    \\  "pricing":{"prompt":"0","completion":"0","octoii":{"second":"0.00007166666666666667"}},
    \\  "octoii":{"kinds":["transcription","realtime-transcription"],"speakers":true,
    \\   "realtime_pricing":{"prompt":"0","completion":"0","octoii":{"second":"0.00012833333333333333"}}}}]
;

/// Deepgram's models a host passes, in `arena`.
pub fn deepgram(arena: std.mem.Allocator) ![]const ModelFacts {
    return foundation.json.decode([]const ModelFacts, arena, deepgram_json);
}
