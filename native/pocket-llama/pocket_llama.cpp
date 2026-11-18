// Runs llama.cpp's full server (llama-server-impl) on a thread inside the app.
// Upstream exposes `int llama_server(int argc, char **argv)` exactly for
// embedding, so this wrapper only fakes a command line.
#include "include/pocket_llama.h"

#include <atomic>
#include <string>
#include <thread>
#include <vector>

int llama_server(int argc, char **argv); // from libllama-server-impl

extern "C" int pll_start(const char *model_path, int port, int context_size) {
    static std::atomic_bool started{false};
    bool expected = false;
    if (!started.compare_exchange_strong(expected, true)) {
        return 1; // already running
    }
    std::string model = model_path ? model_path : "";
    std::thread([model, port, context_size] {
        std::vector<std::string> args = {
            "llama-server",
            "-m", model,
            "--host", "127.0.0.1",
            "--port", std::to_string(port),
            "--ctx-size", std::to_string(context_size > 0 ? context_size : 4096),
            "--no-webui",
        };
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
