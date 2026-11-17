#define PY_SSIZE_T_CLEAN
#include "Python.h"
#include "pocket_python.h"
#include <signal.h>
#include <stdlib.h>
#include <string.h>

static int initialized = 0;

static int append_path(PyConfig *config, const char *path) {
    wchar_t *w = Py_DecodeLocale(path, NULL);
    if (!w) return -1;
    PyStatus s = PyWideStringList_Append(&config->module_search_paths, w);
    PyMem_RawFree(w);
    return PyStatus_Exception(s) ? -1 : 0;
}

static int fail(PyStatus status, char **error) {
    const char *msg = status.err_msg ? status.err_msg : "Python initialisation failed";
    if (error) *error = strdup(msg);
    return -1;
}

int pp_initialize(const char *home, const char *stdlib_dir, const char *dynload_dir, const char *app_dir, char **error) {
    if (initialized) return 0;

    // Settings required for iOS by the official embedding guide.
    PyPreConfig pre;
    PyPreConfig_InitPythonConfig(&pre);
    pre.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&pre);
    if (PyStatus_Exception(status)) return fail(status, error);

    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;
    config.parse_argv = 0;
    config.user_site_directory = 0;

    status = PyConfig_SetBytesString(&config, &config.home, home);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return fail(status, error); }
    config.module_search_paths_set = 1;
    if (append_path(&config, stdlib_dir) || append_path(&config, dynload_dir) || append_path(&config, app_dir)) {
        PyConfig_Clear(&config);
        if (error) *error = strdup("could not set the module search path");
        return -1;
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return fail(status, error);

    // Release the GIL; every run re-acquires it on its own thread.
    PyEval_SaveThread();
    initialized = 1;
    return 0;
}

int pp_run(const char *argv_json, const char *cwd, const char *workspace_root, int out_fd, int err_fd, int in_fd) {
    if (!initialized) return 127;
    PyGILState_STATE gil = PyGILState_Ensure();
    int rc = 1;
    PyObject *mod = PyImport_ImportModule("pocketcode_runner");
    if (!mod) {
        PyErr_Print();
    } else {
        PyObject *res = PyObject_CallMethod(mod, "run", "sssiii", argv_json, cwd, workspace_root, out_fd, err_fd, in_fd);
        if (!res) {
            PyErr_Print();
        } else {
            rc = (int)PyLong_AsLong(res);
            if (PyErr_Occurred()) { PyErr_Clear(); rc = 1; }
            Py_DECREF(res);
        }
        Py_DECREF(mod);
    }
    PyGILState_Release(gil);
    return rc;
}

void pp_interrupt(void) {
    if (initialized) PyErr_SetInterruptEx(SIGINT);
}

const char *pp_version(void) {
    return PY_VERSION;
}
