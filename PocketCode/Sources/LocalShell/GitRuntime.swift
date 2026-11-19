import Foundation

/// The `git` terminal command, backed by embedded libgit2 (no fork/exec).
/// Scope per the design spec: init status add commit log remote branch
/// checkout merge(ff-only) push pull clone, plus login/logout and
/// `push --create` (make the GitHub repo, wire origin, push) — enough to move
/// a phone-grown project to a computer and back. HTTPS + token only.
enum GitRuntime {
    static let shellCommand: (@Sendable (ShellContext) async -> Int32)? = { ctx in await run(ctx) }

    static func run(_ ctx: ShellContext) async -> Int32 {
        git_libgit2_init()
        defer { git_libgit2_shutdown() }
        let args = Array(ctx.args.dropFirst())
        guard let sub = args.first else { usage(ctx); return 1 }
        let rest = Array(args.dropFirst())
        do {
            switch sub {
            case "init":      try cmdInit(ctx)
            case "status":    try cmdStatus(ctx)
            case "add":       try cmdAdd(ctx, rest)
            case "commit":    try cmdCommit(ctx, rest)
            case "log":       try cmdLog(ctx, rest)
            case "branch":    try cmdBranch(ctx, rest)
            case "checkout", "switch": try cmdCheckout(ctx, rest)
            case "merge":     try cmdMerge(ctx, rest)
            case "remote":    try cmdRemote(ctx, rest)
            case "push":      try await cmdPush(ctx, rest)
            case "pull":      try await cmdPull(ctx)
            case "clone":     try await cmdClone(ctx, rest)
            case "login":     try await cmdLogin(ctx)
            case "logout":    GitHubAccount.signOut(); ctx.stdout.line("Signed out of GitHub.")
            default:
                ctx.stderr.line("git: '\(sub)' is not supported here (type `git` for the list)")
                return 1
            }
            return 0
        } catch let e as GitError {
            ctx.stderr.line("git \(sub): \(e.message)")
            return 1
        } catch {
            ctx.stderr.line("git \(sub): \(error.localizedDescription)")
            return 1
        }
    }

