import Foundation
import Citadel
import NIOCore

struct FileItem: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    var size: UInt64?
    var modified: Date?
    var isSymlink = false
}

enum FSError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Abstraction over a file tree: the app's local sandbox or a remote host over SFTP.
@MainActor
protocol FileSystemProvider: AnyObject {
    /// Path of the folder the workspace opens at.
    func initialPath() async throws -> String
    func list(_ path: String) async throws -> [FileItem]
    func read(_ path: String) async throws -> Data
    /// Size in bytes, or nil if the server doesn't say.
    func fileSize(_ path: String) async throws -> UInt64?
    func write(_ data: Data, to path: String) async throws
    func createDirectory(_ path: String) async throws
    func delete(_ item: FileItem) async throws
    func rename(_ from: String, to: String) async throws
}

extension FileSystemProvider {
    func createFile(_ path: String) async throws { try await write(Data(), to: path) }
}

enum PathUtil {
    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }
    static func parent(_ path: String) -> String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    static func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Single-quote a path for safe use in a POSIX shell command.
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - Local

@MainActor
final class LocalFileSystem: FileSystemProvider {
    private let root: URL
    private let scoped: Bool

    init(root: URL, securityScoped: Bool = false) {
        self.root = root
        self.scoped = securityScoped && root.startAccessingSecurityScopedResource()
    }

    deinit { if scoped { root.stopAccessingSecurityScopedResource() } }

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    func initialPath() async throws -> String { root.path }

