import Foundation
import os
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// Pins the server's host key on first connect and rejects later mismatches (trust-on-first-use).
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let pinned: String?
    private(set) var seenKey: String?

    init(pinned: String?) { self.pinned = pinned }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        seenKey = key
        if let pinned, pinned != key {
            validationCompletePromise.fail(SSHConnectError.hostKeyChanged(key))
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

let sshLog = Logger(subsystem: "com.jlmxstudio.pocketcode", category: "ssh")

enum SSHConnectError: LocalizedError {
    case hostKeyChanged(String)
    case badPrivateKey

    var errorDescription: String? {
        switch self {
        case .hostKeyChanged:
            return "The host key for this server has changed. This could mean someone is intercepting the connection. If you expected this (e.g. the server was reinstalled), use “Forget Host Key” in the host settings."
        case .badPrivateKey:
            return "Could not read the private key. Paste an OpenSSH ed25519 or RSA key (-----BEGIN OPENSSH PRIVATE KEY-----)."
        }
    }
}

/// One SSH connection shared by the SFTP explorer and any number of terminals.
@MainActor
final class SSHConnection {
    let host: SSHHost
    let client: SSHClient
    let sftp: SFTPClient?

    private init(host: SSHHost, client: SSHClient, sftp: SFTPClient?) {
        self.host = host
        self.client = client
        self.sftp = sftp
    }

    /// Connects and returns the connection plus the server's host key (for pinning).
    static func connect(host: SSHHost, secrets: HostSecrets) async throws -> (SSHConnection, String?) {
        let auth: SSHAuthenticationMethod
        switch host.auth {
        case .password:
            auth = .passwordBased(username: host.username, password: secrets.password)
        case .privateKey:
            let pass = secrets.passphrase.isEmpty ? nil : Data(secrets.passphrase.utf8)
            let pem = SSHConnection.normalizedOpenSSHKey(secrets.privateKey)
            if let k = try? Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: pass) {
                auth = .ed25519(username: host.username, privateKey: k)
            } else if let k = try? Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: pass) {
                auth = .rsa(username: host.username, privateKey: k)
            } else {
                throw SSHConnectError.badPrivateKey
            }
        }
        let validator = TOFUHostKeyValidator(pinned: host.pinnedHostKey)
        sshLog.info("connect start \(host.hostname, privacy: .public):\(host.port) auth=\(host.auth.rawValue, privacy: .public) user=\(host.username, privacy: .public) pwlen=\(host.auth == .password ? secrets.password.count : -1)")
        let t0 = Date()
        let client = try await SSHClient.connect(
            host: host.hostname,
            port: host.port,
            authenticationMethod: auth,
            hostKeyValidator: .custom(validator),
            reconnect: .never,
            connectTimeout: .seconds(15)
        )
        sshLog.info("auth OK in \(String(format: "%.1f", Date().timeIntervalSince(t0)), privacy: .public)s; opening SFTP")
        // SFTP is optional: a host with only the SSH shell enabled (common on NAS boxes)
        // still gets a working terminal; the explorer just explains what's missing.
        // Hard 10s cap: some servers accept the channel but never answer the subsystem request.
        let sftp = await Self.openSFTP(client, timeoutSeconds: 10)
        sshLog.info("sftp \(sftp == nil ? "unavailable" : "OK", privacy: .public) at \(String(format: "%.1f", Date().timeIntervalSince(t0)), privacy: .public)s")
        return (SSHConnection(host: host, client: client, sftp: sftp), validator.seenKey)
    }

    /// Opens SFTP with a hard timeout. A task group would await the hung child on exit,
    /// so this races two unstructured tasks instead; whichever claims first wins.
    private static func openSFTP(_ client: SSHClient, timeoutSeconds: UInt64) async -> SFTPClient? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
        }
        let once = Once()
        return await withCheckedContinuation { cont in
            Task {
                let c = try? await client.openSFTP()
                if once.claim() { cont.resume(returning: c) } else if let c { try? await c.close() }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// Rebuilds the BEGIN/END lines and strips stray whitespace, so a key whose dashes were
    /// mangled by smart punctuation (or that lost line breaks when pasted) still parses.
    static func normalizedOpenSSHKey(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\r", with: "")
        guard let begin = text.range(of: "BEGIN OPENSSH PRIVATE KEY"),
              let end = text.range(of: "END OPENSSH PRIVATE KEY", range: begin.upperBound..<text.endIndex)
        else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        let body = String(text[begin.upperBound..<end.lowerBound].unicodeScalars.filter { allowed.contains($0) })
        var lines: [String] = []
        var i = body.startIndex
        while i < body.endIndex {
            let j = body.index(i, offsetBy: 70, limitedBy: body.endIndex) ?? body.endIndex
            lines.append(String(body[i..<j]))
            i = j
        }
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + lines + ["-----END OPENSSH PRIVATE KEY-----"]).joined(separator: "\n")
    }

    func close() {
        let client = client, sftp = sftp
        Task {
            try? await sftp?.close()
            try? await client.close()
        }
    }
}
