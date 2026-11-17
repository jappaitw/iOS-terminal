import Foundation
import os

private let pyLog = Logger(subsystem: "com.jlmxstudio.pocketcode", category: "python")

/// The embedded CPython interpreter (official python.org iOS XCframework).
///
/// One interpreter per app process: runs are serialised. Each run executes on its own
/// thread; stdout/stderr come back through pipes and are streamed to the terminal, and
/// stdin is fed from the terminal's line input (for `input()` and the REPL).
/// The one OS thread that owns the interpreter. CPython only handles signals — including
/// the simulated SIGINT behind Ctrl-C (`PyErr_SetInterruptEx`) — on the thread that
/// initialised it, so initialisation and every run happen here, one job at a time.
private final class PythonThread: @unchecked Sendable {
    static let shared = PythonThread()
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []

    private init() {
        let t = Thread { [unowned self] in self.loop() }
        t.name = "PocketCode.Python"
        t.stackSize = 16 << 20 // deep recursion in user code
        t.qualityOfService = .userInitiated
        t.start()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }

    func submit(_ job: @escaping () -> Void) {
        condition.lock(); jobs.append(job); condition.signal(); condition.unlock()
    }

    func sync<T>(_ work: @escaping () -> T) -> T {
        var result: T?
        let done = DispatchSemaphore(value: 0)
        submit { result = work(); done.signal() }
        done.wait()
        return result!
    }

    func async<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in submit { cont.resume(returning: work()) } }
    }
}

enum PythonRuntime {
    static let shellCommand: (@Sendable (ShellContext) async -> Int32)? = { ctx in await run(ctx) }

    private static let lock = NSLock()
    private static var initError: String?
    private static var initialized = false
    /// Only one program at a time can own the interpreter's sys.stdin/stdout.
    private static let busy = NSLock()

    static var version: String { String(cString: pp_version()) }

    /// Starts the interpreter on first use. Returns an error message if it can't.
    static func initialize() -> String? {
        lock.lock(); defer { lock.unlock() }
        if initialized { return nil }
        if let initError { return initError }
        guard let res = Bundle.main.resourcePath else { initError = "no bundle"; return initError }
        let home = res + "/python"
        let lib = home + "/lib/python" + String(version.split(separator: ".").prefix(2).joined(separator: "."))
        guard FileManager.default.fileExists(atPath: lib) else {
            initError = "the Python standard library is missing from the app bundle"
            return initError
        }
        let t0 = Date()
        let appDir = res + "/PythonApp"
        let (rc, message): (Int32, String?) = PythonThread.shared.sync {
            var err: UnsafeMutablePointer<CChar>?
            let rc = pp_initialize(home, lib, lib + "/lib-dynload", appDir, &err)
            let message = err.map { String(cString: $0) }
            free(err)
            return (rc, message)
        }
        if rc != 0 {
            initError = message ?? "initialisation failed"
            pyLog.error("init failed: \(initError ?? "", privacy: .public)")
            return initError
        }
        initialized = true
        pyLog.info("Python \(version, privacy: .public) ready in \(String(format: "%.2f", Date().timeIntervalSince(t0)), privacy: .public)s")
        return nil
    }

    /// Runs `python …` for the local shell.
    static func run(_ ctx: ShellContext) async -> Int32 {
        if let error = initialize() { return ctx.fail(error, status: 127) }
        guard busy.try() else { return ctx.fail("another Python program is still running in a different terminal") }
        defer { busy.unlock() }

        // A script given by path must be inside the workspace (same rule as other commands).
        // sys.argv keeps the path as typed; Python resolves it against the cwd.
        var argv = ctx.args
        argv[0] = "python"
        if argv.count > 1, !argv[1].hasPrefix("-") {
            do { _ = try ctx.resolve(argv[1]) } catch { return ctx.fail(error.localizedDescription, status: 2) }
        }

        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0], inPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0, pipe(&inPipe) == 0 else { return ctx.fail("could not create pipes") }
        let stdinWriter = FileHandle(fileDescriptor: inPipe[1], closeOnDealloc: false)
        let writerLock = NSLock()
        var writerClosed = false
        func closeStdin() {
            writerLock.lock(); defer { writerLock.unlock() }
            if !writerClosed { writerClosed = true; close(inPipe[1]) }
        }
        func writeStdin(_ data: Data) {
            writerLock.lock(); defer { writerLock.unlock() }
            if !writerClosed { try? stdinWriter.write(contentsOf: data) }
        }

        // Ctrl-C → KeyboardInterrupt. A newline also wakes a blocked input()/REPL read so
        // the pending interrupt is noticed straight away.
        ctx.interruptHandler = {
            pp_interrupt()
            writeStdin(Data("\n".utf8))
        }

        // Pump output pipes to the terminal (or the next pipeline stage).
        let pumps = DispatchGroup()
        for (fd, sink) in [(outPipe[0], ctx.stdout), (errPipe[0], ctx.stderr)] {
            pumps.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let n = read(fd, &buf, buf.count)
                    if n <= 0 { break }
                    sink.write(Data(buf[0..<n]))
                }
                close(fd)
                pumps.leave()
            }
        }

        // Feed stdin: piped data, or terminal lines until EOF / the program ends.
        if let data = ctx.stdinData {
            Thread.detachNewThread { writeStdin(data); closeStdin() }
        } else if let input = ctx.terminalInput {
            Thread.detachNewThread {
                while let line = input.readLine() { writeStdin(Data((line + "\n").utf8)) }
                closeStdin()
            }
        } else {
            closeStdin()
        }

        let argvJSON = (try? String(data: JSONEncoder().encode(argv), encoding: .utf8)) ?? "[\"python\"]"
        let cwd = ctx.state.cwd.path, root = ctx.state.sandbox.root.path
        let outW = outPipe[1], errW = errPipe[1], inR = inPipe[0]
        let status: Int32 = await PythonThread.shared.async {
            let rc = pp_run(argvJSON, cwd, root, outW, errW, inR)
            close(outW); close(errW)
            return rc
        }
        closeStdin()
        close(inPipe[0])
        await withCheckedContinuation { cont in pumps.notify(queue: .global()) { cont.resume() } }
        ctx.interruptHandler = nil
        return status
    }
}
