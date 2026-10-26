#!/usr/bin/env python3
"""Build a complete macOS icon from the committed square master artwork."""
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def build_icon():
    source = ROOT / "assets" / "AndroidMTP-Icon.png"
    if not source.is_file():
        raise SystemExit(f"Missing app icon artwork: {source}")
    output = ROOT / ".build" / "app-icon"
    iconset = output / "AndroidMTP.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    dimensions = subprocess.check_output(
        ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", str(source)], text=True
    )
    width = int(dimensions.split("pixelWidth: ")[1].splitlines()[0])
    height = int(dimensions.split("pixelHeight: ")[1].splitlines()[0])
    if width != height or width < 1024:
        raise SystemExit("App icon master must be square and at least 1024 pixels wide.")
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            suffix = "@2x" if scale == 2 else ""
            destination = iconset / f"icon_{points}x{points}{suffix}.png"
            subprocess.run([
                "/usr/bin/sips", "--resampleHeightWidth", str(pixels), str(pixels),
                str(source), "--out", str(destination)
            ], check=True, stdout=subprocess.DEVNULL)
    result = output / "AndroidMTP.icns"
    subprocess.run(["/usr/bin/iconutil", "--convert", "icns", "--output", str(result), str(iconset)], check=True)
    asset = ROOT / "assets" / "AndroidMTP.icns"
    shutil.copy2(result, asset)
    return asset


if __name__ == "__main__":
    print(build_icon())
