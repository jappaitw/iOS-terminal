// Minimal C interface to the embedded llama.cpp server (local models).
// The server exposes OpenAI-compatible routes on loopback — including
// /v1/responses, which the codex engine speaks natively.
#ifndef POCKET_LLAMA_H
#define POCKET_LLAMA_H

#ifdef __cplusplus
extern "C" {
#endif

/// Starts the llama server on 127.0.0.1:port serving the GGUF at model_path.
/// `chat_template_path` (may be NULL) overrides the model's embedded chat
/// template — needed for models (e.g. Qwen2.5-Coder) whose baked-in template
/// lacks the <tool_call> markup llama's parser detects. Returns 0 if the
/// server thread launched; the model loads async (poll GET /health).
int pll_start(const char *model_path, int port, int context_size, const char *chat_template_path);

#ifdef __cplusplus
}
#endif

#endif
