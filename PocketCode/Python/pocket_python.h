// Minimal C interface between Swift and the embedded CPython interpreter.
// Python.h is only included by pocket_python.c, so Swift never sees the full C API.
#ifndef POCKET_PYTHON_H
#define POCKET_PYTHON_H

/// Initialise the interpreter once. Returns 0 on success; on failure returns -1 and sets
/// *error (malloc'ed, caller frees).
int pp_initialize(const char *home, const char *stdlib_dir, const char *dynload_dir, const char *app_dir, char **error);

/// Run `pocketcode_runner.run(...)` with the given argv (JSON array), working directory,
/// workspace root and file descriptors. Blocks until the program finishes; returns its
/// exit status. Safe to call from any thread (takes the GIL).
int pp_run(const char *argv_json, const char *cwd, const char *workspace_root, int out_fd, int err_fd, int in_fd);

/// Ctrl-C: raise KeyboardInterrupt in the running program at the next bytecode boundary.
void pp_interrupt(void);

/// The interpreter version, e.g. "3.15.2".
const char *pp_version(void);

#endif
