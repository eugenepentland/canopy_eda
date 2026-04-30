"""KiCad legacy ActionPlugin shim — registers EDA Sync under
Tools → External Plugins. The actual sync runs out-of-process via the
Go binary `eda-kicad-sync(.exe)` that uses KiCad 10's IPC API.

Install: symlink (or copy) THIS directory to
`<kicad-config>/scripting/plugins/eda-sync/`. The Go binary must live
one level up — i.e. directly inside `tools/kicad-sync-go/`. That's the
case if you symlink `tools/kicad-sync-go/kicad_plugin` into KiCad's
plugin folder.
"""

import datetime
import os
import subprocess
import sys
import tempfile

import pcbnew  # type: ignore[import-not-found]


# `realpath` (not `abspath`) so we follow the symlink that the install
# step creates. Without it, __file__ resolves to KiCad's plugin folder
# and `..` lands in scripting/plugins/ rather than next to the Go binary.
_HERE = os.path.dirname(os.path.realpath(__file__))
_PLUGIN_ROOT = os.path.normpath(os.path.join(_HERE, ".."))
_LOG_PATH = os.path.join(tempfile.gettempdir(), "eda-kicad-sync.log")


def _binary_path() -> str:
    name = "eda-kicad-sync.exe" if os.name == "nt" else "eda-kicad-sync"
    return os.path.join(_PLUGIN_ROOT, name)


def _default_kicad_socket() -> str:
    """Best-effort guess for the KiCad IPC socket path when KiCad
    didn't propagate KICAD_API_SOCKET (which it doesn't for legacy
    ActionPlugin subprocesses). Override by setting the env var
    yourself before launching KiCad."""
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser(r"~\AppData\Local")
        return os.path.join(base, "Temp", "kicad", "api.sock")
    if sys.platform == "darwin":
        return os.path.join(tempfile.gettempdir(), "kicad", "api.sock")
    # Linux + everything else.
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(runtime_dir, "kicad", "api.sock")


def _resolve_kicad_socket() -> str:
    if os.environ.get("KICAD_API_SOCKET"):
        return os.environ["KICAD_API_SOCKET"]
    return _default_kicad_socket()


def _log(line: str) -> None:
    """Append a timestamped line to %TEMP%\\eda-kicad-sync.log so the
    user can see what's happening when notifications swallow errors."""
    try:
        ts = datetime.datetime.now().isoformat(timespec="seconds")
        with open(_LOG_PATH, "a", encoding="utf-8") as f:
            f.write("[" + ts + "] " + line + "\n")
    except Exception:
        pass


def _show_error(msg: str) -> None:
    _log("ERROR: " + msg.replace("\n", " | "))
    try:
        import wx  # type: ignore[import-not-found]

        wx.MessageBox(msg, "EDA Sync", wx.OK | wx.ICON_ERROR)
    except Exception:
        sys.stderr.write("EDA Sync: " + msg + "\n")


class EdaSyncActionPlugin(pcbnew.ActionPlugin):
    def defaults(self) -> None:
        self.name = "EDA Sync"
        self.category = "Sync"
        self.description = "Pull the latest design from the EDA server and apply it to this PCB."
        self.show_toolbar_button = True
        icon = os.path.join(_HERE, "icon.png")
        if os.path.exists(icon):
            self.icon_file_name = icon

    def Run(self) -> None:  # noqa: N802 — KiCad-required name
        binary = _binary_path()
        if not os.path.exists(binary):
            _show_error(
                "Binary not found: " + binary + "\n\n"
                "Build it first:\n"
                "  cd " + _PLUGIN_ROOT + "\n"
                "  go build -o eda-kicad-sync.exe .\\cmd\\eda-kicad-sync"
            )
            return

        cmd = [binary]
        board = pcbnew.GetBoard()
        board_path = ""
        if board:
            board_path = board.GetFileName() or ""
            if board_path:
                cmd += ["--board", board_path]

        # Inject the IPC socket path. KiCad doesn't propagate
        # KICAD_API_SOCKET when launching legacy ActionPlugins (only
        # for the new plugin.json mechanism), so we fall back to the
        # platform-default location KiCad uses when not overridden.
        env = os.environ.copy()
        sock = _resolve_kicad_socket()
        env["KICAD_API_SOCKET"] = sock

        _log(
            "spawn: cmd=" + repr(cmd)
            + " board=" + repr(board_path)
            + " socket=" + repr(sock)
            + " socket_exists=" + str(os.path.exists(sock.replace("ipc://", "")))
        )

        # Open log + error streams to a file so we can read them after
        # the process finishes — Popen output normally vanishes into
        # KiCad's pipes.
        try:
            log_fd = open(_LOG_PATH, "a", encoding="utf-8")
            log_fd.write("---- spawn output ----\n")
            log_fd.flush()
        except Exception:
            log_fd = subprocess.DEVNULL

        # Popen (not run) so KiCad's UI stays responsive while OAuth /
        # network I/O happens. The spawned process owns its own setup
        # web page, browser auth, and result toast.
        subprocess.Popen(cmd, cwd=_PLUGIN_ROOT, env=env, stdout=log_fd, stderr=log_fd)


EdaSyncActionPlugin().register()
