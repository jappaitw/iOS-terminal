import Foundation

/// Embedded CPython (Phase 1b). Until the interpreter is linked, `python` reports that
/// the runtime isn't included in this build.
enum PythonRuntime {
    static let shellCommand: (@Sendable (ShellContext) async -> Int32)? = nil
}
