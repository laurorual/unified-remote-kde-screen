# KDE Screen Remote

A Unified Remote remote for **KDE Plasma on Wayland**, also used locally as
**Bazzite Screen**. It provides a live screen preview, cursor-following 2×/3× zoom
and a multitouch trackpad with clicks, scrolling and dragging.

## Install or update

Run from your desktop account. No clone is required:

```bash
curl -fsSL https://raw.githubusercontent.com/laurorual/unified-remote-kde-screen/main/install.sh -o install.sh
bash install.sh
```

Select your server's **remotes/Custom** directory when prompted. For example:

```bash
bash install.sh --custom-dir "$HOME/Downloads/UnifiedRemoteServer/remotes/Custom"
```

The installer checks dependencies, downloads
[KDE-Screen-Remote.zip from Releases > Latest](https://github.com/laurorual/unified-remote-kde-screen/releases/latest/download/KDE-Screen-Remote.zip),
backs up existing files and configures the authorized Python capture helper.
It uses `sudo` when needed for dependencies and files under `/usr/local`.
After installation, reopen **KDE Screen Remote** in the mobile app.

## Requirements

- KDE Plasma Wayland and Unified Remote Server for Linux.
- Python 3, dbus-python, Pillow and PyGObject/GLib.
- KWin's ScreenShot2 and scripting interfaces.

The installer supports dependency setup on Fedora, Bazzite/rpm-ostree,
Debian/Ubuntu and Arch. Other distributions need the dependencies installed
manually. `kscreen-doctor` is not required.

## Capture helper and backups

The screenshot helper is a copied Python executable. After a system Python
upgrade, rerun this installer to refresh it and avoid missing-library errors.
It also refreshes the legacy Bazzite Screen helper when that remote uses it.
Bazzite Screen controls and Wayland keyboard files are preserved.

Check the current helpers without installing packages, changing files or
restarting the service:

```bash
bash install.sh --custom-dir "$HOME/Downloads/UnifiedRemoteServer/remotes/Custom" --check
```

Use `--no-restart` to restart the server yourself. Backups are stored in the
server's `backups/` directory; the installer prints their location.

## Keyboard input

For symbols and accented text on KDE Wayland, install the separate
[Wayland Fix](https://github.com/laurorual/Unified-Remote-Linux-Wayland-Fix).
That project's mouse/keyboard runtime does not require Python.

## Development

Remote source files are in the repository root. Build the ZIP with
`python3 scripts/build_release.py` and run regression checks with
`python3 -m unittest discover -s tests -v`.

See [CHANGELOG.md](CHANGELOG.md) for history. Tested on Bazzite/KDE Wayland with
the Unified Remote Android client.
