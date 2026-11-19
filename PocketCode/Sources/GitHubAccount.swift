import Foundation
import Security

/// GitHub sign-in state for git-over-HTTPS and repo creation.
/// Token lives in the Keychain only — never files, never logs.
enum GitHubAccount {
    private static let service = "com.jlmxstudio.pocketcode.github"
    private static let accountKey = "github-token"
    private static let loginKey = "gh.login"

    /// Device Flow client ID of the registered "Pocode" GitHub OAuth App.
    /// Device Flow uses no secret, so embedding the ID is the intended model.
    /// Empty string = not registered yet → `git login` falls back to PAT.
    static let oauthClientID = ""

    static var token: String? {
        get { keychainRead() }
        set { if let newValue { keychainWrite(newValue) } else { keychainDelete() } }
    }

    static var login: String? {
        get { UserDefaults.standard.string(forKey: loginKey) }
        set { UserDefaults.standard.set(newValue, forKey: loginKey) }
    }

    static var isSignedIn: Bool { token != nil }

    static func signOut() { token = nil; login = nil }

    // MARK: Device Flow

    struct DeviceCode { let userCode: String, verificationURL: String, deviceCode: String, interval: Int }

    static func startDeviceFlow() async throws -> DeviceCode {
        guard !oauthClientID.isEmpty else {
            throw GHError.message("Device Flow isn't configured in this build — use a Personal Access Token instead.")
        }
        let body = "client_id=\(oauthClientID)&scope=repo"
        let obj = try await postForm("https://github.com/login/device/code", body: body)
        guard let user = obj["user_code"] as? String, let uri = obj["verification_uri"] as? String,
              let device = obj["device_code"] as? String else {
            throw GHError.message("unexpected device-code response")
        }
        return DeviceCode(userCode: user, verificationURL: uri, deviceCode: device,
                          interval: obj["interval"] as? Int ?? 5)
    }

    /// Polls until authorized / denied / cancelled. Returns the login name.
    static func pollDeviceFlow(_ code: DeviceCode, isCancelled: @escaping () -> Bool) async throws -> String {
        while !isCancelled() {
            try await Task.sleep(nanoseconds: UInt64(code.interval) * 1_000_000_000)
            let body = "client_id=\(oauthClientID)&device_code=\(code.deviceCode)"
                + "&grant_type=urn:ietf:params:oauth:grant-type:device_code"
            let obj = try await postForm("https://github.com/login/oauth/access_token", body: body)
            if let t = obj["access_token"] as? String {
                token = t
                let name = (try? await whoAmI()) ?? "github"
                login = name
                return name
            }
            switch obj["error"] as? String {
            case "authorization_pending", "slow_down": continue
            case "expired_token": throw GHError.message("the sign-in code expired — run `git login` again")
            default: throw GHError.message((obj["error_description"] as? String) ?? "sign-in failed")
            }
        }
        throw GHError.message("sign-in cancelled")
    }

    /// Validates a pasted PAT and stores it. Returns the login name.
    static func signInWithPAT(_ pat: String) async throws -> String {
        token = pat
        do {
            let name = try await whoAmI()
            login = name
            return name
        } catch {
            token = nil
            throw error
        }
    }

    static func whoAmI() async throws -> String {
        let obj = try await api("GET", "https://api.github.com/user")
        guard let name = obj["login"] as? String else { throw GHError.message("token rejected by GitHub") }
        return name
    }

    /// POST /user/repos — returns the HTTPS clone URL.
    static func createRepo(name: String, isPrivate: Bool) async throws -> String {
        let obj = try await api("POST", "https://api.github.com/user/repos",
                                json: ["name": name, "private": isPrivate])
        guard let url = obj["clone_url"] as? String else {
            throw GHError.message((obj["message"] as? String) ?? "could not create the repository")
        }
        return url
    }

    // MARK: plumbing

    enum GHError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    private static func postForm(_ url: String, body: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func api(_ method: String, _ url: String, json: [String: Any]? = nil) async throws -> [String: Any] {
        guard let token else { throw GHError.message("not signed in — run `git login`") }
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 {
            signOut()
            throw GHError.message("GitHub token is no longer valid — sign in again with `git login`")
        }
        return obj
    }

    private static func keychainWrite(_ value: String) {
        keychainDelete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: accountKey,
                                kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    private static func keychainRead() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: accountKey,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: accountKey]
        SecItemDelete(q as CFDictionary)
    }
}
