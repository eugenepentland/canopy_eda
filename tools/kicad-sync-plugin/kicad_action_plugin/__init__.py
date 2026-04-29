"""KiCad action-plugin shim for EDA Sync.

Exposes the IPC sync script as a toolbar button in the PCB editor. The
heavy lifting still happens out-of-process (via kipy + the KiCad 10 IPC
API); this shim only registers the menu item and spawns the real script
as a subprocess so KiCad's UI thread stays responsive.

Install: symlink or copy this directory into KiCad's user plugin folder:
    ~/.local/share/kicad/10.0/scripting/plugins/   (Linux/KiCad 10)
    ~/Library/Preferences/kicad/10.0/scripting/plugins/   (macOS)
    %APPDATA%\\kicad\\10.0\\scripting\\plugins\\           (Windows)

The `eda-kicad-sync` directory must be reachable from this folder via
`../` — the shim spawns `python -m plugins.eda_sync_action` from there.
"""

import os
import shutil
import subprocess

import pcbnew  # type: ignore[import-not-found]


_HERE = os.path.dirname(os.path.abspath(__file__))
_PLUGIN_ROOT = os.path.normpath(os.path.join(_HERE, ".."))


def _system_python() -> str:
    """Pick a Python interpreter that has `kipy` installed.

    KiCad's bundled Python normally doesn't ship kipy, so we shell out to
    the user's system Python. Override with EDA_SYNC_PYTHON if you keep
    kipy in a venv.
    """
    return os.environ.get("EDA_SYNC_PYTHON") or shutil.which("python3") or "python3"


class EdaSyncActionPlugin(pcbnew.ActionPlugin):
    def defaults(self) -> None:
        self.name = "EDA Sync"
        self.category = "Sync"
        self.description = "Pull the latest design from the EDA server and apply it to this PCB."
        self.show_toolbar_button = True
        icon = os.path.join(_HERE, "icon.png")
        if os.path.exists(icon):
            self.icon_file_name = icon

    def Run(self) -> None:  # noqa: N802 — KiCad-required method name
        board = pcbnew.GetBoard()
        board_path = board.GetFileName() if board else ""
        cmd = [
            _system_python(),
            "-m", "plugins.eda_sync_action",
            "--board", board_path,
        ]
        # Popen (not run) so KiCad's UI doesn't block while OAuth /
        # network round-trips happen. The spawned process owns its own
        # Tk dialog + result toast.
        subprocess.Popen(cmd, cwd=_PLUGIN_ROOT)


EdaSyncActionPlugin().register()
