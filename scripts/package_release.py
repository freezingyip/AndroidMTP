#!/usr/bin/env python3
"""Package an already-built app and verified dependency sources for GitHub."""
import hashlib
import json
import plistlib
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build/AndroidMTP.app"


def run(*args):
    subprocess.run(args, check=True)


def main():
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    output = ROOT / "build/release" / f"v{version}"
    sources = output / "dependency-sources"
    dependencies = json.loads((ROOT / "docs/dependencies.json").read_text())
    for dependency in dependencies:
        path = sources / dependency["archive"]
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != dependency["sha256"]:
            raise SystemExit(f"Download the verified corresponding source: {dependency['url']} → {path}")
        if not (sources / f"{dependency['name']}-homebrew.rb").is_file():
            raise SystemExit("Include the Homebrew build formulas matching the bundled libraries.")
    stage = output / "stage"
    stage.mkdir(exist_ok=True)
    staged_app = stage / APP.name
    if staged_app.exists():
        shutil.rmtree(staged_app)
    run("/usr/bin/ditto", "--norsrc", str(APP), str(staged_app))
    resources = staged_app / "Contents/Resources"
    shutil.copy2(ROOT / "LICENSE", resources / "LICENSE.txt")
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", resources / "ThirdPartyLicenses/THIRD_PARTY_NOTICES.md")
    shutil.copy2(ROOT / "docs/DEPENDENCIES.md", resources / "ThirdPartyLicenses/DEPENDENCIES.md")
    for library in (staged_app / "Contents/Frameworks").iterdir():
        run("/usr/bin/codesign", "--force", "--sign", "-", str(library))
    run("/usr/bin/codesign", "--force", "--sign", "-", str(staged_app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(staged_app))
    arch = subprocess.check_output(["/usr/bin/lipo", "-archs", str(staged_app / "Contents/MacOS/AndroidMTP")], text=True).strip().replace(" ", "-")
    app_archive = output / f"AndroidMTP-{version}-macOS-{arch}.zip"
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(staged_app), str(app_archive))
    source_archive = output / f"AndroidMTP-{version}-dependency-sources.zip"
    with zipfile.ZipFile(source_archive, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(sources.iterdir()):
            archive.write(path, f"dependency-sources/{path.name}")
        for path in [ROOT / "docs/DEPENDENCIES.md", ROOT / "docs/dependencies.json", *sorted((ROOT / "licenses").iterdir())]:
            archive.write(path, f"dependency-sources/{path.name}")
    checksums = output / "SHA256SUMS.txt"
    checksums.write_text("".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in [app_archive, source_archive]))
    print(f"Prepared {app_archive.name}, {source_archive.name}, and {checksums.name}")


if __name__ == "__main__":
    main()
