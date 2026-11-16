import SwiftUI

/// How a path differs from HEAD, as `git status --porcelain` reports it.
enum GitChange: Int, Comparable {
    case added = 1, untracked, renamed, modified, deleted, conflict
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var letter: String {
        switch self {
        case .added: return "A"
        case .untracked: return "U"
        case .renamed: return "R"
        case .modified: return "M"
        case .deleted: return "D"
        case .conflict: return "!"
        }
    }

    var color: Color {
        switch self {
        case .added, .renamed: return VS.gitAdded
        case .untracked: return VS.gitUntracked
        case .modified: return VS.gitModified
        case .deleted: return VS.gitDeleted
        case .conflict: return VS.gitConflict
        }
    }
}

struct GitSnapshot: Equatable {
    var branch: String
    /// Absolute path → change, for files (and untracked folders git reports as a whole).
    var files: [String: GitChange]
    /// Folders containing changes → most severe change inside (VS Code tints those folders).
    var folders: [String: GitChange]

    func change(for path: String) -> GitChange? { files[path] ?? folders[path] }

    /// Shell script printing the repo top level, then `git status -b -z`. Prints nothing outside a repo.
    static func script(root: String) -> String {
        "cd \(PathUtil.shellQuote(root)) && top=$(git rev-parse --show-toplevel) && printf '%s\\n' \"$top\" && git status --porcelain=v1 -b -z"
    }

    static func parse(_ output: String) -> GitSnapshot? {
        guard let nl = output.firstIndex(of: "\n") else { return nil }
        let top = String(output[..<nl])
        guard top.hasPrefix("/") else { return nil }
        var entries = output[output.index(after: nl)...].split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var branch = "HEAD"
        if let first = entries.first, first.hasPrefix("## ") {
            entries.removeFirst()
            branch = Self.branchName(String(first.dropFirst(3)))
        }
        var files: [String: GitChange] = [:]
        var i = 0
        while i < entries.count {
            let e = entries[i]
            i += 1
            guard e.count > 3 else { continue }
            let xy = Array(e.prefix(2))
            var rel = String(e.dropFirst(3))
            if xy[0] == "R" || xy[0] == "C" { i += 1 } // next entry is the original path
            if rel.hasSuffix("/") { rel.removeLast() }
            guard let change = Self.change(x: xy[0], y: xy[1]) else { continue }
            files[PathUtil.join(top, rel)] = change
        }
        var folders: [String: GitChange] = [:]
        for (path, change) in files {
            var dir = PathUtil.parent(path)
            while dir.count >= top.count {
                if let c = folders[dir], c >= change { break }
                folders[dir] = change
                if dir == top || dir == "/" { break }
                dir = PathUtil.parent(dir)
            }
        }
        return GitSnapshot(branch: branch, files: files, folders: folders)
    }

    private static func change(x: Character, y: Character) -> GitChange? {
        if x == "?" && y == "?" { return .untracked }
        if x == "!" { return nil } // ignored
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { return .conflict }
        if x == "D" || y == "D" { return .deleted }
        if x == "R" || x == "C" { return .renamed }
        if x == "A" { return y == "M" ? .modified : .added }
        return .modified
    }

    /// "main...origin/main [ahead 1]" → "main"; "No commits yet on dev" → "dev".
    private static func branchName(_ s: String) -> String {
        if s.hasPrefix("No commits yet on ") { return String(s.dropFirst("No commits yet on ".count)) }
        if s.hasPrefix("Initial commit on ") { return String(s.dropFirst("Initial commit on ".count)) }
        if s.hasPrefix("HEAD (no branch)") { return "HEAD (detached)" }
        let name = s.components(separatedBy: "...").first ?? s
        return name.components(separatedBy: " ").first ?? name
    }
}
