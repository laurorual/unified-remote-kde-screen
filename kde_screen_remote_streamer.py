#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import io
import json
import os
import select
import signal
import threading
import time
from pathlib import Path

import dbus
from PIL import Image

SERVICE = "org.kde.KWin"
OBJECT = "/org/kde/KWin/ScreenShot2"
INTERFACE = "org.kde.KWin.ScreenShot2"

CURSOR_BUS = "org.kdescreenremote.CursorTracker"
CURSOR_PATH = "/CursorTracker"
CURSOR_INTERFACE = "org.kdescreenremote.CursorTracker"
CURSOR_SCRIPT_NAME = "KDEScreenRemoteCursorTracker"

RUN_DIR = Path("/tmp/kde-screen-remote")
PID_FILE = RUN_DIR / "stream.pid"
LOCK_FILE = RUN_DIR / "stream.lock"
STATE_FILE = RUN_DIR / "state.txt"
ZOOM_FILE = RUN_DIR / "zoom.txt"
LOG_FILE = RUN_DIR / "stream.log"
FRAME_A = RUN_DIR / "frame-a.jpg"
FRAME_B = RUN_DIR / "frame-b.jpg"

running = True


def log(msg: str):
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} | {msg}\n")


def atomic_write(path: Path, data: bytes):
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    try:
        with tmp.open("wb") as f:
            f.write(data)
            f.flush()
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass


def atomic_write_text(path: Path, text: str):
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass


def handle_stop(signum, frame):
    global running
    running = False


class KWinCapture:
    RETRYABLE_DBUS_ERRORS = {
        "org.freedesktop.DBus.Error.UnknownMethod",
        "org.freedesktop.DBus.Error.UnknownObject",
        "org.freedesktop.DBus.Error.ServiceUnknown",
        "org.freedesktop.DBus.Error.NameHasNoOwner",
    }

    def __init__(self):
        self.bus = None
        self.iface = None
        # ScreenShot2 expects QVariantMap -> D-Bus a{sv}, not a{sb}.
        # When introspection is disabled, dbus-python otherwise infers our
        # boolean-only dict as a{sb}, which makes Qt report UnknownMethod.
        self.options = dbus.Dictionary(
            {
                "include-cursor": dbus.Boolean(True, variant_level=1),
                "native-resolution": dbus.Boolean(True, variant_level=1),
            },
            signature="sv",
        )
        self._connect()

    def _connect(self):
        # Recreate the proxy as well as the Interface object. This avoids
        # retaining stale D-Bus state if ScreenShot2 is temporarily
        # unregistered/re-registered by KWin.
        self.bus = dbus.SessionBus()
        obj = self.bus.get_object(
            SERVICE,
            OBJECT,
            introspect=False,
        )
        self.iface = dbus.Interface(obj, INTERFACE)

    @staticmethod
    def read_exact(fd: int, expected: int, timeout=2.0) -> bytes:
        chunks = []
        total = 0
        deadline = time.monotonic() + timeout

        while total < expected:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError(f"timeout reading pipe {total}/{expected}")

            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                raise RuntimeError(f"timeout waiting pipe {total}/{expected}")

            chunk = os.read(fd, min(1024 * 1024, expected - total))
            if not chunk:
                break

            chunks.append(chunk)
            total += len(chunk)

        data = b"".join(chunks)

        if len(data) < expected:
            raise RuntimeError(f"pipe closed early {len(data)}/{expected}")

        return data

    def capture_active(self):
        # KWin's ScreenShot2 endpoint can very occasionally be transiently
        # unavailable during startup/reconfiguration. Previously a single
        # UnknownMethod killed the whole streamer, leaving the phone with a
        # blank preview until the remote was reopened.
        #
        # Retry only availability-related D-Bus failures. Real capture errors
        # are still raised immediately.
        max_attempts = 20
        retry_delay = 0.10
        last_error = None

        for attempt in range(1, max_attempts + 1):
            read_fd, write_fd = os.pipe()
            started = time.perf_counter()

            try:
                unix_fd = dbus.types.UnixFd(write_fd)

                try:
                    # Force the exact ScreenShot2 wire signature:
                    # QVariantMap (a{sv}) + Unix FD (h).
                    capture_method = self.iface.get_dbus_method(
                        "CaptureActiveScreen",
                        INTERFACE,
                    )
                    result = capture_method(
                        self.options,
                        unix_fd,
                        signature="a{sv}h",
                    )
                except dbus.DBusException as exc:
                    error_name = exc.get_dbus_name()
                    last_error = exc

                    if error_name not in self.RETRYABLE_DBUS_ERRORS:
                        raise

                    log(
                        "CAPTURE RETRY "
                        f"{attempt}/{max_attempts}: "
                        f"{error_name}: {exc.get_dbus_message()}"
                    )

                    # This attempt never produced a frame.
                    os.close(write_fd)
                    write_fd = -1
                    os.close(read_fd)
                    read_fd = -1

                    if attempt >= max_attempts:
                        break

                    time.sleep(retry_delay)

                    try:
                        self._connect()
                    except Exception as reconnect_exc:
                        log(
                            "CAPTURE RECONNECT ERROR: "
                            f"{type(reconnect_exc).__name__}: "
                            f"{reconnect_exc}"
                        )

                    continue

                finally:
                    if write_fd != -1:
                        os.close(write_fd)
                        write_fd = -1

                width = int(result["width"])
                height = int(result["height"])
                stride = int(result["stride"])

                data = self.read_exact(
                    read_fd,
                    stride * height,
                )

                capture_ms = (
                    time.perf_counter() - started
                ) * 1000.0

                screen = str(
                    result.get("screen", "unknown")
                )

                if attempt > 1:
                    log(
                        "CAPTURE RECOVERED "
                        f"after {attempt} attempts "
                        f"({capture_ms:.1f} ms)"
                    )

                return (
                    data,
                    width,
                    height,
                    stride,
                    screen,
                    capture_ms,
                )

            finally:
                if write_fd != -1:
                    try:
                        os.close(write_fd)
                    except OSError:
                        pass

                if read_fd != -1:
                    try:
                        os.close(read_fd)
                    except OSError:
                        pass

        if last_error is not None:
            raise last_error

        raise RuntimeError(
            "CaptureActiveScreen remained unavailable "
            "after retry window"
        )


