#!/usr/bin/env python3
"""Build the versionless release asset from an explicit list of source files."""
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = (
    "meta.prop", "layout.xml", "remote.lua", "kde_screen_remote_streamer.py",
    "cursor_tracker.js", "icon.png", "icon_hires.png",
    "CHANGELOG.md", "README.md", "LICENSE",
)


def build():
    output = ROOT / "dist" / "KDE-Screen-Remote.zip"
    output.parent.mkdir(exist_ok=True)
    for name in FILES:
        if not (ROOT / name).is_file():
            raise FileNotFoundError(name)
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name in FILES:
            entry = zipfile.ZipInfo(f"KDE Screen Remote/{name}")
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = (0o100755 if name.endswith(".py") else 0o100644) << 16
            archive.writestr(entry, (ROOT / name).read_bytes())
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        assert len(archive.namelist()) == len(FILES)
    print(output)


if __name__ == "__main__":
    build()
