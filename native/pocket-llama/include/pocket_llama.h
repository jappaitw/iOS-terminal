// Minimal C interface to the embedded llama.cpp server (local models).
// The server exposes OpenAI-compatible routes on loopback — including
// /v1/responses, which the codex engine speaks natively.
#ifndef POCKET_LLAMA_H
#define POCKET_LLAMA_H

#ifdef __cplusplus
extern "C" {
#endif

/// Starts the llama server on 127.0.0.1:port serving the GGUF at model_path.
/// Returns 0 if the server thread launched. One server per process; the model
/// loads asynchronously (poll GET /health for readiness).
int pll_start(const char *model_path, int port, int context_size);

#ifdef __cplusplus
}
#endif

#endif