class CursorTracker:
    """Receive real Plasma Wayland cursor coordinates from a temporary KWin script."""

    def __init__(self, script_path: Path):
        self.script_path = script_path
        self._lock = threading.Lock()
        self._position = None
        self._geometries = {}
        self._updated_at = 0.0
        self._loop = None
        self._thread = None
        self._service = None
        self._script_iface = None
        self._scripting_iface = None
        self.available = False

    def start(self):
        try:
            import dbus.service
            import dbus.mainloop.glib
            from gi.repository import GLib
        except Exception as exc:
            log(f"CURSOR TRACKER unavailable: imports failed: {exc}")
            return

        try:
            dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)

            bus = dbus.SessionBus()
            tracker = self

            class CursorService(dbus.service.Object):
                @dbus.service.method(
                    CURSOR_INTERFACE,
                    in_signature="s",
                    out_signature="",
                )
                def ReportState(self, state):
                    # Cursor and outputs share KWin's logical coordinate space.
                    snapshot = json.loads(str(state))
                    geometries = {
                        str(output["name"]): tuple(
                            int(output[key]) for key in ("x", "y", "width", "height")
                        )
                        for output in snapshot["screens"]
                        if output["width"] > 0 and output["height"] > 0
                    }
                    with tracker._lock:
                        tracker._position = (snapshot["x"], snapshot["y"])
                        tracker._geometries = geometries
                        tracker._updated_at = time.monotonic()

            bus_name = dbus.service.BusName(
                CURSOR_BUS,
                bus=bus,
                do_not_queue=True,
            )

            self._service = CursorService(bus_name, CURSOR_PATH)
            self._loop = GLib.MainLoop()
            self._thread = threading.Thread(
                target=self._loop.run,
                name="kde-screen-remote-dbus",
                daemon=True,
            )
            self._thread.start()

            scripting_obj = bus.get_object("org.kde.KWin", "/Scripting")
            self._scripting_iface = dbus.Interface(
                scripting_obj,
                "org.kde.kwin.Scripting",
            )

            # Clean up a stale dynamically-loaded copy if a prior run crashed.
            try:
                self._scripting_iface.unloadScript(CURSOR_SCRIPT_NAME)
            except Exception:
                pass

            # org.kde.kwin.Scripting overloads loadScript(s) and loadScript(ss).
            # dbus-python can pick the 1-argument introspection signature and then
            # fail with: "Fewer items found in D-Bus signature than in Python arguments".
            # Force the two-string overload explicitly.
            load_script = self._scripting_iface.get_dbus_method(
                "loadScript",
                "org.kde.kwin.Scripting",
            )
            script_id = int(
                load_script(
                    dbus.String(str(self.script_path)),
                    dbus.String(CURSOR_SCRIPT_NAME),
                    signature="ss",
                )
            )

            script_obj = bus.get_object(
                "org.kde.KWin",
                f"/Scripting/Script{script_id}",
            )
            self._script_iface = dbus.Interface(
                script_obj,
                "org.kde.kwin.Script",
            )
            self._script_iface.run()

            # Allow the initial ReportState DBus call to arrive.
            for _ in range(20):
                time.sleep(0.025)
                if self.get() is not None:
                    break

            self.available = self.get() is not None

            if self.available:
                pos = self.get()
                log(
                    f"CURSOR TRACKER OK script_id={script_id} "
                    f"position={pos[0]},{pos[1]}"
                )
            else:
                log(
                    "CURSOR TRACKER started but no cursor position was received"
                )

        except Exception as exc:
            log(
                f"CURSOR TRACKER ERROR: {type(exc).__name__}: {exc}"
            )
            self.available = False

    def get(self):
        with self._lock:
            if self._position is None:
                return None

            # Cursor updates are event-driven: KWin reports a new position only
            # when the pointer moves. A stationary cursor is still perfectly
            # valid, so keep the last known position indefinitely.
            return self._position

    def stop(self):
        try:
            if self._script_iface is not None:
                self._script_iface.stop()
        except Exception:
            pass

        try:
            if self._scripting_iface is not None:
                self._scripting_iface.unloadScript(CURSOR_SCRIPT_NAME)
        except Exception:
            pass

        try:
            if self._loop is not None:
                self._loop.quit()
        except Exception:
            pass


    def snapshot(self, screen_name):
        with self._lock:
            return self._position, self._geometries.get(screen_name)


