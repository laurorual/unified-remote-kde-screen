#!/usr/bin/env bash
set -Eeuo pipefail

REMOTE_FOLDER="KDE Screen Remote"

DEFAULT_REPO_OWNER="laurorual"
REPO_OWNER="${KDE_SCREEN_REMOTE_REPO_OWNER:-$DEFAULT_REPO_OWNER}"
REPO_NAME="${KDE_SCREEN_REMOTE_REPO_NAME:-unified-remote-kde-screen}"

HELPER_BIN="/usr/local/libexec/kde-screen-remote-python"
DESKTOP_FILE="/usr/local/share/applications/org.kdescreenremote.helper.desktop"
BAZZITE_HELPER_BIN="/usr/local/libexec/bazzite-screen-python"
BAZZITE_DESKTOP_FILE="/usr/local/share/applications/org.bazzitescreen.helper.desktop"
WORK_DIR=""
BACKUP_DIR=""
HOST_PYTHON=""
MUTATION_STARTED=0
HAD_REMOTE=0
HAD_BIN=()
HAD_DESKTOP=()
REMOTE_CUSTOM_DIR=""

# Status messages go to stderr so functions can safely return values on stdout.
info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*" >&2; }
ok()    { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*" >&2; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

SUDO=""
configure_sudo() {
    if [[ ${EUID} -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || die "sudo is required."
        SUDO="sudo"
    fi
}

capture_python_ok() {
    [[ -x $1 ]] || return 1
    timeout 10s "$1" - <<'PY' >/dev/null 2>&1
import sys
if sys.version_info < (3, 9):
    raise SystemExit("Python >= 3.9 required")
import dbus
from PIL import Image
from gi.repository import GLib
if not hasattr(Image, "Resampling"):
    raise SystemExit("Pillow >= 9.1 required")
PY
}

detect_host_python() {
    # A developer SDK or an obsolete interpreter in PATH must not replace the OS Python.
    if [[ -x /usr/bin/python3 ]]; then
        HOST_PYTHON=$(readlink -f /usr/bin/python3)
    elif command -v python3 >/dev/null 2>&1; then
        HOST_PYTHON=$(readlink -f "$(command -v python3)")
    else
        die "Python 3 is required. Install your distribution's Python 3 and rerun."
    fi
    [[ -x $HOST_PYTHON ]] || die "Host Python is not executable: $HOST_PYTHON"
    info "Using host Python: $HOST_PYTHON"
}

collect_capture_helpers() {
    CAPTURE_BINS=("$HELPER_BIN")
    CAPTURE_DESKTOPS=("$DESKTOP_FILE")
    local launcher="$1/Bazzite Screen/remote.lua" line configured=''
    local declaration='^[[:space:]]*local[[:space:]]+python_bin[[:space:]]*=[[:space:]]*"([^"]+)";?[[:space:]]*$'
    if [[ -f $launcher && -f $1/Bazzite\ Screen/bazzite_screen_streamer.py ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ $declaration ]]; then configured=${BASH_REMATCH[1]}; break; fi
        done < "$launcher"
        if [[ $configured == "$BAZZITE_HELPER_BIN" ]]; then
            CAPTURE_BINS+=("$BAZZITE_HELPER_BIN")
            CAPTURE_DESKTOPS+=("$BAZZITE_DESKTOP_FILE")
        elif [[ $configured != "$HELPER_BIN" ]]; then
            warn "Preserving the custom Bazzite Screen interpreter: ${configured:-unrecognized launcher}."
        fi
    fi
}

check_capture_helpers() {
    local index binary desktop failed=0
    for index in "${!CAPTURE_BINS[@]}"; do
        binary=${CAPTURE_BINS[index]}; desktop=${CAPTURE_DESKTOPS[index]}
        if capture_python_ok "$binary" &&
           cmp -s -- "$HOST_PYTHON" "$binary" &&
           [[ -f $desktop ]] && grep -Fxq -- "Exec=$binary" "$desktop" &&
           grep -Fxq -- 'X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2' "$desktop"; then
            ok "Capture helper is current and its authorization entry is present: $binary"
        else
            warn "Capture helper needs installation or refresh: $binary"
            failed=1
        fi
    done
    (( failed == 0 ))
}

python_deps_ok() { capture_python_ok "$HOST_PYTHON"; }
all_deps_ok() { python_deps_ok; }

confirm_package_install() {
    local purpose=$1 answer
    warn "$purpose"
    if [[ ! -t 0 ]]; then
        die "Missing dependencies. Run interactively to approve package changes; no packages were installed."
    fi
    read -r -p "Allow the installer to install these host packages? [y/N] " answer
    case $answer in y|Y|yes|YES) :;; *) die "Package installation declined; no packages were installed.";; esac
}

install_dependencies() {
    info "Checking host Python runtime dependencies..."
    if all_deps_ok; then
        ok "Host Python and all capture modules are compatible."
        return
    fi

    "$HOST_PYTHON" -c 'import sys; assert sys.version_info >= (3, 9)' ||
        die "Python >= 3.9 is required; update the host Python first."
    local -a packages=()
    local manager='' immutable=0

    if [[ -f /run/ostree-booted ]] && command -v rpm-ostree >/dev/null 2>&1; then
        manager=rpm-ostree; immutable=1
    elif command -v dnf >/dev/null 2>&1; then manager=dnf
    elif command -v apt-get >/dev/null 2>&1; then manager=apt-get
    elif command -v pacman >/dev/null 2>&1; then manager=pacman
    else die "Unsupported package manager. Install dbus-python, PyGObject and Pillow >=9.1 for $HOST_PYTHON."; fi

    if ! "$HOST_PYTHON" -c 'import dbus' >/dev/null 2>&1; then
        case $manager in rpm-ostree|dnf) packages+=(python3-dbus);; apt-get) packages+=(python3-dbus);; pacman) packages+=(dbus-python);; esac
    fi
    if ! "$HOST_PYTHON" -c 'from gi.repository import GLib' >/dev/null 2>&1; then
        case $manager in rpm-ostree|dnf) packages+=(python3-gobject);; apt-get) packages+=(python3-gi);; pacman) packages+=(python-gobject);; esac
    fi
    if ! "$HOST_PYTHON" -c 'from PIL import Image; assert hasattr(Image, "Resampling")' >/dev/null 2>&1; then
        case $manager in rpm-ostree|dnf) packages+=(python3-pillow);; apt-get) packages+=(python3-pil);; pacman) packages+=(python-pillow);; esac
    fi
    (( ${#packages[@]} > 0 )) ||
        die "Python runtime validation failed, but no missing package was identified. Check Python/library ABI compatibility."

    if (( immutable )); then
        warn "Immutable host detected. rpm-ostree will LAYER these packages, modifying the system deployment and possibly requiring a reboot."
    fi
    confirm_package_install "Missing packages: ${packages[*]}"
    case $manager in
        rpm-ostree) $SUDO rpm-ostree install --apply-live "${packages[@]}";;
        dnf) $SUDO dnf install -y "${packages[@]}";;
        apt-get)
            $SUDO apt-get update
            $SUDO apt-get install -y "${packages[@]}";;
        pacman) $SUDO pacman -S --needed --noconfirm "${packages[@]}";;
    esac

    if ! all_deps_ok; then
        die "Python runtime is still incompatible after installing packages. On immutable systems, reboot and rerun this installer."
    fi
    ok "Capture Python dependencies verified."
}

