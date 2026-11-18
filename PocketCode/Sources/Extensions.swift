import Security
import SwiftUI

// MARK: - MCP server config (config.toml) and token storage

/// Manages the `[mcp_servers.<name>]` sections of CODEX_HOME/config.toml.
/// Only sections it wrote are touched; the rest of the file is preserved.
enum McpConfigFile {
    struct Server: Identifiable, Equatable {
        var name: String
        var url: String
        var hasToken: Bool
        var id: String { name }
    }

    static var path: URL { CodexRuntime.home.appendingPathComponent("config.toml") }

    static func list() -> [Server] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        var servers: [Server] = []
        var current: String?
        var url = "", token = false
        func flush() {
            if let name = current { servers.append(Server(name: name, url: url, hasToken: token)) }
            url = ""; token = false
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                flush()
                if trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") {
                    current = String(trimmed.dropFirst("[mcp_servers.".count).dropLast())
                } else {
                    current = nil
                }
            } else if current != nil {
                if trimmed.hasPrefix("url") { url = tomlValue(trimmed) }
                if trimmed.hasPrefix("bearer_token_env_var") { token = true }
            }
        }
        flush()
        return servers
    }

    static func upsert(name: String, url: String, tokenEnvVar: String?) {
        remove(name: name)
        var text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += "\n[mcp_servers.\(name)]\nurl = \"\(url)\"\n"
        if let tokenEnvVar { text += "bearer_token_env_var = \"\(tokenEnvVar)\"\n" }
        try? FileManager.default.createDirectory(at: CodexRuntime.home, withIntermediateDirectories: true)
        try? text.write(to: path, atomically: true, encoding: .utf8)
    }

    static func remove(name: String) {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return }
        var out: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                skipping = trimmed == "[mcp_servers.\(name)]"
            }
            if !skipping { out.append(line) }
        }
        try? out.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private static func tomlValue(_ line: String) -> String {
        guard let eq = line.firstIndex(of: "=") else { return "" }
        return line[line.index(after: eq)...]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
}

/// Bearer tokens for MCP servers, in the Keychain; exported as environment
/// variables (the engine's `bearer_token_env_var` mechanism) before use.
enum McpTokenStore {
    static func envVar(for server: String) -> String {
        "POCODE_MCP_" + server.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
    }

    static func save(server: String, token: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "pocode.mcp",
                                    kSecAttrAccount as String: server]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
        setenv(envVar(for: server), token, 1)
    }

    static func delete(server: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "pocode.mcp",
                                    kSecAttrAccount as String: server]
        SecItemDelete(query as CFDictionary)
        unsetenv(envVar(for: server))
    }

    /// Called before the engine starts so bearer_token_env_var lookups succeed.
    static func exportAllToEnvironment() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "pocode.mcp",
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true,
                                    kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
               let data = item[kSecValueData as String] as? Data,
               let token = String(data: data, encoding: .utf8) {
                setenv(envVar(for: account), token, 1)
            }
        }
    }
}

// MARK: - Views

/// Settings → Extensions: the user's skills and MCP servers.
struct SkillsSettingsView: View {
    @State private var skills: [(name: String, description: String)] = []
    @State private var status = "Loading…"

    var body: some View {
        List {
            if skills.isEmpty {
                Text(status).foregroundStyle(VS.textDim)
            }
            ForEach(skills, id: \.name) { skill in
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                    if !skill.description.isEmpty {
                        Text(skill.description).font(.caption).foregroundStyle(VS.textDim)
                    }
                }
            }
            Section {
            } footer: {
                Text("Add skills by dropping a folder containing SKILL.md into Files → Pocode → codex-home/skills. Codex picks them up automatically.")
            }
        }
        .navigationTitle("Skills")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        let loaded: [(String, String)]? = await Task.detached(priority: .userInitiated) { () -> [(String, String)]? in
            let (client, error) = CodexRuntime.managementClient()
            guard let client else { await MainActor.run { status = error ?? "engine unavailable" }; return nil }
            guard let result = client.rawRequest(method: "skills/list", params: ["forceReload": true]),
                  let data = result["data"] as? [[String: Any]] else { return [] }
            func str(_ entry: [String: Any], _ key: String) -> String? {
                (entry[key] as? String)
                    ?? ((entry["skill"] as? [String: Any])?[key] as? String)
                    ?? ((entry["metadata"] as? [String: Any])?[key] as? String)
            }
            return data.compactMap { entry in
                guard let name = str(entry, "name") else { return nil }
                return (name, str(entry, "description") ?? "")
            }
        }.value
        if let loaded {
            skills = loaded
            status = loaded.isEmpty ? "No skills installed yet." : ""
        }
    }
}

