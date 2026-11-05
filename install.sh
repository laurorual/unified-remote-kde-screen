#!/usr/bin/env bash
set -Eeuo pipefail

ZIP_NAME="KDE-Screen-Remote.zip"
REMOTE_FOLDER="KDE Screen Remote"

DEFAULT_REPO_OWNER="laurorual"
REPO_OWNER="${KDE_SCREEN_REMOTE_REPO_OWNER:-$DEFAULT_REPO_OWNER}"
REPO_NAME="${KDE_SCREEN_REMOTE_REPO_NAME:-unified-remote-kde-screen}"

HELPER_BIN="/usr/local/libexec/kde-screen-remote-python"
DESKTOP_FILE="/usr/local/share/applications/org.kdescreenremote.helper.desktop"
WORK_DIR=""
BACKUP_DIR=""

# Status messages go to stderr so functions can safely return values on stdout.
info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2; }
ok()    { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "sudo is required."
    SUDO="sudo"
fi

python_deps_ok() {
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - <<'PY' >/dev/null 2>&1
import dbus
from PIL import Image
from gi.repository import GLib
PY
}

all_deps_ok() {
    command -v python3 >/dev/null 2>&1 || return 1
    python_deps_ok || return 1
}

install_dependencies() {
    info "Checking runtime dependencies..."

    if all_deps_ok; then
        ok "All runtime dependencies are already installed."
        return
    fi

    warn "Some dependencies are missing. Trying to install them."

    # Prefer rpm-ostree on immutable Fedora-family systems such as Bazzite.
    if command -v rpm-ostree >/dev/null 2>&1 && [[ -f /run/ostree-booted ]]; then
        info "Detected rpm-ostree system."
        $SUDO rpm-ostree install --apply-live \
            python3 \
            python3-dbus \
            python3-pillow \
            python3-gobject

    elif command -v dnf >/dev/null 2>&1; then
        info "Detected Fedora/RHEL-style system."
        $SUDO dnf install -y \
            python3 \
            python3-dbus \
            python3-pillow \
            python3-gobject

    elif command -v apt-get >/dev/null 2>&1; then
        info "Detected Debian/Ubuntu-style system."
        $SUDO apt-get update
        $SUDO apt-get install -y \
            python3 \
            python3-dbus \
            python3-pil \
            python3-gi

    elif command -v pacman >/dev/null 2>&1; then
        info "Detected Arch-style system."
        $SUDO pacman -S --needed --noconfirm \
            python \
            dbus-python \
            python-pillow \
            python-gobject

    else
        die "Unsupported package manager. Install Python 3, dbus-python, Pillow and PyGObject/GLib manually, then rerun this script."
    fi

    if ! all_deps_ok; then
        die "Dependencies are still unavailable after installation. On an immutable system, a reboot may be required before rerunning the installer."
    fi

    ok "Dependencies installed."
}

download_release_zip() {
    local download_url
    download_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${ZIP_NAME}"

    info "Downloading ${ZIP_NAME} from GitHub..."

    python3 - "${download_url}" "${WORK_DIR}/${ZIP_NAME}" <<'PY'
import sys
import urllib.request

url, output = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=30) as response:
    data = response.read()
with open(output, "wb") as f:
    f.write(data)
PY

    [[ -s "${WORK_DIR}/${ZIP_NAME}" ]] || die "Downloaded ZIP is empty."
    printf '%s\n' "${WORK_DIR}/${ZIP_NAME}"
}

install_remote_files() {
    local zip_path="$1"
    local custom_dir="$2"
    local tmp_dir

    if ! mkdir -p "${custom_dir}" 2>/dev/null; then
        $SUDO mkdir -p "${custom_dir}"
    fi

    tmp_dir="$(mktemp -d "${WORK_DIR}/extract.XXXXXX")"

    python3 - "${zip_path}" "${tmp_dir}" <<'PY'
import sys
import zipfile
from pathlib import Path

archive, destination = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as z:
    root = Path(destination).resolve()
    for entry in z.infolist():
        if not (root / entry.filename).resolve().is_relative_to(root):
            raise ValueError("Unsafe path in release archive")
    z.extractall(destination)
PY

    [[ -d "${tmp_dir}/${REMOTE_FOLDER}" ]] || die "ZIP does not contain the expected '${REMOTE_FOLDER}' folder."
    local required
    for required in meta.prop layout.xml remote.lua kde_screen_remote_streamer.py cursor_tracker.js icon.png icon_hires.png CHANGELOG.md; do
        [[ -f "${tmp_dir}/${REMOTE_FOLDER}/${required}" ]] || die "ZIP is missing ${required}."
    done

    info "Installing remote into: ${custom_dir}"

    if [[ -e "${custom_dir}/${REMOTE_FOLDER}" ]]; then
        info "Backing up the existing remote to ${BACKUP_DIR}"
        $SUDO cp -a "${custom_dir}/${REMOTE_FOLDER}" "${BACKUP_DIR}/"
    fi

    if [[ -w "${custom_dir}" ]]; then
        rm -rf "${custom_dir:?}/${REMOTE_FOLDER}"
        cp -a "${tmp_dir}/${REMOTE_FOLDER}" "${custom_dir}/"
    else
        $SUDO rm -rf "${custom_dir:?}/${REMOTE_FOLDER}"
        $SUDO cp -a "${tmp_dir}/${REMOTE_FOLDER}" "${custom_dir}/"
    fi

    ok "Remote files installed."
}

