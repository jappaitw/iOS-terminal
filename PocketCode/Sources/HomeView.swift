import SwiftUI
import UniformTypeIdentifiers
import Citadel
import NIOPosix

struct HomeView: View {
    let onOpen: (Workspace) -> Void
    @EnvironmentObject private var store: HostStore
    @State private var editing: SSHHost?
    @State private var connecting: SSHHost.ID?
    @State private var stage: SSHConnection.Stage?
    @State private var error: String?
    @State private var pickingFolder = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { openLocal(LocalFileSystem.documents, title: "On My iPhone", scoped: false) } label: {
                        row(icon: "iphone", title: "On My iPhone", subtitle: "App documents (visible in the Files app)")
                    }
                    Button { pickingFolder = true } label: {
                        row(icon: "folder.badge.plus", title: "Open Folder…", subtitle: "From Files, iCloud Drive or a provider")
                    }
                } header: { Text("Local") }

                Section {
                    ForEach(store.hosts) { host in
                        Button { connect(host) } label: {
                            HStack {
                                row(icon: "server.rack", title: host.displayName,
                                    subtitle: connecting == host.id ? (stage?.rawValue ?? "Connecting…") : host.subtitle)
                                Spacer()
                                if connecting == host.id { ProgressView() }
                            }
                        }
                        .disabled(connecting != nil)
                        .swipeActions {
                            Button(role: .destructive) { store.delete(host) } label: { Label("Delete", systemImage: "trash") }
                            Button { editing = host } label: { Label("Edit", systemImage: "pencil") }.tint(.gray)
                        }
                        .contextMenu {
                            Button { editing = host } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { store.delete(host) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    Button { editing = SSHHost() } label: {
                        Label("Add SSH Host…", systemImage: "plus")
                    }
                } header: { Text("Remote — SSH") } footer: {
                    Text("Explorer and editor work over SFTP; the terminal opens a real shell on the host.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(VS.sidebarBG)
            .navigationTitle("PocketCode")
            .sheet(item: $editing) { host in
                HostEditorView(host: host, secrets: store.secrets(for: host)) { h, s in store.upsert(h, secrets: s) }
            }
            .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { openLocal(url, title: url.lastPathComponent, scoped: true) }
            }
            .alert("Couldn't Save Credentials", isPresented: .constant(store.lastSaveError != nil), presenting: store.lastSaveError) { _ in
                Button("OK") { store.lastSaveError = nil }
            } message: { Text($0) }
            .alert("Connection Failed", isPresented: .constant(error != nil), presenting: error) { _ in
                Button("OK") { error = nil }
            } message: { Text($0) }
        }
    }

    private func row(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 28).foregroundStyle(VS.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(VS.text)
                Text(subtitle).font(.caption).foregroundStyle(VS.textDim)
            }
        }
    }

    private func openLocal(_ url: URL, title: String, scoped: Bool) {
        let fs = LocalFileSystem(root: url, securityScoped: scoped)
        onOpen(Workspace(title: title, fs: fs, connection: nil))
    }

    private func connect(_ host: SSHHost) {
        connecting = host.id
        stage = nil
        Task {
            defer { connecting = nil; stage = nil }
            do {
                let (conn, seenKey) = try await SSHConnection.connect(host: host, secrets: store.secrets(for: host)) { s in
                    Task { @MainActor in stage = s }
                }
                if host.pinnedHostKey == nil, let seenKey {
                    var pinned = host
                    pinned.pinnedHostKey = seenKey
                    store.update(pinned)
                }
                onOpen(Workspace(title: host.displayName, fs: conn.makeFileSystem(), connection: conn))
            } catch {
                sshLog.error("connect failed: \(String(describing: error), privacy: .public)")
                self.error = Self.describe(error, host: host)
            }
        }
    }

    /// Turns library error codes into something a person can act on.
    private static func describe(_ error: Error, host: SSHHost) -> String {
        if let e = error as? SSHClientError {
            switch e {
            case .allAuthenticationOptionsFailed:
                return host.auth == .password
                    ? "The server rejected the login for “\(host.username)”. Check the username and password (Edit the host to re-enter it)."
                    : "The server rejected the private key for “\(host.username)”. Make sure its public key is in ~/.ssh/authorized_keys on the server."
            case .unsupportedPasswordAuthentication:
                return "This server doesn't allow password login. Use a private key instead."
            case .unsupportedPrivateKeyAuthentication:
                return "This server doesn't allow private-key login. Use a password instead."
            case .channelCreationFailed:
                return "Logged in, but the server refused to open an SFTP session. Make sure SFTP is enabled on the server."
            default: break
            }
        }
        if let e = error as? NIOConnectionError {
            if e.dnsAError != nil || e.dnsAAAAError != nil {
                return "Couldn't find the host “\(host.hostname)”. Check the address."
            }
            let detail = String(describing: e)
            if detail.contains("refused") || detail.contains("61") {
                return "\(host.hostname) is reachable, but nothing is accepting SSH on port \(host.port). On a Mac, turn on System Settings → General → Sharing → Remote Login."
            }
            return "Couldn't connect to \(host.hostname):\(host.port). Check that the machine is on, on the same network, and has SSH enabled.\n\n\(detail)"
        }
        let text = error.localizedDescription
        if text.contains("Connection refused") { return "Nothing is listening on \(host.hostname):\(host.port). Is SSH (Remote Login) turned on?" }
        if text.lowercased().contains("timed out") || text.contains("connectTimeout") {
            return "Couldn't reach \(host.hostname):\(host.port). Check the address and that you're on the same network."
        }
        return text
    }
}