    private static func usage(_ ctx: ShellContext) {
        ctx.stdout.line("""
        usage: git <command>
          init status add commit log branch checkout merge remote push pull clone
          login logout            sign in to GitHub (token in Keychain)
          push --create [--private]   create the GitHub repo, set origin, push
        """.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    struct GitError: Error { let message: String }

    private static func lastError(_ fallback: String) -> GitError {
        if let e = git_error_last(), let m = e.pointee.message {
            return GitError(message: String(cString: m))
        }
        return GitError(message: fallback)
    }

    private static func check(_ rc: Int32, _ what: String) throws {
        if rc < 0 { throw lastError("\(what) failed (code \(rc))") }
    }

    private static func openRepo(_ ctx: ShellContext) throws -> OpaquePointer {
        var repo: OpaquePointer?
        guard git_repository_open_ext(&repo, ctx.state.cwd.path, UInt32(GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue), ctx.state.sandbox.root.path) == 0,
              let repo else {
            throw GitError(message: "not a git repository (run `git init` here first)")
        }
        return repo
    }

    private static func signature(_ repo: OpaquePointer) throws -> UnsafeMutablePointer<git_signature> {
        var sig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&sig, repo) == 0, let sig { return sig }
        try check(git_signature_now(&sig, "Pocode", "pocode@device"), "signature")
        return sig!
    }

    // MARK: offline commands

    private static func cmdInit(_ ctx: ShellContext) throws {
        var repo: OpaquePointer?
        try check(git_repository_init(&repo, ctx.state.cwd.path, 0), "init")
        git_repository_free(repo)
        ctx.stdout.line("Initialized empty Git repository in \(ctx.state.sandbox.display(ctx.state.cwd))/.git/")
    }

    private static func cmdStatus(_ ctx: ShellContext) throws {
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        var head: OpaquePointer?
        var branch = "(no branch)"
        if git_repository_head(&head, repo) == 0, let head {
            branch = String(cString: git_reference_shorthand(head)); git_reference_free(head)
        } else if git_repository_head_unborn(repo) == 1 {
            branch = "main (no commits yet)"
        }
        ctx.stdout.line("On branch \(branch)")

        var opts = git_status_options()
        git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
        var list: OpaquePointer?
        try check(git_status_list_new(&list, repo, &opts), "status")
        defer { git_status_list_free(list) }
        let n = git_status_list_entrycount(list)
        if n == 0 { ctx.stdout.line("nothing to commit, working tree clean"); return }
        for i in 0..<n {
            guard let e = git_status_byindex(list, i)?.pointee else { continue }
            let s = e.status.rawValue
            let path = e.head_to_index?.pointee.new_file.path ?? e.index_to_workdir?.pointee.new_file.path
            guard let p = path.map({ String(cString: $0) }) else { continue }
            var x = " ", y = " "
            if s & GIT_STATUS_INDEX_NEW.rawValue != 0 { x = "A" }
            if s & GIT_STATUS_INDEX_MODIFIED.rawValue != 0 { x = "M" }
            if s & GIT_STATUS_INDEX_DELETED.rawValue != 0 { x = "D" }
            if s & GIT_STATUS_INDEX_RENAMED.rawValue != 0 { x = "R" }
            if s & GIT_STATUS_WT_NEW.rawValue != 0 { x = (x == " " ? "?" : x); y = "?" }
            if s & GIT_STATUS_WT_MODIFIED.rawValue != 0 { y = "M" }
            if s & GIT_STATUS_WT_DELETED.rawValue != 0 { y = "D" }
            ctx.stdout.line("\(x)\(y) \(p)")
        }
    }

    private static func cmdAdd(_ ctx: ShellContext, _ args: [String]) throws {
        guard !args.isEmpty else { throw GitError(message: "nothing specified — try `git add .`") }
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo), "index")
        defer { git_index_free(index) }
        // Paths are repo-relative; translate from the shell cwd.
        let root = String(cString: git_repository_workdir(repo))
        let cwdRel = ctx.state.cwd.path.hasPrefix(root)
            ? String(ctx.state.cwd.path.dropFirst(root.count)) : ""
        var specs = args.map { a -> String in
            let joined = cwdRel.isEmpty ? a : cwdRel + "/" + a
            return joined == "." ? "*" : joined
        }
        try withPathspec(&specs) { strarray in
            var sa = strarray
            try check(git_index_add_all(index, &sa, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil), "add")
            try check(git_index_update_all(index, &sa, nil, nil), "add")
        }
        try check(git_index_write(index), "index write")
    }

    private static func withPathspec(_ specs: inout [String], _ body: (git_strarray) throws -> Void) rethrows {
        var cstrs = specs.map { strdup($0) }
        defer { cstrs.forEach { free($0) } }
        try cstrs.withUnsafeMutableBufferPointer { buf in
            let arr = git_strarray(strings: buf.baseAddress, count: buf.count)
            try body(arr)
        }
    }

    private static func cmdCommit(_ ctx: ShellContext, _ args: [String]) throws {
        guard let mIdx = args.firstIndex(of: "-m"), args.count > mIdx + 1 else {
            throw GitError(message: "a message is required: git commit -m \"...\"")
        }
        let message = args[(mIdx + 1)...].joined(separator: " ")
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo), "index")
        defer { git_index_free(index) }
        var treeOid = git_oid()
        try check(git_index_write_tree(&treeOid, index), "write-tree")
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repo, &treeOid), "tree")
        defer { git_tree_free(tree) }
        let sig = try signature(repo); defer { git_signature_free(sig) }

        var parent: OpaquePointer?
        var parents: [OpaquePointer?] = []
        var headOid = git_oid()
        if git_reference_name_to_id(&headOid, repo, "HEAD") == 0,
           git_commit_lookup(&parent, repo, &headOid) == 0 {
            parents = [parent]
        }
        defer { if let parent { git_commit_free(parent) } }
        var oid = git_oid()
        try parents.withUnsafeMutableBufferPointer { buf in
            try check(git_commit_create(&oid, repo, "HEAD", sig, sig, nil, message, tree,
                                        buf.count, buf.baseAddress), "commit")
        }
        var short = [CChar](repeating: 0, count: 8)
        git_oid_tostr(&short, 8, &oid)
        ctx.stdout.line("[\(currentBranch(repo) ?? "main") \(String(cString: short))] \(message)")
    }

    private static func currentBranch(_ repo: OpaquePointer) -> String? {
        var head: OpaquePointer?
        guard git_repository_head(&head, repo) == 0, let head else { return nil }
        defer { git_reference_free(head) }
        return String(cString: git_reference_shorthand(head))
    }

    private static func cmdLog(_ ctx: ShellContext, _ args: [String]) throws {
        let limit = args.first.flatMap { $0.hasPrefix("-") ? Int($0.dropFirst()) : nil } ?? 20
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        var walk: OpaquePointer?
        try check(git_revwalk_new(&walk, repo), "log")
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue)
        try check(git_revwalk_push_head(walk), "log (no commits yet?)")
        var oid = git_oid(); var count = 0
        while count < limit, git_revwalk_next(&oid, walk) == 0 {
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repo, &oid) == 0, let commit else { continue }
            defer { git_commit_free(commit) }
            var short = [CChar](repeating: 0, count: 8)
            git_oid_tostr(&short, 8, &oid)
            let msg = git_commit_summary(commit).map { String(cString: $0) } ?? ""
            let who = git_commit_author(commit)?.pointee.name.map { String(cString: $0) } ?? ""
            ctx.stdout.line("\u{1B}[33m\(String(cString: short))\u{1B}[0m \(msg) \u{1B}[2m— \(who)\u{1B}[0m")
            count += 1
        }
    }

    private static func cmdBranch(_ ctx: ShellContext, _ args: [String]) throws {
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        if let name = args.first {
            var headOid = git_oid()
            try check(git_reference_name_to_id(&headOid, repo, "HEAD"), "branch (commit something first)")
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, repo, &headOid), "branch")
            defer { git_commit_free(commit) }
            var ref: OpaquePointer?
            try check(git_branch_create(&ref, repo, name, commit, 0), "branch")
            git_reference_free(ref)
            ctx.stdout.line("Created branch \(name)")
            return
        }
        var iter: OpaquePointer?
        try check(git_branch_iterator_new(&iter, repo, GIT_BRANCH_LOCAL), "branch")
        defer { git_branch_iterator_free(iter) }
        let current = currentBranch(repo)
        var ref: OpaquePointer?; var type = GIT_BRANCH_LOCAL
        while git_branch_next(&ref, &type, iter) == 0 {
            var name: UnsafePointer<CChar>?
            git_branch_name(&name, ref)
            if let name {
                let n = String(cString: name)
                ctx.stdout.line(n == current ? "* \u{1B}[32m\(n)\u{1B}[0m" : "  \(n)")
            }
            git_reference_free(ref)
        }
    }

    private static func cmdCheckout(_ ctx: ShellContext, _ args: [String]) throws {
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        var args = args
        if args.first == "-b" || args.first == "-c" {
            args.removeFirst()
            try cmdBranch(ctx, args)
        }
        guard let name = args.first else { throw GitError(message: "which branch?") }
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, repo, "refs/heads/\(name)"), "checkout: no branch '\(name)'")
        defer { git_object_free(obj) }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try check(git_checkout_tree(repo, obj, &opts), "checkout")
        try check(git_repository_set_head(repo, "refs/heads/\(name)"), "checkout")
        ctx.stdout.line("Switched to branch '\(name)'")
    }

    private static func cmdMerge(_ ctx: ShellContext, _ args: [String]) throws {
        guard let name = args.last, name != "--ff-only" else { throw GitError(message: "which branch?") }
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        var ref: OpaquePointer?
        try check(git_reference_dwim(&ref, repo, name), "merge: no branch '\(name)'")
        defer { git_reference_free(ref) }
        var annotated: OpaquePointer?
        try check(git_annotated_commit_from_ref(&annotated, repo, ref), "merge")
        defer { git_annotated_commit_free(annotated) }
        try fastForward(ctx, repo: repo, annotated: annotated!, label: name)
    }

    /// FF-only merge shared by `merge` and `pull`. Diverged → clean abort.
    private static func fastForward(_ ctx: ShellContext, repo: OpaquePointer,
                                    annotated: OpaquePointer, label: String) throws {
        var analysis = git_merge_analysis_t(0)
        var pref = git_merge_preference_t(0)
        var heads: [OpaquePointer?] = [annotated]
        try heads.withUnsafeMutableBufferPointer { buf in
            try check(git_merge_analysis(&analysis, &pref, repo, buf.baseAddress, 1), "merge analysis")
        }
        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            ctx.stdout.line("Already up to date."); return
        }
        guard analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0
            || analysis.rawValue & GIT_MERGE_ANALYSIS_UNBORN.rawValue != 0 else {
            throw GitError(message: "branches have diverged — finish this merge on your computer (git pull --rebase), the phone only fast-forwards")
        }
        let oid = git_annotated_commit_id(annotated)!
        var target: OpaquePointer?
        try check(git_object_lookup(&target, repo, oid, GIT_OBJECT_COMMIT), "merge")
        defer { git_object_free(target) }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try check(git_checkout_tree(repo, target, &opts), "merge checkout")
        if git_repository_head_unborn(repo) == 1 {
            var head: OpaquePointer?
            try check(git_reference_create(&head, repo, "refs/heads/main", oid, 1, "pocode: ff"), "merge")
            git_reference_free(head)
            try check(git_repository_set_head(repo, "refs/heads/main"), "merge")
        } else {
            var head: OpaquePointer?
            try check(git_repository_head(&head, repo), "merge")
            defer { git_reference_free(head) }
            var moved: OpaquePointer?
            try check(git_reference_set_target(&moved, head, oid, "pocode: ff \(label)"), "merge")
            git_reference_free(moved)
        }
        ctx.stdout.line("Fast-forwarded to \(label).")
    }

    private static func cmdRemote(_ ctx: ShellContext, _ args: [String]) throws {
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        if args.first == "add", args.count >= 3 {
            guard args[2].hasPrefix("https://github.com/") else {
                throw GitError(message: "only https://github.com/ remotes are allowed")
            }
            var remote: OpaquePointer?
            try check(git_remote_create(&remote, repo, args[1], args[2]), "remote add")
            git_remote_free(remote)
            return
        }
        var names = git_strarray()
        try check(git_remote_list(&names, repo), "remote")
        defer { git_strarray_dispose(&names) }
        for i in 0..<names.count {
            guard let n = names.strings[i] else { continue }
            var remote: OpaquePointer?
            if git_remote_lookup(&remote, repo, n) == 0, let remote {
                let url = git_remote_url(remote).map { String(cString: $0) } ?? ""
                ctx.stdout.line("\(String(cString: n))\t\(url)")
                git_remote_free(remote)
            }
        }
    }

    // MARK: network commands

    /// libgit2 credential callback — C fn pointer, so the token rides a static.
    private static let credentialCallback: git_credential_acquire_cb = { out, _, _, _, _ in
        guard let token = GitHubAccount.token else { return Int32(GIT_EUSER.rawValue) }
        return git_credential_userpass_plaintext_new(out, "x-access-token", token)
    }

    private static func requireLogin(_ ctx: ShellContext) async throws {
        guard !GitHubAccount.isSignedIn else { return }
        ctx.stdout.line("GitHub sign-in required.")
        try await cmdLogin(ctx)
    }

    private static func cmdLogin(_ ctx: ShellContext) async throws {
        if let name = GitHubAccount.login, GitHubAccount.isSignedIn {
            ctx.stdout.line("Already signed in as \(name). (`git logout` to switch)")
            return
        }
        if !GitHubAccount.oauthClientID.isEmpty {
            let code = try await GitHubAccount.startDeviceFlow()
            ctx.stdout.line("Enter code \u{1B}[1m\(code.userCode)\u{1B}[0m at \(code.verificationURL)")
            CodexHostBridge.openURL(URL(string: code.verificationURL)!)
            let name = try await GitHubAccount.pollDeviceFlow(code, isCancelled: { false })
            CodexHostBridge.dismissBrowser()
            ctx.stdout.line("\u{1B}[32m✓ Signed in as \(name).\u{1B}[0m")
            return
        }
        guard let input = ctx.terminalInput else { throw GitError(message: "interactive terminal required") }
        ctx.stdout.line("Paste a GitHub Personal Access Token (repo scope) — github.com/settings/tokens")
        ctx.stdout.write("token› ")
        guard let pat = input.readLine()?.trimmingCharacters(in: .whitespaces), !pat.isEmpty else {
            throw GitError(message: "no token entered")
        }
        let name = try await GitHubAccount.signInWithPAT(pat)
        ctx.stdout.line("\u{1B}[32m✓ Signed in as \(name) (token stored in Keychain).\u{1B}[0m")
    }

    private static func cmdPush(_ ctx: ShellContext, _ args: [String]) async throws {
        try await requireLogin(ctx)
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        var remote: OpaquePointer?
        if git_remote_lookup(&remote, repo, "origin") != 0 {
            guard args.contains("--create") else {
                throw GitError(message: "no 'origin' remote — `git remote add origin <url>` or `git push --create`")
            }
            let name = ctx.state.cwd.lastPathComponent
            let isPrivate = args.contains("--private")
            ctx.stdout.line("Creating GitHub repo \(name)\(isPrivate ? " (private)" : "")…")
            let url = try await GitHubAccount.createRepo(name: name, isPrivate: isPrivate)
            try check(git_remote_create(&remote, repo, "origin", url), "remote add")
            ctx.stdout.line("origin → \(url)")
        }
        defer { git_remote_free(remote) }
        let branch = currentBranch(repo) ?? "main"
        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        callbacks.credentials = credentialCallback
        var opts = git_push_options()
        git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION))
        opts.callbacks = callbacks
        var specs = ["refs/heads/\(branch):refs/heads/\(branch)"]
        try withPathspec(&specs) { arr in
            var sa = arr
            try check(git_remote_push(remote, &sa, &opts), "push")
        }
        ctx.stdout.line("\u{1B}[32mPushed \(branch) → origin.\u{1B}[0m")
    }

    private static func cmdPull(_ ctx: ShellContext) async throws {
        try await requireLogin(ctx)
        let repo = try openRepo(ctx); defer { git_repository_free(repo) }
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, repo, "origin"), "pull: no 'origin' remote")
        defer { git_remote_free(remote) }
        var callbacks = git_remote_callbacks()
        git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        callbacks.credentials = credentialCallback
        var fo = git_fetch_options()
        git_fetch_options_init(&fo, UInt32(GIT_FETCH_OPTIONS_VERSION))
        fo.callbacks = callbacks
        try check(git_remote_fetch(remote, nil, &fo, "pull"), "fetch")
        let branch = currentBranch(repo) ?? "main"
        var oid = git_oid()
        try check(git_reference_name_to_id(&oid, repo, "refs/remotes/origin/\(branch)"), "pull: origin/\(branch) not found")
        var annotated: OpaquePointer?
        try check(git_annotated_commit_lookup(&annotated, repo, &oid), "pull")
        defer { git_annotated_commit_free(annotated) }
        try fastForward(ctx, repo: repo, annotated: annotated!, label: "origin/\(branch)")
    }

    private static func cmdClone(_ ctx: ShellContext, _ args: [String]) async throws {
        guard let url = args.first, url.hasPrefix("https://github.com/") else {
            throw GitError(message: "usage: git clone https://github.com/user/repo [dir]")
        }
        let defaultName = url.split(separator: "/").last.map {
            String($0).replacingOccurrences(of: ".git", with: "")
        } ?? "repo"
        let dest = ctx.state.cwd.appendingPathComponent(args.count > 1 ? args[1] : defaultName)
        guard dest.path.hasPrefix(ctx.state.sandbox.root.path) else {
            throw GitError(message: "destination must stay inside the workspace")
        }
        var opts = git_clone_options()
        git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION))
        opts.fetch_opts.callbacks.credentials = credentialCallback
        ctx.stdout.line("Cloning into '\(dest.lastPathComponent)'…")
        var repo: OpaquePointer?
        try check(git_clone(&repo, url, dest.path, &opts), "clone")
        git_repository_free(repo)
        ctx.stdout.line("\u{1B}[32mDone.\u{1B}[0m")
    }
}
