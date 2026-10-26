#!/usr/bin/env python3
"""Create harmless, unique transfer fixtures locally; this does not access USB."""
import hashlib
import json
import secrets
import sys
from datetime import date
from pathlib import Path

base = Path(sys.argv[1]).resolve()
name = f"AndroidMTP-Test-{date.today():%Y%m%d}-{secrets.token_hex(3)}"
source = base / "upload" / name
(source / "nested").mkdir(parents=True)
(source / "empty-folder").mkdir()
(source / "hello.txt").write_text(
    "AndroidMTP local transfer verification.\nNo personal data.\n", encoding="utf-8"
)
(source / "nested" / "測試-📱.txt").write_text(
    "MTP file transfer: 中文 / café / 📱\n" * 300, encoding="utf-8"
)
(source / "sample.bin").write_bytes(bytes(range(256)) * (5 * 4096))
(source / "zero-byte.txt").write_bytes(b"")
manifest = {
    str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in source.rglob("*") if path.is_file()
}
(base / "manifest.json").write_text(
    json.dumps({"folder": name, "sha256": manifest}, ensure_ascii=False, indent=2),
    encoding="utf-8",
)
print(f"Prepared {len(manifest)} synthetic files in {source}")