install_authorized_python_helper() {
    local python_real
    python_real="$(readlink -f "$(command -v python3)")"

    info "Installing authorized Python helper..."
    if [[ -e "${HELPER_BIN}" ]]; then
        $SUDO cp -a "${HELPER_BIN}" "${BACKUP_DIR}/kde-screen-remote-python"
    fi
    if [[ -e "${DESKTOP_FILE}" ]]; then
        $SUDO cp -a "${DESKTOP_FILE}" "${BACKUP_DIR}/org.kdescreenremote.helper.desktop"
    fi
    $SUDO install -Dm755 "${python_real}" "${HELPER_BIN}"

    $SUDO tee "${DESKTOP_FILE}" >/dev/null <<EOF
[Desktop Entry]
Name=KDE Screen Remote Helper
Comment=KWin ScreenShot2 helper for Unified Remote
Exec=${HELPER_BIN}
Type=Application
NoDisplay=true
Terminal=false
StartupNotify=false
X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2
EOF

    if command -v update-desktop-database >/dev/null 2>&1; then
        $SUDO update-desktop-database /usr/local/share/applications >/dev/null 2>&1 || true
    fi

    ok "KWin ScreenShot2 authorization helper installed."
}

restart_unified_remote_if_possible() {
    if command -v systemctl >/dev/null 2>&1 && \
       systemctl --user is-active --quiet unified-remote.service 2>/dev/null; then
        info "Restarting unified-remote.service..."
        systemctl --user restart unified-remote.service
        ok "Unified Remote restarted."
    else
        warn "Unified Remote was not detected as the user service 'unified-remote.service'. Restart Unified Remote Server manually before using the remote."
    fi
}

main() {
    printf '\nKDE Screen Remote installer (Latest release)\n\n'

    if [[ "${XDG_SESSION_TYPE:-}" != "wayland" ]]; then
        warn "Current session does not report XDG_SESSION_TYPE=wayland."
    fi

    if [[ "${XDG_CURRENT_DESKTOP:-}" != *KDE* && "${XDG_CURRENT_DESKTOP:-}" != *Plasma* ]]; then
        warn "Current desktop does not appear to be KDE Plasma."
    fi

    install_dependencies

    local custom_dir="${CUSTOM_REMOTES_DIR:-}"

    if [[ -z "${custom_dir}" ]]; then
        printf 'Enter the full path to your Unified Remote remotes/Custom directory:\n> '
        IFS= read -r custom_dir
    fi

    [[ -n "${custom_dir}" ]] || die "No Custom remotes directory was provided."

    # Expand a leading ~/ entered interactively.
    if [[ "${custom_dir}" == "~/"* ]]; then
        custom_dir="${HOME}/${custom_dir#\~/}"
    fi
    [[ "${custom_dir}" == /* ]] || die "Provide an absolute Custom remotes directory."

    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf -- "${WORK_DIR}"' EXIT
    BACKUP_DIR="${custom_dir}/../../backups/kde-screen-remote-$(date +%Y%m%d-%H%M%S)-$$"
    $SUDO mkdir -p "${BACKUP_DIR}"

    local zip_path
    zip_path="$(download_release_zip)"

    install_remote_files "${zip_path}" "${custom_dir}"
    install_authorized_python_helper
    restart_unified_remote_if_possible

    printf '\n'
    ok "KDE Screen Remote from Releases > Latest is installed."
    info "Backups: ${BACKUP_DIR}"
    info "Open Unified Remote on your phone and select '${REMOTE_FOLDER}'."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

