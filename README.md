# KDE Screen Remote

A custom [Unified Remote](https://www.unifiedremote.com/) remote for KDE Plasma
on Wayland, with live preview of the active monitor, cursor-following zoom and
a multitouch trackpad.

## Features

- Active-monitor preview at 10 FPS.
- 2× and 3× zoom following the real KWin cursor across multiple monitors.
- Relative mouse movement, left click, double click, and drag and drop.
- Two-finger right click and scrolling.
- Stream starts when the mobile remote opens and stops when it closes.

## Requirements

- KDE Plasma running on Wayland and Unified Remote Server for Linux.
- Python 3, `dbus-python`, Pillow and PyGObject / GLib.
- KWin's `org.kde.KWin.ScreenShot2` D-Bus interface and scripting API.

`kscreen-doctor` is no longer required. Cursor coordinates and logical output
geometry now come from the same KWin script, so the monitor offset remains
correct even when the server starts without graphical environment variables.

## Automatic installation or update

```bash
curl -fsSL https://raw.githubusercontent.com/laurorual/unified-remote-kde-screen/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

The installer asks for your Unified Remote `remotes/Custom` directory, checks
dependencies, downloads the stable ZIP from **Releases > Latest**, installs the
remote and configures the authorized Python screenshot helper. An existing
remote is copied into a timestamped backup directory before replacement.

The ZIP always has the same name:

[Download KDE-Screen-Remote.zip](https://github.com/laurorual/unified-remote-kde-screen/releases/latest/download/KDE-Screen-Remote.zip)

Dependency installation is supported on Fedora, rpm-ostree systems such as
Bazzite, Debian/Ubuntu and Arch. Immutable systems may need a reboot if newly
installed dependencies cannot be applied live. On other distributions, install
the requirements manually and run the installer again.

## Manual installation

1. Install the requirements listed above.
2. Download `KDE-Screen-Remote.zip` using the Latest link above.
3. Back up any existing `remotes/Custom/KDE Screen Remote` directory, then
   extract the ZIP's **KDE Screen Remote** folder into `remotes/Custom/`.

```text
remotes/Custom/KDE Screen Remote/
├── meta.prop
├── layout.xml
├── remote.lua
├── kde_screen_remote_streamer.py
├── cursor_tracker.js
├── icon.png
├── icon_hires.png
├── CHANGELOG.md
├── README.md
└── LICENSE
```

Alternatively, the seven remote source files are directly in the repository
root and can be copied into that remote directory together.

4. Back up an existing `/usr/local/libexec/kde-screen-remote-python` helper and
   `/usr/local/share/applications/org.kdescreenremote.helper.desktop` entry
   before replacing them. Install an authorized copy of Python:

```bash
sudo install -Dm755 "$(readlink -f "$(command -v python3)")" \
  /usr/local/libexec/kde-screen-remote-python
```

5. Authorize the helper for KWin's restricted screenshot interface:

```bash
sudo tee /usr/local/share/applications/org.kdescreenremote.helper.desktop >/dev/null <<'EOF'
[Desktop Entry]
Name=KDE Screen Remote Helper
Comment=KWin ScreenShot2 helper for Unified Remote
Exec=/usr/local/libexec/kde-screen-remote-python
Type=Application
NoDisplay=true
Terminal=false
StartupNotify=false
X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2
EOF
```

6. Restart Unified Remote Server and reopen **KDE Screen Remote** on the phone.
   For the `unified-remote.service` user service:

```bash
systemctl --user restart unified-remote.service
```

## Symbols and accented keyboard input

The phone's keyboard uses Unified Remote's Core input remotes. Apply the separate
[Unified Remote Linux Wayland Fix](https://github.com/laurorual/Unified-Remote-Linux-Wayland-Fix)
for symbols, accents and Unicode text on KDE Wayland. Installing only this
screen remote does not replace the Core keyboard files.

## Changelog

### v1.0.1 — 2026-11-05

- Fixed zoom stuck against the right edge of the second monitor.
- Obtain output geometry directly from KWin and remove `kscreen-doctor`.
- Publish source files at the repository root and use a versionless ZIP from
  Releases > Latest.
- Back up an existing remote before installation and include the changelog in
  the release archive.
- Document the separate symbols/accented keyboard fix.

See [CHANGELOG.md](CHANGELOG.md) for details and the initial release history.

## Building a release

```bash
python3 scripts/build_release.py
```

This creates `dist/KDE-Screen-Remote.zip` with the same layout used by the
installer. The release workflow builds the archive and publishes v1.0.1.

Run zoom regression checks with `python3 -m unittest discover -s tests -v`
after installing the runtime Python dependencies.

## Tested environment

Bazzite Linux, KDE Plasma Wayland, NVIDIA GPU, portable Unified Remote Server
for Linux and the Android client. Other KDE Wayland distributions have not yet
been tested. KWin-specific APIs are required; GNOME, X11 and wlroots compositors
need a different implementation.

## Credits

Developed with assistance from **ChatGPT by OpenAI**, including architecture,
debugging, Lua/Python implementation, testing and documentation.
