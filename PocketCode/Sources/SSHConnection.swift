import Foundation
import os
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// Accepts only the pinned host key. An unknown host (nothing pinned yet) or a changed key
/// aborts the handshake with an error carrying the key, so the UI can show its fingerprint
/// and let the person decide; trusting it pins the key and connects again.
final class PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let pinned: String?
    private(set) var seenKey: String?

    init(pinned: String?) { self.pinned = pinned }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        seenKey = key
        switch pinned {
        case nil: validationCompletePromise.fail(SSHConnectError.unknownHost(key))
        case key: validationCompletePromise.succeed(())
        default: validationCompletePromise.fail(SSHConnectError.hostKeyChanged(key))
        }
    }
}

/// OpenSSH-style fingerprint of a public key line ("ssh-ed25519 AAAA…"): "SHA256:base64-no-padding".
enum HostKeyFingerprint {
    static func sha256(_ openSSHKey: String) -> String {
        let parts = openSSHKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "(unreadable key)" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static func type(_ openSSHKey: String) -> String {
        switch openSSHKey.split(separator: " ").first.map(String.init) ?? "" {
        case "ssh-ed25519": return "ED25519"
        case "ssh-rsa": return "RSA"
        case let t where t.hasPrefix("ecdsa-sha2-"): return "ECDSA"
        case let t: return t
        }
    }
}

let sshLog = Logger(subsystem: "com.jlmxstudio.pocketcode", category: "ssh")

enum SSHConnectError: LocalizedError {
    /// The server presented a different key than the one pinned (associated: the new key).
    case hostKeyChanged(String)
    /// First connection: nothing pinned yet (associated: the server's key).
    case unknownHost(String)

    var errorDescription: String? {
        switch self {
        case .unknownHost:
            return "This server hasn't been verified yet."
        case .hostKeyChanged:
            return "The host key for this server has changed. This could mean someone is intercepting the connection. If you expected this (e.g. the server was reinstalled), reconnect and choose “Trust New Key” after checking the fingerprint."
        }
    }
}

/// Claims a one-shot continuation: whichever racer calls `claim()` first wins.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}

/// One SSH connection shared by the SFTP explorer and any number of terminals.
/// The underlying client can be rebuilt (`reconnect()`) after iOS drops the socket in the background.
@MainActor
final class SSHConnection {
    let host: SSHHost
    private(set) var client: SSHClient
    private(set) var sftp: SFTPClient?
    /// Kept in memory only, so the session can sign in again without asking.
    private let secrets: HostSecrets
    /// Host key seen on the first connect; later reconnects must present the same key.
    private var pinnedKey: String?

    /// Connection phases shown in the UI while connecting.
    enum Stage: String {
        case signingIn = "Connecting & signing in…"
        case openingFiles = "Opening file browser…"
    }

    private init(host: SSHHost, secrets: HostSecrets, client: SSHClient, sftp: SFTPClient?, pinnedKey: String?) {
        self.host = host
        self.secrets = secrets
        self.client = client
        self.sftp = sftp
        self.pinnedKey = pinnedKey
    }

    /// Connects and returns the connection plus the server's host key (for pinning).
    static func connect(host: SSHHost, secrets: HostSecrets,
                        progress: @escaping (Stage) -> Void = { _ in }) async throws -> (SSHConnection, String?) {
        let (client, sftp, seenKey) = try await open(host: host, secrets: secrets, pinned: host.pinnedHostKey, progress: progress)
        let conn = SSHConnection(host: host, secrets: secrets, client: client, sftp: sftp, pinnedKey: seenKey ?? host.pinnedHostKey)
        return (conn, seenKey)
    }