download_main_snapshot() {
    local archive="$WORK_DIR/KDE-Screen-Remote.zip"
    local download_url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/main"
    info "Fetching current main branch source from GitHub..."
    "$HOST_PYTHON" - "$download_url" "$archive" <<'PY'
import io
import pathlib
import sys
import tarfile
import urllib.request
import zipfile

url, output = sys.argv[1:]
required = (
    "meta.prop", "layout.xml", "remote.lua", "kde_screen_remote_streamer.py",
    "cursor_tracker.js", "icon.png", "icon_hires.png", "CHANGELOG.md",
    "README.md", "LICENSE",
)
request = urllib.request.Request(url, headers={"User-Agent": "kde-screen-remote-installer"})
with urllib.request.urlopen(request, timeout=45) as response:
    data = response.read(20 * 1024 * 1024 + 1)
if len(data) > 20 * 1024 * 1024:
    raise RuntimeError("Source archive exceeds the 20 MiB safety limit")
files = {}
with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as source:
    for entry in source:
        path = pathlib.PurePosixPath(entry.name)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("Unsafe source archive path")
        if not (entry.isfile() or entry.isdir()):
            raise ValueError("Unsupported source archive entry")
        if len(path.parts) == 2 and path.parts[1] in required and entry.isfile():
            handle = source.extractfile(entry)
            if handle is None:
                raise ValueError("Cannot read source entry")
            files[path.parts[1]] = handle.read()
missing = sorted(set(required) - set(files))
if missing:
    raise ValueError("Source archive lacks: " + ", ".join(missing))
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for name in required:
        archive.writestr("KDE Screen Remote/" + name, files[name])
PY
    [[ -s "$archive" ]] || die "Downloaded source was empty."
    printf '%s\n' "$archive"
}

