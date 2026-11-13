#!/usr/bin/env python3
"""Stage the approved author-original Tda V4X assets inside a free app bundle."""

import argparse
import hashlib
import io
from pathlib import Path
import sys
import zipfile


ARCHIVE_NAME = "Tda式初音ミクV4X_Ver1.00.zip"
EXPECTED_SHA256 = "c7036712a1168a1558f61c1256a61c94574878451e02e8a0b6fb8ef945c6bfba"
MAX_ARCHIVE_BYTES = 12 * 1_024 * 1_024
ROOT = "Tda式初音ミクV4X_Ver1.00"
PMX_NAME = "Tda式初音ミクV4X_Ver1.00.pmx"
NOTICE_NAMES = ("AL注意点.jpg", "readme_English.txt", "よんでね.txt")
RUNTIME_TEXTURES = (
    "body00_s.bmp",
    "body01_s.bmp",
    "body02_MikuAp.tga",
    "face_Mikuv4x.tga",
    "hair_Mikuv4x.tga",
    "hair_s.bmp",
    "mikuv4x_body00.tga",
    "skin_s.bmp",
    "toon_defo.bmp",
    "toon_hair.bmp",
    "toon_skin.bmp",
)
EXPECTED_FILES = {
    f"{ROOT}/AL注意点.jpg": "c247b9a0197fa38cb608171062bccb83b7040a6a3fcbebcfa83acb5e347041d0",
    f"{ROOT}/readme_English.txt": "2b60489ff596b841683a8d0ba48d99e1568ef4d2ce7c4cf9d95a389f338141d1",
    f"{ROOT}/{PMX_NAME}": "a3876a152b456d4d4e99b2b8fbb7d87c5308c0ad0c624b3163a7dc84dcbaca77",
    f"{ROOT}/tex/body00_s.bmp": "25d8d36c9a7e3ddfbbc35441ecf68ae37c42d43b58d47642ec498c050a228213",
    f"{ROOT}/tex/body00_s.psd": "e4cc6fdcfb8b3453b7f12e65a3572ed214402bd254749b1706e64ab1a28ba0e7",
    f"{ROOT}/tex/body01_s.bmp": "e5465509fac91d84daaad3e1405eca4bc8789f542967cd327ea1303885182449",
    f"{ROOT}/tex/body01_s.psd": "da72eb49802bd6a705177b5eb5bbee59fb019b07f8780e83ae4f052f46cebdb8",
    f"{ROOT}/tex/body02_MikuAp.tga": "5e397b2c3b46805e49f6d8c5a440aee9fafda9a83c08c53cee552dac35ecc80f",
    f"{ROOT}/tex/face_Mikuv4x.tga": "f529a3ec8762d86e290fa59c27f428bba710545139a92a2180727a8b6820158c",
    f"{ROOT}/tex/hair_Mikuv4x.tga": "0a365478a620ad11a8d5ed90d335ed4a339d69207fa8227575122762b2563c8b",
    f"{ROOT}/tex/hair_s.bmp": "84b32daa627d6835b50f81c6279d84a89f398fa645fc5f7b711435c935dcc95b",
    f"{ROOT}/tex/mikuv4x_body00.tga": "6a3af51aa02bef64d74cbcbd83189a8531a45fdbacb4625a598f83365de0da39",
    f"{ROOT}/tex/skin_s.bmp": "6c18e4b39e93baf450f9f964bf235cd392b4ed88c852c1c1f791338c5a12a1ce",
    f"{ROOT}/tex/skin_s.psd": "be611219f60d7fdc205e2ac75f47206a2c7a1e9a5e12ff05c69dee06c3ebdcd9",
    f"{ROOT}/tex/toon_defo.bmp": "b53e5b17c773069766ea785db52051c7e0d2c15971a6bffb15bdcef86b30ec15",
    f"{ROOT}/tex/toon_hair.bmp": "61297ea34a2b7f4a0239506ed801a58ea7747d31800316278491c14f04749dd6",
    f"{ROOT}/tex/toon_skin.bmp": "48b04e38f6a559f0ebdb748ea65addeafd529a988b0b9b3cddcdcdf7d7e8000f",
    f"{ROOT}/よんでね.txt": "6b7fe39fe4175cd4b25d1415d9494a30a51f8e0337edd91ac6e5b174d4c26141",
}


class PackagingError(Exception):
    pass


def decoded_name(entry):
    if entry.flag_bits & 0x800:
        return entry.filename
    return entry.filename.encode("cp437").decode("cp932")


def load_verified_files(archive):
    archive = Path(archive).expanduser()
    try:
        size = archive.stat().st_size
        if size <= 0 or size > MAX_ARCHIVE_BYTES:
            raise PackagingError("The V4X archive has an unexpected size.")
        data = archive.read_bytes()
    except OSError as error:
        raise PackagingError(f"Cannot read the V4X archive: {error}") from None
    if hashlib.sha256(data).hexdigest() != EXPECTED_SHA256:
        raise PackagingError("Expected the approved author-original Tda V4X Ver1.00 ZIP.")

    files = {}
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as bundle:
            for entry in bundle.infolist():
                if entry.is_dir():
                    continue
                name = decoded_name(entry)
                if name in files or name not in EXPECTED_FILES:
                    raise PackagingError("The V4X archive file list does not match the approved original.")
                contents = bundle.read(entry)
                if hashlib.sha256(contents).hexdigest() != EXPECTED_FILES[name]:
                    raise PackagingError(f"The V4X archive member failed verification: {name}")
                files[name] = contents
    except (OSError, UnicodeError, zipfile.BadZipFile, RuntimeError):
        raise PackagingError("The V4X archive could not be read safely.") from None
    if set(files) != set(EXPECTED_FILES):
        raise PackagingError("The V4X archive is incomplete.")
    return files


def stage_model(archive, destination):
    files = load_verified_files(archive)
    destination = Path(destination).expanduser().absolute()
    if destination.name != "tda-v4x" or destination.exists() or destination.is_symlink():
        raise PackagingError("The V4X staging destination must be a new tda-v4x directory.")
    destination.mkdir(parents=True)
    (destination / "tex").mkdir()
    (destination / "miku.pmx").write_bytes(files[f"{ROOT}/{PMX_NAME}"])
    for name in RUNTIME_TEXTURES:
        (destination / "tex" / name).write_bytes(files[f"{ROOT}/tex/{name}"])
    for name in NOTICE_NAMES:
        (destination / name).write_bytes(files[f"{ROOT}/{name}"])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", help=f"Approved author-original {ARCHIVE_NAME}")
    parser.add_argument("destination", help="New app-bundle tda-v4x directory")
    options = parser.parse_args(argv)
    try:
        stage_model(options.archive, options.destination)
    except PackagingError as error:
        print(f"V4X packaging failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified Tda V4X assets staged in {options.destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
