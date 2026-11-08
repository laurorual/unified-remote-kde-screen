# KDE Screen Remote

A Unified Remote custom remote for **KDE Plasma on Wayland**, also formerly used
locally as **Bazzite Screen**. It offers an active-screen preview, cursor-following
2×/3× zoom, and a multitouch trackpad with scrolling, clicks and dragging.

## Install or update

Run as your normal desktop user. Unified Remote Server must already be installed.

```bash
curl -fsSL https://raw.githubusercontent.com/laurorual/unified-remote-kde-screen/main/install.sh -o install.sh
bash install.sh
```

The installer asks for the server's `remotes/Custom` directory, or you can supply it:

```bash
bash install.sh --custom-dir "$HOME/Downloads/UnifiedRemoteServer/remotes/Custom"
```

**Updates are manual:** rerun the same `install.sh`. It downloads the **current
`main` branch**, not a GitHub Release or a manually published ZIP. The installer
extracts only the expected remote files, validates the downloaded source, backs
up existing files, refreshes its authorized capture helpers, and restarts an
active `unified-remote.service` when possible.

Reopen **KDE Screen Remote** on your phone afterward. If the server is not
managed by that user service, restart it manually.

## Requirements and dependency handling

- KDE Plasma Wayland, Unified Remote Server for Linux, and KWin ScreenShot2 / scripting APIs.
- **Host** Python 3.9+ with dbus-python, PyGObject/GLib, and **Pillow 9.1+**.
- Bash, coreutils (including `timeout`), and working HTTPS access to GitHub.
- The installer supports Fedora, Bazzite/rpm-ostree, Debian/Ubuntu, and Arch.

The installer deliberately uses the host Python at `/usr/bin/python3` when
available, rather than a developer toolchain or virtual environment earlier in
`PATH`. It checks the interpreter and its required modules, asks for **explicit
permission before installing missing host packages**, and validates the modules
again afterward. On an immutable rpm-ostree system, package layering is clearly
announced beforehand; a reboot may be needed.

**Important after Bazzite/Fedora system updates:** the authorized helper is a
copy of the host Python executable in `/usr/local/libexec`. A Python upgrade
can make the old copy incompatible with system libraries. Simply rerun
`install.sh` to recreate it from the current host Python, without reinstalling
Unified Remote itself.

## Backups, checks and recovery

The installer backs up the prior remote, its Python helper, and its desktop
authorization entry before replacing them. On a failed installation it attempts
to roll back all affected files and prints the backup location.

```bash
# Check current host dependencies and capture helper without modifying anything:
bash install.sh --custom-dir "$HOME/Downloads/UnifiedRemoteServer/remotes/Custom" --check

# Install but restart the server yourself:
bash install.sh --custom-dir "$HOME/Downloads/UnifiedRemoteServer/remotes/Custom" --no-restart
```

It also preserves and refreshes the older **Bazzite Screen** capture helper
when the installed legacy remote specifically references the recognized helper.
It does not touch mouse/keyboard fixes managed by Wayland Fix.

## Keyboard input

To add symbols and accented text support on KDE Wayland, use the independent
[Unified Remote Wayland Fix](https://github.com/laurorual/Unified-Remote-Linux-Wayland-Fix).
The screen-capture remote itself does not require the keyboard fix.

## Development

Run regression checks with:

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
```

See [CHANGELOG.md](CHANGELOG.md) for project history. End-to-end screen capture
and the phone receiver still require testing on a running KDE Wayland session.