def read_zoom():
    try:
        value = float(
            ZOOM_FILE.read_text(encoding="utf-8").strip()
        )

        if value in (1.0, 2.0, 3.0):
            return value
    except Exception:
        pass

    return 2.0


def encode_jpeg(
    data,
    width,
    height,
    stride,
    geometry,
    cursor_position,
    max_width=960,
    quality=55,
):
    started = time.perf_counter()

    image = Image.frombytes(
        "RGBA",
        (width, height),
        data,
        "raw",
        "BGRA",
        stride,
        1,
    ).convert("RGB")

    zoom = read_zoom()

    # Default is the monitor center if the KWin cursor bridge is unavailable.
    center_x = 0.5
    center_y = 0.5

    if cursor_position is not None and geometry is not None:
        origin_x, origin_y, logical_w, logical_h = geometry
        cursor_x, cursor_y = cursor_position

        center_x = max(
            0.0,
            min(
                1.0,
                (cursor_x - origin_x) / max(logical_w, 1),
            ),
        )
        center_y = max(
            0.0,
            min(
                1.0,
                (cursor_y - origin_y) / max(logical_h, 1),
            ),
        )

    if zoom > 1.0:
        crop_width = max(1, round(width / zoom))
        crop_height = max(1, round(height / zoom))

        pixel_x = center_x * width
        pixel_y = center_y * height

        left = round(pixel_x - crop_width / 2)
        top = round(pixel_y - crop_height / 2)

        left = max(0, min(left, width - crop_width))
        top = max(0, min(top, height - crop_height))

        image = image.crop(
            (
                left,
                top,
                left + crop_width,
                top + crop_height,
            )
        )

    output_height = round(
        max_width * image.height / image.width
    )

    image = image.resize(
        (max_width, output_height),
        Image.Resampling.BILINEAR,
    )

    buffer = io.BytesIO()
    image.save(
        buffer,
        "JPEG",
        quality=quality,
        optimize=False,
    )

    payload = buffer.getvalue()

    encode_ms = (
        time.perf_counter() - started
    ) * 1000.0

    return (
        payload,
        image.size,
        encode_ms,
        zoom,
        center_x,
        center_y,
    )


