import Foundation
import Darwin

/// `bench` — measures the active local model on THIS device: prompt (prefill)
/// and generation (decode) throughput, time-to-first-token, and the app's memory
/// footprint. Simulator numbers reflect the Mac, not a phone — run it on real
/// hardware for meaningful device-to-device comparisons (16 Pro vs 17 vs 18).
enum BenchmarkRuntime {
    static let shellCommand: (@Sendable (ShellContext) async -> Int32)? = { ctx in await run(ctx) }

    private static let port: Int32 = 8080

    static func run(_ ctx: ShellContext) async -> Int32 {
        func out(_ s: String) { ctx.stdout.write(s) }
        out("\u{1B}[1mBenchmark\u{1B}[0m — on-device local-model speed.\r\n")

        #if targetEnvironment(simulator)
        out("\u{1B}[33m⚠️ Simulator runs on this Mac, not an iPhone chip — these numbers are NOT representative of real-device performance. Run on hardware.\u{1B}[0m\r\n")
        #endif

        let nPredict = ctx.args.count > 1 ? (Int(ctx.args[1]) ?? 128) : 128

        guard await LocalModelBackend.ensureRunning(out: out) != nil else {
            out("\u{1B}[33mNo local model is active. Download one in Settings → AI → AI Model, press Use, then run `bench`.\u{1B}[0m\r\n")
            return 1
        }

        let device = deviceName()
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        out("\r\nDevice \u{1B}[2m\(device) · \(String(format: "%.0f", ramGB)) GB RAM\u{1B}[0m\r\n")

        // Warm-up so model load / first-run graph build doesn't skew the measured run.
        out("\u{1B}[2mWarming up…\u{1B}[0m\r\n")
        _ = await complete(prompt: "Hi", nPredict: 8)

        out("\u{1B}[2mMeasuring (\(nPredict) tokens)…\u{1B}[0m\r\n")
        let before = footprintMB()
        guard let t = await complete(prompt: benchPrompt, nPredict: nPredict) else {
            out("\u{1B}[31mBenchmark request failed (the model server may have stopped).\u{1B}[0m\r\n")
            return 1
        }
        let after = footprintMB()

        func line(_ label: String, _ value: String) {
            out("  \u{1B}[2m\(label.padding(toLength: 22, withPad: " ", startingAt: 0))\u{1B}[0m \(value)\r\n")
        }
        out("\r\n\u{1B}[1mResults\u{1B}[0m\r\n")
        line("Prompt (prefill)", String(format: "%.1f tok/s  (%d tokens)", t.promptPerSec, t.promptN))
        line("Generation (decode)", String(format: "\u{1B}[32m%.1f tok/s\u{1B}[0m  (%d tokens)", t.predPerSec, t.predN))
        line("Time to first token", String(format: "%.0f ms", t.promptMs))
        line("Total time", String(format: "%.1f s", (t.promptMs + t.predMs) / 1000))
        line("Memory footprint", String(format: "%.0f MB (peak ~%.0f MB)", after, max(before, after)))
        out("\r\n\u{1B}[2mTip: 1.5B models decode ~2× faster than 3B on the same device.\u{1B}[0m\r\n")
        return 0
    }

    private struct Timings {
        let promptN: Int, predN: Int
        let promptMs: Double, predMs: Double
        let promptPerSec: Double, predPerSec: Double
    }

    /// POST /completion (raw prompt, no chat template) and read llama's timings.
    private static func complete(prompt: String, nPredict: Int) async -> Timings? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/completion") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 120
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "prompt": prompt, "n_predict": nPredict, "temperature": 0, "cache_prompt": false,
        ])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tm = obj["timings"] as? [String: Any] else { return nil }
        func d(_ k: String) -> Double { (tm[k] as? Double) ?? 0 }
        return Timings(
            promptN: Int(d("prompt_n")), predN: Int(d("predicted_n")),
            promptMs: d("prompt_ms"), predMs: d("predicted_ms"),
            promptPerSec: d("prompt_per_second"), predPerSec: d("predicted_per_second"))
    }

    private static let benchPrompt =
        "Write a short technical explanation of how a hash map works, including collisions and load factor."

    /// The app's physical memory footprint (model + KV + runtime) in MB.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func deviceName() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine  // e.g. "iPhone17,1" — the raw identifier is unambiguous for benchmarking
    }
}
