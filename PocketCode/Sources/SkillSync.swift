import Foundation

/// Mirrors skills from user-chosen cloud folders (iCloud Drive, Google Drive,
/// Dropbox — anything the Files app exposes) into CODEX_HOME/skills, so the
/// same skills follow the user across devices. Folders are remembered as
/// security-scoped bookmarks; a manifest tracks what we created so removals
/// clean up after themselves.
enum SkillSync {
    struct Source: Identifiable, Codable, Equatable {
        var id: UUID
        var name: String
        var bookmark: Data
        var lastSync: Date?
        var lastResult: String?
    }

    private static let defaultsKey = "skills.syncSources"
    private static let manifestKey = "skills.syncedDirs"

    static func sources() -> [Source] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([Source].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [Source]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: defaultsKey)
    }

    static func add(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData() else { return }
        var list = sources()
        list.removeAll { $0.name == url.lastPathComponent }
        list.append(Source(id: UUID(), name: url.lastPathComponent, bookmark: bookmark))
        save(list)
    }

    static func remove(_ source: Source) {
        save(sources().filter { $0.id != source.id })
        cleanUpManagedDirs(keeping: [])
        _ = syncAll() // re-mirror what's left
    }

    /// Mirrors every source; returns the refreshed source list.
    @discardableResult
    static func syncAll() -> [Source] {
        var list = sources()
        var mirrored: [String] = []
        for index in list.indices {
            var resolved: URL?
            var stale = false
            resolved = try? URL(resolvingBookmarkData: list[index].bookmark, bookmarkDataIsStale: &stale)
            guard let url = resolved else {
                list[index].lastResult = "folder unavailable"
                continue
            }
            if stale, let fresh = try? url.bookmarkData() { list[index].bookmark = fresh }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copied = mirror(from: url, prefix: list[index].name, into: &mirrored)
            list[index].lastSync = Date()
            list[index].lastResult = "\(copied) skill\(copied == 1 ? "" : "s")"
        }
        cleanUpManagedDirs(keeping: mirrored)
        UserDefaults.standard.set(mirrored, forKey: manifestKey)
        save(list)
        return list
    }

    /// Copies each skill (a directory containing SKILL.md, or the folder itself)
    /// into CODEX_HOME/skills. Returns how many skills were mirrored.
    private static func mirror(from url: URL, prefix: String, into mirrored: inout [String]) -> Int {
        let fm = FileManager.default
        let skillsRoot = CodexRuntime.home.appendingPathComponent("skills", isDirectory: true)
        try? fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)

        var candidates: [URL] = []
        if fm.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) {
            candidates = [url]
        } else if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
            candidates = children.filter { fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
        }

        var copied = 0
        for skill in candidates {
            // Prefix with the source name so two folders can't collide.
            let destName = "\(prefix)-\(skill.lastPathComponent)"
                .replacingOccurrences(of: " ", with: "-")
            let dest = skillsRoot.appendingPathComponent(destName, isDirectory: true)
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: skill, to: dest)
                mirrored.append(destName)
                copied += 1
            } catch {
                continue
            }
        }
        return copied
    }

    /// Removes previously mirrored directories that no source produced this time.
    private static func cleanUpManagedDirs(keeping: [String]) {
        let fm = FileManager.default
        let skillsRoot = CodexRuntime.home.appendingPathComponent("skills", isDirectory: true)
        let previous = UserDefaults.standard.stringArray(forKey: manifestKey) ?? []
        for name in previous where !keeping.contains(name) {
            try? fm.removeItem(at: skillsRoot.appendingPathComponent(name))
        }
    }
}
