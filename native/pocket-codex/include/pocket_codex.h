// Minimal C interface between Swift and the embedded Codex app-server
// (pocket-codex Rust staticlib). Swift talks to the server over the unix
// socket using the app-server JSON-RPC protocol; this header only starts it.
#ifndef POCKET_CODEX_H
#define POCKET_CODEX_H

/// Start the Codex app-server on a unix socket inside the app container.
/// `codex_home` becomes CODEX_HOME (config + credentials, kept in the sandbox).
/// Returns 0 on success (server thread running), non-zero on failure with
/// *error set (free with pc_free). One server per process.
int pc_start(const char *socket_path, const char *codex_home, char **error);

/// Free a string returned through pc_start's error out-parameter.
void pc_free(char *s);

/// FFI contract version (bump on breaking changes).
int pc_abi_version(void);

#endif
