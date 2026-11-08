# Changelog

## v1.0.2 — 2026-11-08

- Fix blue/red channel swaps when KWin returns RGBX8888 or RGBA8888 frames.
- Preserve ScreenShot2 pixel-format metadata and decode each frame accordingly,
  retaining native-endian RGB32/ARGB32 and RGB888 support.
- Correctly unpremultiply alpha and honor row padding; reject unsupported formats
  instead of silently guessing a channel order.
- Add known-color, JPEG, alpha, endianness and capture-metadata regressions; run
  the test suite before publishing the versionless Latest release archive.

## 2026-11-08 — Capture installer checks

- Keep Python capture-helper checks in the screen installer, separate from the
  Wayland mouse/keyboard installer.
- Add `--custom-dir`, read-only `--check` and `--no-restart` options.
- Validate a staged copy of the host Python before replacing a helper, preserve
  the previous binary/authorization entry in backups and verify the installed copy.
- Refresh the legacy Bazzite Screen helper when the installed remote references it.
- Validate the selected Custom directory and shorten the installation README.

## v1.0.1 — 2026-11-05

- Fixed cursor-following zoom stuck at the right edge of a secondary monitor.
- Receive cursor position and per-output logical geometry together from KWin,
  matching the captured monitor by name and accounting for its desktop offset.
- Removed `kscreen-doctor` and its dependency on graphical environment variables
  inherited by the Unified Remote service.
- Keep the preview centered if geometry is unavailable instead of using an
  incorrect monitor origin. Continue reading geometry as frames are captured.
- Published the remote's source files directly in the repository root.
- Changed installation to download `KDE-Screen-Remote.zip` from Releases > Latest.
- Added backups when updating an existing remote and included this changelog in
  the release ZIP.
- Documented the separate Wayland keyboard fix for symbols and accented text.

Validation: zoom regression checks for primary/secondary monitors, negative
origins and logical scaling; live KWin capture without DISPLAY/WAYLAND_DISPLAY.
End-to-end phone validation remains dependent on the user's receiver test.

## v1.0.0

- Initial KDE Plasma Wayland remote with active-monitor preview, cursor-following
  zoom, trackpad controls, clicks, two-finger scrolling, right click and dragging.