def acquire_single_instance_lock():
    RUN_DIR.mkdir(parents=True, exist_ok=True)

    lock_fd = os.open(
        LOCK_FILE,
        os.O_CREAT | os.O_RDWR,
        0o600,
    )

    try:
        fcntl.flock(
            lock_fd,
            fcntl.LOCK_EX | fcntl.LOCK_NB,
        )
    except BlockingIOError:
        os.close(lock_fd)
        raise RuntimeError(
            "another KDE Screen Remote helper is already running"
        )

    return lock_fd


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fps", type=float, default=10.0)
    parser.add_argument("--width", type=int, default=960)
    parser.add_argument("--quality", type=int, default=55)
    parser.add_argument(
        "--cursor-script",
        type=Path,
        required=True,
    )
    args = parser.parse_args()

    lock_fd = acquire_single_instance_lock()
    PID_FILE.write_text(str(os.getpid()), encoding="utf-8")

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)

    cursor_tracker = CursorTracker(
        args.cursor_script.resolve()
    )
    cursor_tracker.start()

    capture = KWinCapture()

    period = 1.0 / max(args.fps, 0.1)
    deadline = time.perf_counter()
    seq = 0

    last_geometry = None

    log(
        f"START pid={os.getpid()} fps={args.fps:g} "
        f"mode=active width={args.width} q={args.quality} "
        f"cursor_tracker={'yes' if cursor_tracker.available else 'fallback'}"
    )

    try:
        while running:
            frame_started = time.perf_counter()
            seq += 1

            (
                data,
                source_w,
                source_h,
                stride,
                screen,
                capture_ms,
            ) = capture.capture_active()

            cursor_position, geometry = cursor_tracker.snapshot(screen)
            if (screen, geometry) != last_geometry:
                log(f"GEOMETRY screen={screen} logical={geometry}")
                last_geometry = (screen, geometry)

            (
                payload,
                output_size,
                jpeg_ms,
                zoom,
                center_x,
                center_y,
            ) = encode_jpeg(
                data,
                source_w,
                source_h,
                stride,
                geometry,
                cursor_position,
                args.width,
                args.quality,
            )

            frame_path = (
                FRAME_A if seq % 2 else FRAME_B
            )

            atomic_write(frame_path, payload)

            total_ms = (
                time.perf_counter() - frame_started
            ) * 1000.0

            state = (
                f"{seq}\n"
                f"{frame_path}\n"
                f"{capture_ms:.3f}\n"
                f"{jpeg_ms:.3f}\n"
                f"{total_ms:.3f}\n"
                f"{len(payload)}\n"
                f"{output_size[0]}x{output_size[1]}\n"
                f"{screen}\n"
                f"{args.fps:g}\n"
                f"{os.getpid()}\n"
                f"{zoom:g}\n"
                f"{center_x:.6f}\n"
                f"{center_y:.6f}\n"
                f"{1 if cursor_position is not None else 0}\n"
            )

            atomic_write_text(
                STATE_FILE,
                state,
            )

            if seq == 1 or seq % 50 == 0:
                cursor_text = (
                    f"{cursor_position[0]},{cursor_position[1]}"
                    if cursor_position is not None
                    else "unavailable"
                )

                log(
                    f"frame={seq} screen={screen} "
                    f"capture={capture_ms:.1f}ms "
                    f"jpeg={jpeg_ms:.1f}ms "
                    f"total={total_ms:.1f}ms "
                    f"size={output_size[0]}x{output_size[1]} "
                    f"zoom={zoom:g} "
                    f"cursor={cursor_text} "
                    f"center={center_x:.3f},{center_y:.3f}"
                )

            deadline += period
            delay = deadline - time.perf_counter()

            if delay > 0:
                time.sleep(delay)
            else:
                deadline = time.perf_counter()

    except Exception as exc:
        log(
            f"ERROR {type(exc).__name__}: {exc}"
        )
        raise

    finally:
        cursor_tracker.stop()

        log(
            f"STOP pid={os.getpid()} frames={seq}"
        )

        try:
            if (
                PID_FILE.exists()
                and PID_FILE.read_text().strip()
                == str(os.getpid())
            ):
                PID_FILE.unlink()
        except Exception:
            pass

        try:
            fcntl.flock(
                lock_fd,
                fcntl.LOCK_UN,
            )
            os.close(lock_fd)
        except Exception:
            pass


if __name__ == "__main__":
    main()
