"""Capture installer checks using temporary remotes and helper paths; no sudo/UI."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class CaptureInstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.custom = self.base / 'server/remotes/Custom'
        self.custom.mkdir(parents=True)
        (self.custom.parent / 'Unified/Core').mkdir(parents=True)
        self.system = self.base / 'helpers'
        self.system.mkdir()
        self.helper = self.system / 'kde-screen-remote-python'
        self.desktop = self.system / 'org.kdescreenremote.helper.desktop'
        self.legacy = self.system / 'bazzite-screen-python'
        self.legacy_desktop = self.system / 'org.bazzitescreen.helper.desktop'
        self.python = Path(shutil.which('python3')).resolve()
        self.archive = self.base / 'release.zip'
        required = ('meta.prop', 'layout.xml', 'remote.lua', 'kde_screen_remote_streamer.py',
                    'cursor_tracker.js', 'icon.png', 'icon_hires.png', 'CHANGELOG.md')
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for name in required:
                archive.write(ROOT / name, 'KDE Screen Remote/' + name)
        self.marker = self.base / 'calls'
        self.env = dict(os.environ, TEST_INSTALLER=str(ROOT / 'install.sh'),
                        TEST_CUSTOM=str(self.custom), TEST_HELPERS=str(self.system),
                        TEST_ARCHIVE=str(self.archive), TEST_MARKER=str(self.marker))

    def run_shell(self, body, success=True):
        prefix = '''source "$TEST_INSTALLER"
HELPER_BIN="$TEST_HELPERS/kde-screen-remote-python"
DESKTOP_FILE="$TEST_HELPERS/org.kdescreenremote.helper.desktop"
BAZZITE_HELPER_BIN="$TEST_HELPERS/bazzite-screen-python"
BAZZITE_DESKTOP_FILE="$TEST_HELPERS/org.bazzitescreen.helper.desktop"
configure_sudo() { SUDO=""; printf 'sudo-setup\\n' >> "$TEST_MARKER"; }
install_dependencies() { printf 'dependency-setup\\n' >> "$TEST_MARKER"; }
download_release_zip() { printf 'download\\n' >> "$TEST_MARKER"; printf '%s\\n' "$TEST_ARCHIVE"; }
update-desktop-database() { :; }
restart_unified_remote_if_possible() { printf 'restart\\n' >> "$TEST_MARKER"; }
'''
        result = subprocess.run(['bash', '-c', prefix + body], env=self.env,
                                capture_output=True, text=True, timeout=15)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def stale_helper(self, binary, desktop):
        binary.write_text('#!/bin/sh\nexit 1\n')
        binary.chmod(0o755)
        desktop.write_text('original authorization entry\n')

    def healthy_helper(self):
        shutil.copy2(self.python, self.helper)
        self.desktop.write_text('[Desktop Entry]\nExec=' + str(self.helper) + '\n'
                                'X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2\n')

    def bazzite(self, interpreter):
        folder = self.custom / 'Bazzite Screen'
        folder.mkdir()
        launcher = folder / 'remote.lua'
        launcher.write_text('local python_bin = "' + str(interpreter) + '";\n-- controls\n')
        (folder / 'bazzite_screen_streamer.py').write_text('# original capture script\n')
        return launcher

    def test_check_is_read_only_and_needs_no_sudo_packages_or_download(self):
        self.healthy_helper()
        before = self.helper.read_bytes()
        self.run_shell('main --custom-dir "$TEST_CUSTOM" --check\n')
        self.assertEqual(self.helper.read_bytes(), before)
        self.assertFalse(self.marker.exists())
        self.assertFalse((self.base / 'server/backups').exists())

    def test_check_reports_stale_python_without_changing_it(self):
        self.stale_helper(self.helper, self.desktop)
        before = self.helper.read_bytes()
        result = self.run_shell('main --custom-dir "$TEST_CUSTOM" --check\n', success=False)
        self.assertIn('needs installation or refresh', result.stderr)
        self.assertEqual(self.helper.read_bytes(), before)
        self.assertFalse(self.marker.exists())

    def test_check_requires_the_authorization_entry(self):
        self.healthy_helper()
        self.desktop.unlink()
        self.run_shell('main --custom-dir "$TEST_CUSTOM" --check\n', success=False)
        self.assertFalse(self.desktop.exists())
        self.assertFalse(self.marker.exists())

    def test_refreshes_both_helpers_with_backups_and_preserves_bazzite_controls(self):
        self.stale_helper(self.helper, self.desktop)
        self.stale_helper(self.legacy, self.legacy_desktop)
        launcher = self.bazzite(self.legacy)
        before = launcher.read_bytes()
        self.run_shell('main --custom-dir "$TEST_CUSTOM" --no-restart\n')
        self.assertEqual(self.helper.read_bytes(), self.python.read_bytes())
        self.assertEqual(self.legacy.read_bytes(), self.python.read_bytes())
        self.assertEqual(launcher.read_bytes(), before)
        backup = next((self.base / 'server/backups').iterdir())
        for name in (self.helper.name, self.legacy.name):
            self.assertEqual((backup / name).read_text(), '#!/bin/sh\nexit 1\n')
        for name in (self.desktop.name, self.legacy_desktop.name):
            self.assertEqual((backup / name).read_text(), 'original authorization entry\n')
        self.assertNotIn('restart', self.marker.read_text())
        self.assertTrue((self.custom / 'KDE Screen Remote/CHANGELOG.md').is_file())

    def test_bad_staged_copy_preserves_previous_helper_and_authorization(self):
        self.stale_helper(self.helper, self.desktop)
        before, entry = self.helper.read_bytes(), self.desktop.read_bytes()
        self.run_shell('''BACKUP_DIR="$TEST_HELPERS/backup"
mkdir "$BACKUP_DIR"
capture_python_ok() { [[ $1 != */.screen-python-* ]]; }
install_authorized_python_helper
''', success=False)
        self.assertEqual(self.helper.read_bytes(), before)
        self.assertEqual(self.desktop.read_bytes(), entry)
        self.assertFalse(list(self.system.glob('.screen-python-*')))

    def test_preserves_unrecognized_bazzite_interpreter(self):
        custom = self.system / 'custom-python'
        custom.write_text('custom helper: do not replace')
        launcher = self.bazzite(custom)
        before = launcher.read_bytes()
        self.run_shell('main --custom-dir "$TEST_CUSTOM" --no-restart\n')
        self.assertEqual(launcher.read_bytes(), before)
        self.assertEqual(custom.read_text(), 'custom helper: do not replace')
        self.assertFalse(self.legacy.exists())

    def test_rejects_server_root_before_setting_up_dependencies(self):
        self.run_shell('main --custom-dir "${TEST_CUSTOM%/remotes/Custom}"\n', success=False)
        self.assertFalse(self.marker.exists())
        self.assertFalse(self.helper.exists())

    def test_restarts_after_successful_validation(self):
        self.run_shell('main --custom-dir "$TEST_CUSTOM"\n')
        self.assertIn('restart', self.marker.read_text())


if __name__ == '__main__':
    unittest.main()