struct HostEditorView: View {
    @State var host: SSHHost
    @State var secrets: HostSecrets
    let onSave: (SSHHost, HostSecrets) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Key auth with no key can never log in, so don't let it be saved.
    private var canSave: Bool {
        let base = !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.username.trimmingCharacters(in: .whitespaces).isEmpty
        if host.auth == .privateKey {
            return base && secrets.privateKey.contains("PRIVATE KEY")
        }
        return base
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name (optional)", text: $host.name)
                    TextField("Host or IP", text: $host.hostname)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", value: $host.port, format: .number.grouping(.never)).keyboardType(.numberPad)
                    TextField("Username", text: $host.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Authentication") {
                    Picker("Method", selection: $host.auth) {
                        ForEach(AuthKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if host.auth == .password {
                        SecureField("Password", text: $secrets.password)
                    } else {
                        PlainTextView(text: $secrets.privateKey)
                            .frame(minHeight: 120)
                            .overlay(alignment: .topLeading) {
                                if secrets.privateKey.isEmpty {
                                    Text("-----BEGIN OPENSSH PRIVATE KEY-----").font(.caption.monospaced())
                                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 4).allowsHitTesting(false)
                                }
                            }
                        SecureField("Passphrase (if any)", text: $secrets.passphrase)
                    }
                }
                Section {
                    TextField("Start folder (default: home)", text: $host.startPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Workspace") }
                if let key = host.pinnedHostKey {
                    Section {
                        Text(key).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                        Button("Forget Host Key", role: .destructive) { host.pinnedHostKey = nil }
                    } header: { Text("Trusted Host Key") } footer: {
                        Text("Pinned on first connect. A different key will be refused.")
                    }
                }
            }
            .navigationTitle(host.hostname.isEmpty ? "New Host" : host.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(host, secrets); dismiss() }
                        .disabled(!canSave)
                }
            }
        }
    }
}

/// Multi-line text field with every "smart" substitution off, so pasted keys stay byte-for-byte intact.
/// (SwiftUI's TextEditor turns "-----" into em dashes, which breaks OpenSSH keys.)
struct PlainTextView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = .clear
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.smartInsertDeleteType = .no
        tv.keyboardType = .asciiCapable
        tv.delegate = context.coordinator
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textViewDidChange(_ textView: UITextView) { text.wrappedValue = textView.text }
    }
}