install_remote_files() {
    local zip_path="$1"
    local custom_dir="$2"
    local tmp_dir

    if ! mkdir -p "${custom_dir}" 2>/dev/null; then
        $SUDO mkdir -p "${custom_dir}"
    fi

    tmp_dir="$(mktemp -d "${WORK_DIR}/extract.XXXXXX")"

    "$HOST_PYTHON" - "${zip_path}" "${tmp_dir}" <<'PY'
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
    local python_real staged helper_bin=${1:-$HELPER_BIN} desktop_file=${2:-$DESKTOP_FILE}
    python_real="$HOST_PYTHON"

    info "Refreshing capture helper from the current host Python: $helper_bin"
    capture_python_ok "$python_real" || die "Host Python cannot load the capture dependencies."
    if [[ -e "${helper_bin}" ]]; then
        $SUDO cp -a "${helper_bin}" "${BACKUP_DIR}/$(basename -- "$helper_bin")"
    fi
    if [[ -e "${desktop_file}" ]]; then
        $SUDO cp -a "${desktop_file}" "${BACKUP_DIR}/$(basename -- "$desktop_file")"
    fi
    $SUDO mkdir -p -- "$(dirname -- "$helper_bin")"
    staged=$($SUDO mktemp -- "$(dirname -- "$helper_bin")/.screen-python-XXXXXX")
    if ! $SUDO install -m755 "${python_real}" "$staged" || ! capture_python_ok "$staged"; then
        $SUDO rm -f -- "$staged"
        die "The copied Python failed validation; the previous capture helper was preserved."
    fi
    if ! $SUDO mv -f -- "$staged" "$helper_bin"; then
        $SUDO rm -f -- "$staged"
        die "Could not replace the capture helper."
    fi

    $SUDO mkdir -p -- "$(dirname -- "$desktop_file")"
    $SUDO tee "${desktop_file}" >/dev/null <<EOF
[Desktop Entry]
Name=KDE Screen Remote Helper
Comment=KWin ScreenShot2 helper for Unified Remote
Exec=${helper_bin}
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

snapshot_installation() {
    local index
    if [[ -e "$REMOTE_CUSTOM_DIR/$REMOTE_FOLDER" || -L "$REMOTE_CUSTOM_DIR/$REMOTE_FOLDER" ]]; then
        [[ -d "$REMOTE_CUSTOM_DIR/$REMOTE_FOLDER" && ! -L "$REMOTE_CUSTOM_DIR/$REMOTE_FOLDER" ]] ||
            die "Refusing to replace a non-directory or symlinked remote."
        HAD_REMOTE=1
        $SUDO cp -a -- "$REMOTE_CUSTOM_DIR/$REMOTE_FOLDER" "$BACKUP_DIR/remote-original"
    fi
    for index in "${!CAPTURE_BINS[@]}"; do
        if [[ -e "${CAPTURE_BINS[index]}" || -L "${CAPTURE_BINS[index]}" ]]; then
            [[ -f "${CAPTURE_BINS[index]}" && ! -L "${CAPTURE_BINS[index]}" ]] ||
                die "Refusing to replace a symlink or non-file helper: ${CAPTURE_BINS[index]}"
            HAD_BIN[index]=1
            $SUDO cp -a -- "${CAPTURE_BINS[index]}" "$BACKUP_DIR/helper-$index"
        else HAD_BIN[index]=0; fi
        if [[ -e "${CAPTURE_DESKTOPS[index]}" || -L "${CAPTURE_DESKTOPS[index]}" ]]; then
            [[ -f "${CAPTURE_DESKTOPS[index]}" && ! -L "${CAPTURE_DESKTOPS[index]}" ]] ||
                die "Refusing to replace a symlink or non-file desktop entry."
            HAD_DESKTOP[index]=1
            $SUDO cp -a -- "${CAPTURE_DESKTOPS[index]}" "$BACKUP_DIR/desktop-$index"
        else HAD_DESKTOP[index]=0; fi
    done
}

rollback_installation() {
    local index
    warn "Rolling back files from $BACKUP_DIR"
    $SUDO rm -rf -- "$REMOTE_CUSTOM_DIR/$REMOTE_FOLDER" || true
    if (( HAD_REMOTE )); then
        $SUDO cp -a -- "$BACKUP_DIR/remote-original" "$REMOTE_CUSTOM_DIR/$REMOTE_FOLDER" || warn "Could not restore the previous remote."
    fi
    for index in "${!CAPTURE_BINS[@]}"; do
        $SUDO rm -f -- "${CAPTURE_BINS[index]}" || true
        if (( HAD_BIN[index] )); then
            $SUDO cp -a -- "$BACKUP_DIR/helper-$index" "${CAPTURE_BINS[index]}" || warn "Could not restore a capture helper."
        fi
        $SUDO rm -f -- "${CAPTURE_DESKTOPS[index]}" || true
        if (( HAD_DESKTOP[index] )); then
            $SUDO cp -a -- "$BACKUP_DIR/desktop-$index" "${CAPTURE_DESKTOPS[index]}" || warn "Could not restore a desktop entry."
        fi
    done
    if command -v systemctl >/dev/null 2>&1 &&
       systemctl --user is-active --quiet unified-remote.service 2>/dev/null; then
        systemctl --user restart unified-remote.service || warn "Restart the server manually after rollback."
    fi
}

on_exit() {
    local status=$1
    trap - EXIT
    if (( status != 0 && MUTATION_STARTED )); then
        rollback_installation || warn "Rollback was incomplete; manual backups are in $BACKUP_DIR"
    fi
    [[ -z $WORK_DIR ]] || rm -rf -- "$WORK_DIR"
    exit "$status"
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
    local custom_dir="${CUSTOM_REMOTES_DIR:-}" check_only=0 restart=1 index
    while (( $# )); do
        case $1 in
            --custom-dir)
                [[ $# -ge 2 && -n $2 ]] || die "--custom-dir requires a path."
                custom_dir=$2; shift 2;;
            --check) check_only=1; shift;;
            --no-restart) restart=0; shift;;
            -h|--help)
                printf '%s\n' 'Usage: bash install.sh [--custom-dir PATH] [--check] [--no-restart]'
                printf '%s\n' 'Checks/refreshes the authorized Python capture helpers; --check changes nothing.'
                return 0;;
            *) die "Unknown option: $1";;
        esac
    done
    printf '\nKDE Screen Remote installer (main branch)\n\n'

    if [[ "${XDG_SESSION_TYPE:-}" != "wayland" ]]; then
        warn "Current session does not report XDG_SESSION_TYPE=wayland."
    fi

    if [[ "${XDG_CURRENT_DESKTOP:-}" != *KDE* && "${XDG_CURRENT_DESKTOP:-}" != *Plasma* ]]; then
        warn "Current desktop does not appear to be KDE Plasma."
    fi

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
    [[ $(basename -- "$custom_dir") == Custom && -d $custom_dir/../Unified/Core ]] ||
        die "Choose the server's remotes/Custom directory (its sibling Unified/Core must exist)."
    command -v timeout >/dev/null || die "timeout (coreutils) is required for capture-helper checks."
    collect_capture_helpers "$custom_dir"
    if (( check_only )); then
        detect_host_python
        all_deps_ok || die "Host Python >=3.9, Pillow >=9.1, D-Bus or GI modules are missing."
        check_capture_helpers
        return
    fi
    configure_sudo
    detect_host_python
    install_dependencies

    WORK_DIR="$(mktemp -d)"
    trap 'on_exit "$?"' EXIT
    local zip_path
    zip_path="$(download_main_snapshot)"
    BACKUP_DIR="${custom_dir}/../../backups/kde-screen-remote-$(date +%Y%m%d-%H%M%S)-$$"
    $SUDO mkdir -p "${BACKUP_DIR}"
    REMOTE_CUSTOM_DIR="$custom_dir"
    snapshot_installation
    MUTATION_STARTED=1

    install_remote_files "${zip_path}" "${custom_dir}"
    for index in "${!CAPTURE_BINS[@]}"; do
        install_authorized_python_helper "${CAPTURE_BINS[index]}" "${CAPTURE_DESKTOPS[index]}"
    done
    check_capture_helpers || die "Capture-helper verification failed. Backups: $BACKUP_DIR"
    if (( restart )); then restart_unified_remote_if_possible; fi

    MUTATION_STARTED=0
    printf '\n'
    ok "KDE Screen Remote from the current main branch is installed."
    info "Backups: ${BACKUP_DIR}"
    info "Open Unified Remote on your phone and select '${REMOTE_FOLDER}'."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