struct McpServersSettingsView: View {
    @State private var servers: [McpConfigFile.Server] = []
    @State private var statusByName: [String: String] = [:]
    @State private var showAdd = false

    var body: some View {
        List {
            if servers.isEmpty {
                Text("No MCP servers configured.").foregroundStyle(VS.textDim)
            }
            ForEach(servers) { server in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(server.name)
                        Spacer()
                        Text(statusByName[server.name] ?? "")
                            .font(.caption)
                            .foregroundStyle(VS.textDim)
                    }
                    Text(server.url).font(.caption).foregroundStyle(VS.textDim)
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    let server = servers[index]
                    McpConfigFile.remove(name: server.name)
                    McpTokenStore.delete(server: server.name)
                }
                servers.remove(atOffsets: offsets)
                Task.detached { reloadEngine() }
            }
            Section {
            } footer: {
                Text("Streamable-HTTP MCP servers (the kind cloud services provide). Codex can use their tools in every conversation.")
            }
        }
        .navigationTitle("MCP Servers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showAdd) {
            AddMcpServerView { name, url, token in
                if let token, !token.isEmpty {
                    McpTokenStore.save(server: name, token: token)
                    McpConfigFile.upsert(name: name, url: url, tokenEnvVar: McpTokenStore.envVar(for: name))
                } else {
                    McpConfigFile.upsert(name: name, url: url, tokenEnvVar: nil)
                }
                servers = McpConfigFile.list()
                Task.detached { reloadEngine(); await refreshStatus() }
            }
        }
        .task {
            servers = McpConfigFile.list()
            await Task.detached { reloadEngine() }.value
            await refreshStatus()
        }
        .refreshable { await refreshStatus() }
    }

    private nonisolated func reloadEngine() {
        let (client, _) = CodexRuntime.managementClient()
        _ = client?.rawRequest(method: "config/mcpServer/reload", params: [:])
    }

    private func refreshStatus() async {
        let status: [String: String] = await Task.detached { () -> [String: String] in
            let (client, _) = CodexRuntime.managementClient()
            guard let result = client?.rawRequest(method: "mcpServerStatus/list", params: [:]),
                  let data = result["data"] as? [[String: Any]] else { return [:] }
            var out: [String: String] = [:]
            for entry in data {
                guard let name = entry["name"] as? String else { continue }
                if let runtime = entry["runtimeStatus"] as? [String: Any] {
                    out[name] = (runtime["type"] as? String) ?? "configured"
                } else if entry["serverCapabilities"] != nil {
                    out[name] = "reachable"
                } else {
                    out[name] = "configured"
                }
            }
            return out
        }.value
        statusByName = status
    }
}

private struct AddMcpServerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    let onSave: (String, String, String?) -> Void

    private var nameOK: Bool { !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
    private var urlOK: Bool { url.hasPrefix("https://") || url.hasPrefix("http://") }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (e.g. github)", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("URL (https://…/mcp)", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    SecureField("Bearer token (optional)", text: $token)
                } footer: {
                    Text("Stored in the Keychain; sent as an Authorization header.")
                }
            }
            .navigationTitle("Add MCP Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onSave(name, url, token.isEmpty ? nil : token)
                        dismiss()
                    }
                    .disabled(!nameOK || !urlOK)
                }
            }
        }
    }
}