    func list(_ path: String) async throws -> [FileItem] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
        return PathUtil.sorted(urls.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return FileItem(name: u.lastPathComponent, path: u.path, isDirectory: v?.isDirectory ?? false,
                            size: v?.fileSize.map(UInt64.init), modified: v?.contentModificationDate)
        })
    }

    func read(_ path: String) async throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
    func fileSize(_ path: String) async throws -> UInt64? {
        (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }
    func write(_ data: Data, to path: String) async throws { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    func createDirectory(_ path: String) async throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }
    func delete(_ item: FileItem) async throws { try FileManager.default.removeItem(atPath: item.path) } // removes links, not targets
    func rename(_ from: String, to: String) async throws { try FileManager.default.moveItem(atPath: from, toPath: to) }

    /// Creates a small sample project so the local workspace isn't empty on first launch.
    static func seedWelcomeProjectIfNeeded() {
        let flag = "pocketcode.seeded"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        let dir = documents.appendingPathComponent("welcome", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        let files: [String: String] = [
            "README.md": "# Welcome to PocketCode\n\nA pocket-sized code editor.\n\n- **Explorer** — browse local or remote (SFTP) folders\n- **Editor** — syntax highlighting, line numbers, find, save\n- **Terminal** — a real shell over SSH\n\nAdd an SSH host on the home screen to work on a remote machine.\n",
            "src/main.swift": "import Foundation\n\nstruct Greeter {\n    let name: String\n\n    func greet() -> String {\n        // String interpolation\n        return \"Hello, \\(name)!\"\n    }\n}\n\nlet greeter = Greeter(name: \"PocketCode\")\nprint(greeter.greet())\n",
            "src/app.py": "import sys\n\n\ndef fib(n: int) -> int:\n    \"\"\"Return the n-th Fibonacci number.\"\"\"\n    a, b = 0, 1\n    for _ in range(n):\n        a, b = b, a + b\n    return a\n\n\nif __name__ == \"__main__\":\n    print(fib(int(sys.argv[1]) if len(sys.argv) > 1 else 10))\n",
            "src/index.ts": "type User = { id: number; name: string };\n\nexport async function loadUsers(url: string): Promise<User[]> {\n  const res = await fetch(url);\n  if (!res.ok) throw new Error(`HTTP ${res.status}`);\n  return res.json();\n}\n",
            "package.json": "{\n  \"name\": \"welcome\",\n  \"version\": \"1.0.0\",\n  \"scripts\": { \"start\": \"node dist/index.js\" }\n}\n",
        ]
        for (name, body) in files { try? body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    }
}

/// Stands in when the host accepted the SSH login but refused the SFTP subsystem.
@MainActor
final class UnavailableFileSystem: FileSystemProvider {
    private let message: String
    init(message: String) { self.message = message }
    private var error: FSError { .message(message) }
    func initialPath() async throws -> String { throw error }
    func list(_ path: String) async throws -> [FileItem] { throw error }
    func read(_ path: String) async throws -> Data { throw error }
    func fileSize(_ path: String) async throws -> UInt64? { throw error }
    func write(_ data: Data, to path: String) async throws { throw error }
    func createDirectory(_ path: String) async throws { throw error }
    func delete(_ item: FileItem) async throws { throw error }
    func rename(_ from: String, to: String) async throws { throw error }
}

// MARK: - SFTP

@MainActor
final class SFTPFileSystem: FileSystemProvider {
    let sftp: SFTPClient
    private let startPath: String

    init(sftp: SFTPClient, startPath: String) {
        self.sftp = sftp
        self.startPath = startPath
    }

    func initialPath() async throws -> String {
        let p = startPath.trimmingCharacters(in: .whitespaces)
        return try await sftp.getRealPath(atPath: p.isEmpty ? "." : p)
    }

    func list(_ path: String) async throws -> [FileItem] {
        let names: [SFTPMessage.Name]
        do {
            names = try await sftp.listDirectory(atPath: path)
        } catch {
            throw Self.friendlyError(error, path: path)
        }
        var out: [FileItem] = []
        for comp in names.flatMap(\.components) where comp.filename != "." && comp.filename != ".." {
            let full = PathUtil.join(path, comp.filename)
            var attrs = comp.attributes
            let mode = (attrs.permissions ?? 0) & 0o170000
            let isLink = mode == 0o120000 || comp.longname.hasPrefix("l")
            if isLink {
                // Symlink: follow it to see whether it points at a directory.
                if let target = try? await sftp.getAttributes(at: full) { attrs = target }
            }
            let isDir = ((attrs.permissions ?? 0) & 0o170000) == 0o040000 || (attrs.permissions == nil && comp.longname.hasPrefix("d"))
            out.append(FileItem(name: comp.filename, path: full, isDirectory: isDir,
                                size: attrs.size, modified: attrs.accessModificationTime?.modificationTime,
                                isSymlink: isLink))
        }
        return PathUtil.sorted(out)
    }

    /// Turns Citadel's opaque `SFTPMessage.Status error N` into something a user
    /// can act on. The macOS SFTP server sends an empty message for most denials,
    /// and the common one — protected folders (Desktop/Documents/Downloads) that
    /// need Full Disk Access granted to Remote Login (sshd) — otherwise shows only
    /// a cryptic code.
    static func friendlyError(_ error: Error, path: String) -> Error {
        guard let status = error as? SFTPMessage.Status else { return error }
        let name = (path as NSString).lastPathComponent
        let fda = "On macOS, protected folders (Desktop, Documents, Downloads) need Full Disk Access granted to Remote Login in System Settings → Privacy & Security → Full Disk Access."
        switch status.errorCode {
        case .permissionDenied:
            return FSError.message("\(name): permission denied. \(fda)")
        case .noSuchFile:
            return FSError.message("\(name): no such file or directory.")
        case .failure where status.message.isEmpty:
            return FSError.message("\(name): the server refused this operation. \(fda)")
        default:
            let detail = status.message.isEmpty ? status.errorCode.debugDescription : status.message
            return FSError.message("\(name): \(detail)")
        }
    }

    func read(_ path: String) async throws -> Data {
        let buffer: NIOCore.ByteBuffer
        do {
            buffer = try await sftp.withFile(filePath: path, flags: .read) { try await $0.readAll() }
        } catch {
            throw Self.friendlyError(error, path: path)
        }
        return Data(buffer.readableBytesView)
    }

    func fileSize(_ path: String) async throws -> UInt64? { try await sftp.getAttributes(at: path).size }

    func write(_ data: Data, to path: String) async throws {
        let buffer = ByteBuffer(bytes: data)
        try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
            try await file.write(buffer, at: 0)
        }
    }

    func createDirectory(_ path: String) async throws { try await sftp.createDirectory(atPath: path) }

    func delete(_ item: FileItem) async throws {
        if item.isDirectory && !item.isSymlink {
            for child in try await list(item.path) { try await delete(child) }
            try await sftp.rmdir(at: item.path)
        } else {
            try await sftp.remove(at: item.path)
        }
    }

    func rename(_ from: String, to: String) async throws { try await sftp.rename(at: from, to: to) }
}
