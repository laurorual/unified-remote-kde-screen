"""Installer regression tests using isolated writable directories.

These tests do not change a real Unified Remote installation.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"


class InstallerTests(unittest.TestCase):
    def run_shell(self, script, *, env=None):
        proc = subprocess.run(
            ["bash", "-c", 'source "$1"\n' + script, "bash", str(INSTALLER)],
            env=dict(os.environ, **(env or {})), capture_output=True, text=True,
            timeout=25,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def test_shell_help(self):
        result = subprocess.run(["bash", str(INSTALLER), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--check", result.stdout)

    def test_snapshot_rollback_restores_previous_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            custom = base / "server/remotes/Custom"
            previous = custom / "KDE Screen Remote"
            previous.mkdir(parents=True)
            (previous / "remote.lua").write_text("old remote")
            helper = base / "libexec/python"
            helper.parent.mkdir()
            helper.write_text("old python")
            desktop = base / "applications/screen.desktop"
            desktop.parent.mkdir()
            desktop.write_text("old desktop")
            backup = base / "backup"
            backup.mkdir()
            self.run_shell(
                """
SUDO=''
REMOTE_CUSTOM_DIR="$TEST_CUSTOM"
BACKUP_DIR="$TEST_BACKUP"
HELPER_BIN="$TEST_HELPER"
DESKTOP_FILE="$TEST_DESKTOP"
CAPTURE_BINS=("$HELPER_BIN")
CAPTURE_DESKTOPS=("$DESKTOP_FILE")
snapshot_installation
printf 'new remote' > "$REMOTE_CUSTOM_DIR/KDE Screen Remote/remote.lua"
printf 'new python' > "$HELPER_BIN"
printf 'new desktop' > "$DESKTOP_FILE"
rollback_installation
[[ $(cat "$REMOTE_CUSTOM_DIR/KDE Screen Remote/remote.lua") == 'old remote' ]]
[[ $(cat "$HELPER_BIN") == 'old python' ]]
[[ $(cat "$DESKTOP_FILE") == 'old desktop' ]]
""",
                env={
                    "TEST_CUSTOM": str(custom), "TEST_BACKUP": str(backup),
                    "TEST_HELPER": str(helper), "TEST_DESKTOP": str(desktop),
                },
            )

    def test_snapshot_rollback_removes_new_files(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            custom = base / "server/remotes/Custom"
            custom.mkdir(parents=True)
            helper = base / "libexec/python"
            desktop = base / "applications/screen.desktop"
            backup = base / "backup"
            backup.mkdir()
            self.run_shell(
                """
SUDO=''
REMOTE_CUSTOM_DIR="$TEST_CUSTOM"
BACKUP_DIR="$TEST_BACKUP"
HELPER_BIN="$TEST_HELPER"
DESKTOP_FILE="$TEST_DESKTOP"
CAPTURE_BINS=("$HELPER_BIN")
CAPTURE_DESKTOPS=("$DESKTOP_FILE")
snapshot_installation
mkdir -p "$REMOTE_CUSTOM_DIR/KDE Screen Remote" "${HELPER_BIN%/*}" "${DESKTOP_FILE%/*}"
touch "$REMOTE_CUSTOM_DIR/KDE Screen Remote/remote.lua" "$HELPER_BIN" "$DESKTOP_FILE"
rollback_installation
[[ ! -e "$REMOTE_CUSTOM_DIR/KDE Screen Remote" ]]
[[ ! -e "$HELPER_BIN" && ! -e "$DESKTOP_FILE" ]]
""",
                env={
                    "TEST_CUSTOM": str(custom), "TEST_BACKUP": str(backup),
                    "TEST_HELPER": str(helper), "TEST_DESKTOP": str(desktop),
                },
            )

    def test_system_python_capture_helper_survives_refresh(self):
        # The CI runner installs the same distro-managed dependencies as a KDE host.
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            helper = base / "libexec/python"
            desktop = base / "applications/screen.desktop"
            backup = base / "backup"
            backup.mkdir()
            self.run_shell(
                """
SUDO=''
HOST_PYTHON=$(readlink -f /usr/bin/python3)
BACKUP_DIR="$TEST_BACKUP"
capture_python_ok "$HOST_PYTHON"
install_authorized_python_helper "$TEST_HELPER" "$TEST_DESKTOP"
CAPTURE_BINS=("$TEST_HELPER")
CAPTURE_DESKTOPS=("$TEST_DESKTOP")
check_capture_helpers
printf 'stale executable' > "$TEST_HELPER"
if check_capture_helpers; then exit 23; fi
install_authorized_python_helper "$TEST_HELPER" "$TEST_DESKTOP"
check_capture_helpers
""",
                env={
                    "TEST_BACKUP": str(backup), "TEST_HELPER": str(helper),
                    "TEST_DESKTOP": str(desktop),
                },
            )


if __name__ == "__main__":
    unittest.main()
