import SwiftUI

/// Settings → AI Model: pick the backend and manage downloadable local models.
/// Nothing ships preinstalled; the engine is built in, models are user-chosen.
struct ModelSettingsView: View {
    @StateObject private var store = ModelStore.shared
    @State private var customURL = ""

    private var ramGB: Int { ModelStore.deviceRAMGB }

    var body: some View {
        List {
            Section {
                Text("Pocode uses Codex (GPT) by default. Download a local model to run fully offline, or add a custom OpenAI-compatible endpoint. Local models are optional — nothing is preinstalled.")
                    .font(.caption).foregroundStyle(VS.textDim)
            }

            Section("Backend") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cloud GPT (Codex)")
                        Text("Online · needs sign-in · flagship model")
                            .font(.caption2).foregroundStyle(VS.textDim)
                    }
                    Spacer()
                    if store.activeModelID == nil {
                        Text("Active").font(.caption).foregroundStyle(VS.accent)
                    } else {
                        Button("Use") { store.activeModelID = nil }
                    }
                }
            }

            Section("Local models") {
                Text("This device: \(ramGB) GB RAM — suggested \(ramGB >= 12 ? "up to 4B" : "1.5B–3B")")
                    .font(.caption).foregroundStyle(VS.textDim)
                ForEach(store.catalog) { model in
                    row(for: model)
                }
            }

            Section {
                HStack {
                    TextField("HuggingFace GGUF URL", text: $customURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.caption)
                    Button("Add") { addCustom() }.disabled(!customURL.hasPrefix("http"))
                }
            } header: {
                Text("Custom model")
            } footer: {
                Text("Paste a direct .gguf link. Tool-calling may be unreliable on models we haven't verified.")
            }
        }
        .navigationTitle("AI Model")
    }

    @ViewBuilder
    private func row(for model: CatalogModel) -> some View {
        let isInstalled = store.installed.contains(model.id)
        let isActive = store.activeModelID == model.id
        let progress = store.downloading[model.id]

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                    Text("\(model.sizeText) · \(model.note)")
                        .font(.caption2).foregroundStyle(VS.textDim)
                }
                Spacer()
                if let progress {
                    ProgressView(value: progress).frame(width: 60)
                } else if isActive {
                    Text("Active").font(.caption).foregroundStyle(VS.accent)
                } else if isInstalled {
                    Button("Use") { store.activeModelID = model.id }
                } else {
                    Button("Download") { store.download(model) }
                }
            }
            if ramGB < model.minRAMGB {
                Label("Tight on this device's memory", systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .swipeActions {
            if isInstalled {
                Button("Delete", role: .destructive) { store.delete(model.id) }
            }
        }
    }

    private func addCustom() {
        guard let url = URL(string: customURL) else { return }
        let id = url.deletingPathExtension().lastPathComponent
        let model = CatalogModel(id: id, name: id, sizeBytes: 0, url: url,
                                 template: "qwen2.5", note: "Custom", minRAMGB: 8)
        store.download(model)
        customURL = ""
    }
}
