"""PocketCode's driver for the embedded CPython interpreter.

Called from Swift (via pocket_python.c) once per `python …` command typed in the local
terminal. Implements the parts of the `python` command line that make sense on iOS:

    python file.py [args]   python -c CODE [args]   python -m MODULE [args]
    python -               python (REPL)            python -V / --version

and keeps every run inside the workspace folder with an audit hook (see _guard). The hook
is defence in depth for user- and AI-written code, not a security boundary — Python's
documentation is explicit that audit hooks can't contain hostile code. The real boundary
is the iOS app sandbox.
"""

import builtins
import code
import io
import json
import os
import runpy
import sys
import traceback

_RUNNER_FILE = os.path.realpath(__file__)
_PY_HOME = os.path.realpath(sys.prefix)
_APP_DIR = os.path.dirname(_RUNNER_FILE)
# The .app bundle (PYTHONHOME is <bundle>/python). Its contents are the app's own, read-only
# code — including Frameworks/, where iOS keeps the stdlib's extension modules — so reading
# it is allowed; everything else outside the workspace is not.
_APP_BUNDLE = os.path.dirname(_PY_HOME)

# Workspace root while a program runs; None between runs (the hook can't be removed).
_active_root = None
_hook_installed = False

_DENIED_EVENTS = {
    "ctypes.dlopen", "ctypes.dlsym", "ctypes.dlsym/handle", "ctypes.cdata", "ctypes.call_function",
    "os.system", "os.exec", "os.posix_spawn", "os.spawn", "os.fork", "os.forkpty", "os.kill",
    "os.killpg", "subprocess.Popen", "pty.spawn", "socket.bind", "sys._debugmallocstats",
    "os.add_dll_directory",
}
# Filesystem events whose first argument is a path that must be inside the workspace.
_PATH_WRITE_EVENTS = {
    "os.remove", "os.rename", "os.rmdir", "os.mkdir", "os.chmod", "os.chown", "os.truncate",
    "os.link", "os.symlink", "os.utime", "shutil.rmtree", "shutil.move", "shutil.copyfile",
    "shutil.copytree", "os.removexattr", "os.setxattr",
}
_PATH_READ_EVENTS = {"os.listdir", "os.scandir", "os.chdir", "glob.glob", "os.walk"}


def _inside(path, root):
    return path == root or path.startswith(root.rstrip("/") + "/")


def _resolve(path):
    if isinstance(path, int):
        return None
    try:
        p = os.fsdecode(path)
    except Exception:
        return None
    if not os.path.isabs(p):
        p = os.path.join(os.getcwd(), p)
    return os.path.realpath(p)


def _readable(p, root):
    return (_inside(p, root) or _inside(p, _PY_HOME) or _inside(p, _APP_DIR)
            or (_APP_BUNDLE.endswith(".app") and _inside(p, _APP_BUNDLE))
            or p in ("/dev/null", "/dev/urandom", "/dev/random"))


def _guard(event, args):
    root = _active_root
    if root is None:
        return
    if event in _DENIED_EVENTS:
        raise PermissionError(f"PocketCode: '{event}' isn't available on this device")
    if event == "open":
        path, mode, flags = (list(args) + [None, None, None])[:3]
        p = _resolve(path)
        if p is None:
            return
        writing = (isinstance(mode, str) and any(c in mode for c in "wax+")) or \
                  (isinstance(flags, int) and flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND))
        if (writing and not _inside(p, root)) or (not writing and not _readable(p, root)):
            raise PermissionError(f"PocketCode: '{path}' is outside the workspace")
    elif event in _PATH_WRITE_EVENTS or event in _PATH_READ_EVENTS:
        for a in args[:2]:
            if isinstance(a, (str, bytes, os.PathLike)):
                p = _resolve(a)
                ok = _inside(p, root) if event in _PATH_WRITE_EVENTS else _readable(p, root)
                if p is not None and not ok:
                    raise PermissionError(f"PocketCode: '{a}' is outside the workspace")


def _install_guard():
    global _hook_installed
    if not _hook_installed:
        sys.addaudithook(_guard)
        _hook_installed = True


def _streams(out_fd, err_fd, in_fd):
    def writer(fd):
        return io.TextIOWrapper(io.FileIO(fd, "w", closefd=False), encoding="utf-8",
                                errors="backslashreplace", line_buffering=True, write_through=True)
    stdin = io.TextIOWrapper(io.FileIO(in_fd, "r", closefd=False), encoding="utf-8", errors="replace")
    return stdin, writer(out_fd), writer(err_fd)


