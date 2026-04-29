"""KiCad legacy ActionPlugin shim — registers EDA Sync under
Tools → External Plugins. The actual sync runs out-of-process via the
Go binary `eda-kicad-sync(.exe)` that uses KiCad 10's IPC API.

Install: symlink (or copy) THIS directory to
`<kicad-config>/scripting/plugins/eda-sync/`. The Go binary must live
one level up — i.e. directly inside `tools/kicad-sync-go/`. That's the
case if you symlink `tools/kicad-sync-go/kicad_plugin` into KiCad's
plugin folder.
"""

import os
import subprocess
import sys

import pcbnew  # type: ignore[import-not-found]


_HERE = os.path.dirname(os.path.abspath(__file__))
_PLUGIN_ROOT = os.path.normpath(os.path.join(_HERE, ".."))


def _binary_path() -> str:
    name = "eda-kicad-sync.exe" if os.name == "nt" else "eda-kicad-sync"
    return os.path.join(_PLUGIN_ROOT, name)


def _show_error(msg: str) -> None:
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
        if board:
            board_path = board.GetFileName()
            if board_path:
                cmd += ["--board", board_path]

        # Popen (not run) so KiCad's UI stays responsive while OAuth /
        # network I/O happens. The spawned process owns its own setup
        # web page, browser auth, and result toast.
        subprocess.Popen(cmd, cwd=_PLUGIN_ROOT)


EdaSyncActionPlugin().register()
