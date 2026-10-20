#!/usr/bin/env python3
import hashlib
from pathlib import Path
import sys
import zipfile


EXPECTED_SHA256 = "79baabda41248efe06a3e401ae137f34ce8a20b73db6f76c9039ff9c6b673f92"


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 scripts/import-tda-model.py <author-original.zip>")

    archive = Path(sys.argv[1]).expanduser()
    if hashlib.sha256(archive.read_bytes()).hexdigest() != EXPECTED_SHA256:
        raise SystemExit("Expected the original Tda classic-outfit v1.1 ZIP from https://bowlroll.net/file/16344")

    destination = Path(__file__).resolve().parent.parent / "Wallpaper/assets/companion-model/tda"
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            name = entry.filename
            if not entry.flag_bits & 0x800:
                name = name.encode("cp437").decode("cp932")
            relative = Path(name)
            if len(relative.parts) != 2 or entry.is_dir():
                continue
            if relative.suffix.lower() not in {".pmx", ".tga", ".bmp", ".png", ".txt"}:
                continue
            filename = "miku.pmx" if relative.suffix.lower() == ".pmx" else relative.name
            (destination / filename).write_bytes(bundle.read(entry))

    print("Tda model imported for local use. Keep the author's readmes with the model; do not redistribute the original assets.")


if __name__ == "__main__":
    main()
