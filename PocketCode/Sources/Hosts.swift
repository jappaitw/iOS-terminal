import Foundation
import Security
import os

private let keychainLog = Logger(subsystem: "com.jlmxstudio.pocketcode", category: "keychain")

enum AuthKind: String, Codable, CaseIterable, Identifiable {
    case password, privateKey
    var id: String { rawValue }
    var label: String { self == .password ? "Password" : "Private Key" }
}

struct SSHHost: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var hostname: String = ""
    var port: Int = 22
    var username: String = ""
    var auth: AuthKind = .password
    /// Remote folder to open in the explorer. Empty means the login (home) directory.
    var startPath: String = ""
    /// OpenSSH-format host public key pinned on first successful connect (TOFU).
    var pinnedHostKey: String?

    var displayName: String { name.isEmpty ? hostname : name }
    var subtitle: String { "\(username)@\(hostname)\(port == 22 ? "" : ":\(port)")" }
}

/// Secrets (password / private key / passphrase) for a host, stored in the Keychain.
struct HostSecrets {
    var password = ""
    var privateKey = ""
    var passphrase = ""
}

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [SSHHost] = []
    private let key = "pocketcode.hosts"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([SSHHost].self, from: data) {
            hosts = decoded
        }
    }

    @Published var lastSaveError: String?

    func upsert(_ host: SSHHost, secrets: HostSecrets) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        let ok = Keychain.set(secrets.password, for: "\(host.id).password")
            && Keychain.set(secrets.privateKey, for: "\(host.id).key")
            && Keychain.set(secrets.passphrase, for: "\(host.id).passphrase")
        if !ok { lastSaveError = "The password or key could not be saved to the Keychain, so the connection will fail. (Is the app signed?)" }
        persist()
    }

    func update(_ host: SSHHost) {
        guard let i = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[i] = host
        persist()
    }

    func delete(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        for s in ["password", "key", "passphrase"] { Keychain.delete("\(host.id).\(s)") }
        persist()
    }

    func secrets(for host: SSHHost) -> HostSecrets {
        HostSecrets(password: Keychain.get("\(host.id).password") ?? "",
                    privateKey: Keychain.get("\(host.id).key") ?? "",
                    passphrase: Keychain.get("\(host.id).passphrase") ?? "")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum Keychain {
    private static let service = "com.jlmxstudio.pocketcode"

    /// Returns false if the secret could not be stored.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        delete(account)
        guard !value.isEmpty else { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { keychainLog.error("SecItemAdd \(account, privacy: .public) failed: \(status)") }
        return status == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status != errSecSuccess { keychainLog.error("SecItemCopyMatching \(account, privacy: .public): \(status)") }
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