def _exit_code(e):
    c = e.code
    if c is None:
        return 0
    if isinstance(c, int):
        return c
    print(c, file=sys.stderr)
    return 1


def _print_user_traceback(exc):
    """Print a traceback without PocketCode's / runpy's own frames."""
    tb = exc.__traceback__
    # runpy is usually frozen ("<frozen runpy>", no __file__), but cover a file install too.
    runpy_file = getattr(runpy, "__file__", None)
    internal = {_RUNNER_FILE} | ({os.path.realpath(runpy_file)} if runpy_file else set())

    def is_internal(filename):
        return filename.startswith("<frozen runpy") or os.path.realpath(filename) in internal

    try:
        while tb is not None and is_internal(tb.tb_frame.f_code.co_filename):
            tb = tb.tb_next
    except Exception:
        tb = exc.__traceback__  # never let trimming lose the real error
    traceback.print_exception(type(exc), exc, tb, file=sys.stderr)


def _forget_user_modules(root):
    """Drop modules imported from the workspace so edited files are re-imported next run."""
    for name, mod in list(sys.modules.items()):
        f = getattr(mod, "__file__", None)
        if f and _inside(os.path.realpath(f), root):
            sys.modules.pop(name, None)


def _repl():
    banner = (f"Python {sys.version.split()[0]} on PocketCode (iOS, runs on this device)\n"
              "Type exit() or press Ctrl-D to leave.")
    console = code.InteractiveConsole(locals={"__name__": "__console__", "__builtins__": builtins})
    console.interact(banner=banner, exitmsg="")
    return 0


def _main(argv):
    args = argv[1:]
    if not args:
        return _repl()
    first = args[0]
    if first in ("-V", "--version"):
        print(f"Python {sys.version.split()[0]}")
        return 0
    if first in ("-h", "--help"):
        print("usage: python [-c cmd | -m mod | file | -] [arg ...]\n"
              "PocketCode runs CPython on this device with the standard library only.")
        return 0
    if first == "-c":
        if len(args) < 2:
            print("Argument expected for the -c option", file=sys.stderr)
            return 2
        sys.argv = ["-c"] + args[2:]
        sys.path.insert(0, os.getcwd())
        exec(compile(args[1], "<string>", "exec"), {"__name__": "__main__", "__builtins__": builtins})
        return 0
    if first == "-m":
        if len(args) < 2:
            print("Argument expected for the -m option", file=sys.stderr)
            return 2
        sys.argv = [args[1]] + args[2:]
        sys.path.insert(0, os.getcwd())
        runpy.run_module(args[1], run_name="__main__", alter_sys=True)
        return 0
    if first == "-":
        sys.argv = ["-"] + args[1:]
        exec(compile(sys.stdin.read(), "<stdin>", "exec"), {"__name__": "__main__", "__builtins__": builtins})
        return 0
    if first.startswith("-"):
        print(f"Unknown option: {first} (supported: -c, -m, -V, -)", file=sys.stderr)
        return 2
    path = os.path.realpath(first)
    if not os.path.exists(path):
        print(f"python: can't open file '{first}': [Errno 2] No such file or directory", file=sys.stderr)
        return 2
    sys.argv = args
    sys.path.insert(0, os.path.dirname(path))
    # run_path sets sys.argv[0] to the path it's given: pass it as typed, like CPython.
    runpy.run_path(first, run_name="__main__")
    return 0


def run(argv_json, cwd, workspace_root, out_fd, err_fd, in_fd):
    """Entry point from Swift. Returns the program's exit status."""
    global _active_root
    argv = json.loads(argv_json)
    root = os.path.realpath(workspace_root)
    saved = (sys.stdin, sys.stdout, sys.stderr, list(sys.argv), list(sys.path), os.getcwd())
    sys.stdin, sys.stdout, sys.stderr = _streams(out_fd, err_fd, in_fd)
    _install_guard()
    status = 0
    try:
        os.chdir(cwd)
        _active_root = root
        status = _main(argv)
    except SystemExit as e:
        status = _exit_code(e)
    except KeyboardInterrupt:
        print("KeyboardInterrupt", file=sys.stderr)
        status = 130
    except BaseException as e:  # noqa: BLE001 — report everything the program raised
        _print_user_traceback(e)
        status = 1
    finally:
        _active_root = None
        for s in (sys.stdout, sys.stderr):
            try:
                s.flush()
            except Exception:
                pass
        sys.stdin, sys.stdout, sys.stderr, sys.argv, sys.path, prev_cwd = saved
        try:
            os.chdir(prev_cwd)
        except OSError:
            pass
        _forget_user_modules(root)
    return status
