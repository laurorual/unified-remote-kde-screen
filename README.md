# KDE Screen Remote

A custom [Unified Remote](https://www.unifiedremote.com/) remote for KDE Plasma on Wayland.

It adds a live preview of the active monitor and a touchpad-style control surface, including cursor-following zoom and multitouch gestures.

## Features

- Live preview of the active monitor at 10 FPS
- 2× and 3× zoom that follows the real KWin cursor
- Relative touchpad mouse control
- Left click and double click
- Two-finger right click
- Two-finger scrolling
- Drag and drop
- Multi-monitor support
- Automatic start when the remote is opened
- Automatic stop when leaving the remote

## Requirements

- KDE Plasma running on Wayland
- Unified Remote Server for Linux
- Python 3
- `dbus-python`
- Pillow
- PyGObject / GLib
- KScreen (`kscreen-doctor`)
- KWin with the `org.kde.KWin.ScreenShot2` D-Bus interface

## Installation

### Automatic installation

The installer checks the required dependencies, installs them on supported distributions, downloads the release ZIP, installs the remote, and configures the Python helper required for KWin's restricted `ScreenShot2` interface.

```bash
curl -fsSL https://raw.githubusercontent.com/laurorual/unified-remote-kde-screen/main/install.sh -o install.sh
chmod +x install.sh
./install.sh
```

The script will ask for the full path to your Unified Remote `remotes/Custom` directory.

The installer currently handles dependencies automatically on:

- Fedora and Fedora-based distributions
- rpm-ostree Fedora systems such as Bazzite
- Debian and Ubuntu-based distributions
- Arch Linux-based distributions

On other distributions, install the dependencies manually and run the script again.

### Manual installation

1. Install the required packages for your distribution:
   - Python 3
   - dbus-python
   - Pillow
   - PyGObject / GLib
   - KScreen / `kscreen-doctor`

2. Download `KDE-Screen-Remote-v1.0.0.zip`.

3. Extract the `KDE Screen Remote` folder into your Unified Remote:

```text
remotes/Custom/
```

The final structure should look like:

```text
remotes/Custom/KDE Screen Remote/
├── meta.prop
├── layout.xml
├── remote.lua
├── kde_screen_remote_streamer.py
├── cursor_tracker.js
├── icon.png
└── icon_hires.png
```

4. Install an authorized copy of Python:

```bash
sudo install -Dm755 "$(readlink -f "$(command -v python3)")" \
  /usr/local/libexec/kde-screen-remote-python
```

5. Authorize that helper to access KWin's restricted screenshot interface:

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

6. Restart Unified Remote Server and open **KDE Screen Remote** from the mobile app.

If you use Unified Remote as a user systemd service named `unified-remote.service`, you can restart it with:

```bash
systemctl --user restart unified-remote.service
```

## Tested Environment

So far, KDE Screen Remote has been tested on:

- Bazzite Linux
- KDE Plasma on Wayland
- NVIDIA GPU
- Unified Remote Server for Linux (portable version)
- Unified Remote Android client

The project is intended to work on other KDE Plasma Wayland distributions as well, but those environments have not yet been tested.

## Notes

KDE Screen Remote relies on KDE/KWin-specific APIs. It is not expected to work unchanged on GNOME, X11, wlroots-based compositors, or other desktop environments.

## Credits

Developed with assistance from **ChatGPT by OpenAI**, including architecture, debugging, Lua/Python implementation, testing support, and documentation.
