import Foundation

/// A downloadable local model (GGUF) plus the chat template its tool-calls need.
struct CatalogModel: Identifiable, Hashable {
    let id: String            // filename stem, also the on-disk id
    let name: String
    let sizeBytes: Int64
    let url: URL
    let template: String      // resource name in llama-templates (without .jinja)
    let note: String          // one-line capability / recommendation
    let minRAMGB: Int         // suggested minimum device RAM

    var sizeText: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

/// Curated models (tool-calling verified or being verified) + on-disk management.
/// Models live in Documents/models; nothing ships preinstalled.
@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published private(set) var installed: Set<String> = []
    @Published var activeModelID: String? {
        didSet { UserDefaults.standard.set(activeModelID, forKey: "model.activeLocal") }
    }
    @Published private(set) var downloading: [String: Double] = [:] // id → progress 0…1

    /// Curated list. Prefer Instruct/clean-licence; coder builds are completion-only.
    let catalog: [CatalogModel] = [
        CatalogModel(id: "qwen2.5-3b-instruct-q4_k_m", name: "Qwen2.5 3B Instruct",
                     sizeBytes: 2_100_000_000,
                     url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf")!,
                     template: "qwen2.5", note: "Tool-calling verified · needs 12GB for smooth agent use", minRAMGB: 8),
        CatalogModel(id: "qwen2.5-1.5b-instruct-q4_k_m", name: "Qwen2.5 1.5B Instruct",
                     sizeBytes: 1_000_000_000,
                     url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
                     template: "qwen2.5", note: "Light · simple edits & completion", minRAMGB: 8),
    ]

    var modelsDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        activeModelID = UserDefaults.standard.string(forKey: "model.activeLocal")
        refreshInstalled()
    }

    func refreshInstalled() {
        let files = (try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)) ?? []
        installed = Set(files.filter { $0.pathExtension == "gguf" }.map { $0.deletingPathExtension().lastPathComponent })
        // Never auto-activate: the user explicitly picks a local model (otherwise
        // `codex` would silently switch to a local model just because a file
        // exists, and boot would block on starting it).
        if let active = activeModelID, !installed.contains(active) { activeModelID = nil }
    }

    func fileURL(for id: String) -> URL { modelsDir.appendingPathComponent("\(id).gguf") }

    func template(for id: String) -> String? {
        catalog.first { $0.id == id }?.template
    }

    /// Device RAM in whole GB (for recommendations).
    static var deviceRAMGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }

    func download(_ model: CatalogModel) {
        guard downloading[model.id] == nil else { return }
        downloading[model.id] = 0
        let dest = fileURL(for: model.id)
        let delegate = DownloadDelegate(id: model.id, dest: dest) { [weak self] progress in
            Task { @MainActor in self?.downloading[model.id] = progress }
        } onFinish: { [weak self] ok in
            Task { @MainActor in
                self?.downloading[model.id] = nil
                self?.refreshInstalled()
                // Downloading one's first model activates it; otherwise the user
                // keeps their current choice and switches explicitly with "Use".
                if ok, self?.activeModelID == nil, self?.installed.count == 1 {
                    self?.activeModelID = model.id
                }
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        session.downloadTask(with: model.url).resume()
    }

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
        refreshInstalled()
    }
}

/// Streams a download to disk with progress — avoids holding the whole GGUF in memory.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let id: String
    let dest: URL
    let onProgress: (Double) -> Void
    let onFinish: (Bool) -> Void

    init(id: String, dest: URL, onProgress: @escaping (Double) -> Void, onFinish: @escaping (Bool) -> Void) {
        self.id = id; self.dest = dest; self.onProgress = onProgress; self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        onFinish(ok)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { onFinish(false) }
    }
}
