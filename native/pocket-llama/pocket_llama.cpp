// Runs llama.cpp's full server (llama-server-impl) on a thread inside the app.
// Upstream exposes `int llama_server(int argc, char **argv)` exactly for
// embedding, so this wrapper only fakes a command line.
#include "include/pocket_llama.h"

#include <atomic>
#include <string>
#include <thread>
#include <vector>

int llama_server(int argc, char **argv); // from libllama-server-impl

extern "C" int pll_start(const char *model_path, int port, int context_size, const char *chat_template_path, int kv_f16) {
    static std::atomic_bool started{false};
    bool expected = false;
    if (!started.compare_exchange_strong(expected, true)) {
        return 1; // already running
    }
    std::string model = model_path ? model_path : "";
    std::string tmpl = chat_template_path ? chat_template_path : "";
    std::thread([model, port, context_size, tmpl, kv_f16] {
        std::vector<std::string> args = {
            "llama-server",
            "-m", model,
            "--host", "127.0.0.1",
            "--port", std::to_string(port),
            "--ctx-size", std::to_string(context_size > 0 ? context_size : 4096),
            "--no-webui",
            // Without --jinja the chat template ignores tool definitions and
            // the model can never emit a tool call.
            "--jinja",
            // Flash attention speeds up attention and is the prerequisite for a
            // quantized KV cache.
            "--flash-attn", "on",
        };
        // KV cache precision is a speed/memory trade the caller picks by device
        // RAM and model size: f16 is faster to decode; q8_0 is ~half the memory
        // (used for a big model on a tight device to avoid a jetsam OOM).
        if (!kv_f16) {
            args.push_back("--cache-type-k"); args.push_back("q8_0");
            args.push_back("--cache-type-v"); args.push_back("q8_0");
        }
        if (!tmpl.empty()) {
            // A tool-aware template whose <tool_call> markup llama's parser detects.
            args.push_back("--chat-template-file");
            args.push_back(tmpl);
        }
        std::vector<char *> argv;
        argv.reserve(args.size());
        for (auto &arg : args) {
            argv.push_back(const_cast<char *>(arg.c_str()));
        }
        llama_server(static_cast<int>(argv.size()), argv.data());
        started.store(false); // server exited; allow a restart attempt
    }).detach();
    return 0;
}