    private static func open(host: SSHHost, secrets: HostSecrets, pinned: String?,
                             progress: @escaping (Stage) -> Void) async throws -> (SSHClient, SFTPClient?, String?) {
        let auth: SSHAuthenticationMethod
        switch host.auth {
        case .password:
            auth = .passwordBased(username: host.username, password: secrets.password)
        case .privateKey:
            auth = try PrivateKeyParser.parse(secrets.privateKey, passphrase: secrets.passphrase)
                .authMethod(username: host.username)
        }
        let validator = PinnedHostKeyValidator(pinned: pinned)
        #if DEBUG
        sshLog.debug("connect start \(host.hostname, privacy: .public):\(host.port) auth=\(host.auth.rawValue, privacy: .public)")
        #endif
        let t0 = Date()
        progress(.signingIn)
        let client = try await SSHClient.connect(
            host: host.hostname,
            port: host.port,
            authenticationMethod: auth,
            hostKeyValidator: .custom(validator),
            reconnect: .never,
            connectTimeout: .seconds(15)
        )
        sshLog.info("auth OK in \(String(format: "%.1f", Date().timeIntervalSince(t0)), privacy: .public)s")
        progress(.openingFiles)
        // SFTP is optional: a host with only the SSH shell enabled (common on NAS boxes)
        // still gets a working terminal; the explorer just explains what's missing.
        // Hard 10s cap: some servers accept the channel but never answer the subsystem request.
        let sftp = await Self.openSFTP(client, timeoutSeconds: 10)
        sshLog.info("sftp \(sftp == nil ? "unavailable" : "OK", privacy: .public) at \(String(format: "%.1f", Date().timeIntervalSince(t0)), privacy: .public)s")
        return (client, sftp, validator.seenKey)
    }

    /// The file system the explorer should use for this connection right now.
    func makeFileSystem() -> FileSystemProvider {
        if let sftp { return SFTPFileSystem(sftp: sftp, startPath: host.startPath) }
        return UnavailableFileSystem(message: "Logged in to \(host.hostname), but it does not offer SFTP, so files can't be browsed. On a NAS, enable SFTP (Synology: Control Panel → File Services → FTP). The terminal works normally.")
    }

    /// True if the session still answers a round trip within `timeoutSeconds`.
    /// After a long background stint the socket can look open while the peer is long gone,
    /// so `isConnected` alone is not enough.
    func isHealthy(timeoutSeconds: UInt64 = 5) async -> Bool {
        guard client.isConnected else { return false }
        let client = client, sftp = sftp
        let once = Once()
        return await withCheckedContinuation { cont in
            Task {
                let ok: Bool
                if let sftp, sftp.isActive {
                    ok = (try? await sftp.getRealPath(atPath: ".")) != nil
                } else {
                    ok = (try? await client.executeCommand("true")) != nil
                }
                if once.claim() { cont.resume(returning: ok) }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if once.claim() { cont.resume(returning: false) }
            }
        }
    }

    /// Throws away the old session and signs in again with the same credentials and pinned host key.
    func reconnect() async throws {
        let oldClient = client, oldSFTP = sftp
        Task { try? await oldSFTP?.close(); try? await oldClient.close() }
        let (client, sftp, seenKey) = try await Self.open(host: host, secrets: secrets, pinned: pinnedKey, progress: { _ in })
        self.client = client
        self.sftp = sftp
        if pinnedKey == nil { pinnedKey = seenKey }
        sshLog.info("reconnected")
    }

    enum RunError: LocalizedError {
        case timedOut
        var errorDescription: String? { "The server took too long to answer." }
    }

    /// Runs a POSIX `sh` script on the host and returns stdout. The script's own failures
    /// are swallowed (Citadel throws on any non-zero exit or stderr output), so callers
    /// interpret empty output themselves. Works the same whatever the login shell is.
    func run(_ script: String, timeoutSeconds: UInt64 = 30, maxBytes: Int = 8 << 20) async throws -> String {
        let client = client
        let command = "sh -c \(PathUtil.shellQuote(script)) 2>/dev/null; true"
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            Task {
                do {
                    let buf = try await client.executeCommand(command, maxResponseSize: maxBytes)
                    if once.claim() { cont.resume(returning: String(decoding: buf.readableBytesView, as: UTF8.self)) }
                } catch {
                    if once.claim() { cont.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                if once.claim() { cont.resume(throwing: RunError.timedOut) }
            }
        }
    }

    /// Retries the SFTP subsystem on the existing session (e.g. after the user enabled it on the server).
    func reopenSFTP() async -> SFTPClient? {
        if let sftp { return sftp }
        sftp = await Self.openSFTP(client, timeoutSeconds: 10)
        return sftp
    }

    /// Opens SFTP with a hard timeout. A task group would await the hung child on exit,
    /// so this races two unstructured tasks instead; whichever claims first wins.
    private static func openSFTP(_ client: SSHClient, timeoutSeconds: UInt64) async -> SFTPClient? {
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

    /// Kept for callers/tests written against the original OpenSSH-only helper.
    nonisolated static func normalizedOpenSSHKey(_ raw: String) -> String { PrivateKeyParser.normalizedPEM(raw) }

    func close() {
        let client = client, sftp = sftp
        Task {
            try? await sftp?.close()
            try? await client.close()
        }
    }
}
