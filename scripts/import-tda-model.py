#!/usr/bin/env python3
"""Import the author's original Tda v1.1 model for this user's local installation."""

import argparse
import hashlib
from html.parser import HTMLParser
from http.cookiejar import CookieJar
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit, urlunsplit
from urllib.request import HTTPCookieProcessor, HTTPRedirectHandler, Request, build_opener
import zipfile
import webbrowser


AUTHOR_URL = "https://bowlroll.net/file/16344"
DOWNLOAD_CHECK_URL = "https://bowlroll.net/api/file/16344/download-check"
ARCHIVE_NAME = "Tda式デフォ服ミク_ver1.1.zip"
EXPECTED_SHA256 = "79baabda41248efe06a3e401ae137f34ce8a20b73db6f76c9039ff9c6b673f92"
MAX_ARCHIVE_BYTES = 12 * 1024 * 1024
OFFICIAL_HOSTS = {"bowlroll.net", "storage-file-download-common.bowlroll.cloud"}
ASSET_SHA256 = {
    'body00_s.bmp': 'ec4d2ba9b86638e91268fec13f7472934ce493748d2b810ca4602222b80d6ce7',
    'body01_s.bmp': '428847cb0a5038c576dbd754402973de3ba1e95a94c8c988dde78883d025db7a',
    'body02_MikuAp.tga': '5e397b2c3b46805e49f6d8c5a440aee9fafda9a83c08c53cee552dac35ecc80f',
    'hair_MikuAp.png': '1d215253ddc25ae9d6d1309bf3b6ea2a9f9a9b79d10c76a49bba14ccac25d37d',
    'hair_s.bmp': '84b32daa627d6835b50f81c6279d84a89f398fa645fc5f7b711435c935dcc95b',
    'k_Asi2.png': 'ea24137369a45963c052f94c0ba6f983e98cebbec286806fe344dde970cd5c33',
    'k_face_MikuAp.tga': '3da7bf0d5a62606f2e28344bab9bc69d64c05e90558fcdb487ff879e115308df',
    'k_Hada.png': '45b45a939c17f98cf6dc4eebb1ea128c1b336e2428d0f9906a91eaba2dc3ea2b',
    'k_hika.png': '00893ed908c3a132829fc95fdc437f3a165b3953334c0a08ee63525aeea6a619',
    'k_huku1.png': '640e14bb2935cc814f403aa2271e9f7342df5ec55ce75672f9181a858e74454f',
    'k_huku2.png': '440c6f705d33c92edba20539a8ff922efd5e737e934eb47ac06d4b61ec6f4797',
    'ReadMe_Tda.txt': '5b732de972eb58d258bd5294c2a2c9927d26931961b414130131ab248ddf9fb6',
    'ReadMe_Tda_English.txt': '62ccff079e89a2e8e1ec073aefcc3c57da37012742495021ccc79abd490dbf20',
    'ReadMe_金子卵黄.txt': '12594f475d34935cd4a40f4061dbab05783b19a5dbb03f4e3aab4b9e47616d3d',
    'skin_s.bmp': '009219d37c409d1b496e94897343e85af8ff03162bcdb0ee90b859a5708a3ab1',
    'miku.pmx': '7ef24d4d43eba55b2125f62c69edb674bab61e835df7c0f2cd03b94572498966',
    'toon_defo.bmp': '5df98b15c19816f9f8701a4e1cb8c568879285a6a6340fee84a4fb8b87e4f6ea',
    'toon_hair.bmp': '61297ea34a2b7f4a0239506ed801a58ea7747d31800316278491c14f04749dd6',
    'toon_skin.bmp': '48b04e38f6a559f0ebdb748ea65addeafd529a988b0b9b3cddcdcdf7d7e8000f',
}


class ModelSetupError(Exception):
    pass


def archive_error():
    return ModelSetupError(f"Expected the original Tda v1.1 ZIP from {AUTHOR_URL}.")


def checked_archive(data):
    if not data or len(data) > MAX_ARCHIVE_BYTES or hashlib.sha256(data).hexdigest() != EXPECTED_SHA256:
        raise archive_error()
    return data


def read_bounded(stream, maximum):
    data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ModelSetupError("The author response exceeds the allowed download size.")
    return data


def official_url(value):
    parts = urlsplit(value)
    if (parts.scheme != "https" or parts.hostname not in OFFICIAL_HOSTS
            or parts.username or parts.password or parts.port not in (None, 443)):
        raise ModelSetupError("The author download redirected outside its official hosts.")
    return urlunsplit((parts.scheme, parts.netloc, quote(parts.path, safe="/%"), parts.query, parts.fragment))


class OfficialRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return super().redirect_request(request, response, code, message, headers, official_url(new_url))


class AuthorPage(HTMLParser):
    def __init__(self):
        super().__init__()
        self.configuration = None

    def handle_starttag(self, tag, attributes):
        values = dict(attributes)
        if tag == "div" and values.get("id") == "initialize":
            self.configuration = values


def download_archive(opener=None):
    opener = opener or build_opener(HTTPCookieProcessor(CookieJar()), OfficialRedirects())
    headers = {"User-Agent": "MikuDesktop-ModelSetup/1.0", "Referer": AUTHOR_URL}
    try:
        with opener.open(Request(AUTHOR_URL, headers=headers), timeout=30) as response:
            page = AuthorPage()
            page.feed(read_bounded(response, 2 * 1024 * 1024).decode("utf-8"))
        config = page.configuration or {}
        if (config.get("data-download_control") != "permission"
                or config.get("data-download_key") != "false" or not config.get("data-csrf_token")):
            raise ModelSetupError("The author page requires an interactive download or its download flow has changed.")
        body = urlencode({
            "download_key": "bowlroll_download_control_mischievous",
            "csrf_token": config["data-csrf_token"],
        }).encode("utf-8")
        request = Request(DOWNLOAD_CHECK_URL, data=body, headers={
            **headers, "Origin": "https://bowlroll.net", "X-Requested-With": "XMLHttpRequest",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        })
        with opener.open(request, timeout=30) as response:
            result = json.loads(read_bounded(response, 64 * 1024))
        if not isinstance(result, dict) or result.get("status") != "success" or not isinstance(result.get("url"), str):
            raise ModelSetupError("The author download needs permission, sign-in, or verification.")
        with opener.open(Request(official_url(result["url"]), headers=headers), timeout=30) as response:
            data = read_bounded(response, MAX_ARCHIVE_BYTES)
        return checked_archive(data)
    except (HTTPError, URLError, TimeoutError, UnicodeError, ValueError) as error:
        # Requests may contain short-lived author URLs or CSRF values. Keep those out of logs.
        status = f" (HTTP {error.code})" if isinstance(error, HTTPError) else ""
        if isinstance(error, HTTPError):
            error.close()
        raise ModelSetupError("The original author download is currently unavailable" + status + ".") from None


def is_ready(destination):
    destination = Path(destination)
    try:
        return all(
            not (destination / name).is_symlink()
            and hashlib.sha256((destination / name).read_bytes()).hexdigest() == expected
            for name, expected in ASSET_SHA256.items()
        )
    except OSError:
        return False


def import_bytes(data, destination):
    checked_archive(data)
    destination = Path(destination).expanduser().absolute()
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink() or destination.exists() and not destination.is_dir():
        raise ModelSetupError("The model destination must be a real directory.")
    with tempfile.TemporaryDirectory(prefix=".tda-import-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "model"
        staged.mkdir()
        with zipfile.ZipFile(io.BytesIO(data)) as bundle:
            for entry in bundle.infolist():
                if entry.is_dir():
                    continue
                name = entry.filename
                if not entry.flag_bits & 0x800:
                    name = name.encode("cp437").decode("cp932")
                relative = Path(name)
                if len(relative.parts) != 2 or relative.parts[0] != "Tda式デフォ服ミク_ver1.1":
                    raise archive_error()
                filename = "miku.pmx" if relative.suffix.lower() == ".pmx" else relative.name
                if filename not in ASSET_SHA256:
                    raise archive_error()
                (staged / filename).write_bytes(bundle.read(entry))
        if not is_ready(staged) or set(item.name for item in staged.iterdir()) != set(ASSET_SHA256):
            raise archive_error()
        previous = destination.parent / (Path(temporary).name + "-previous")
        replacing = destination.exists()
        if replacing:
            os.replace(destination, previous)
        try:
            os.replace(staged, destination)
        except OSError:
            if replacing:
                os.replace(previous, destination)
            raise
        if replacing:
            shutil.rmtree(previous)
    return destination


def import_archive(archive, destination):
    with Path(archive).expanduser().open("rb") as stream:
        return import_bytes(read_bounded(stream, MAX_ARCHIVE_BYTES), destination)


def wait_for_author_archive(downloads, timeout=180):
    print(f"Complete the download on the author's page: {AUTHOR_URL}")
    print(f"Waiting up to {timeout} seconds for the original ZIP in {downloads}.")
    try:
        opened = webbrowser.open(AUTHOR_URL)
    except webbrowser.Error:
        opened = False
    if not opened:
        raise ModelSetupError("Could not open the author's page. Download the original ZIP and supply its path.")
    deadline = time.monotonic() + timeout
    seen = {}
    while time.monotonic() < deadline:
        for candidate in downloads.glob(f"{Path(ARCHIVE_NAME).stem}*.zip"):
            try:
                stat = candidate.stat()
                signature = (stat.st_size, stat.st_mtime_ns)
                if seen.get(candidate) == signature:
                    continue
                seen[candidate] = signature
                with candidate.open("rb") as stream:
                    checked_archive(read_bounded(stream, MAX_ARCHIVE_BYTES))
                return candidate
            except (OSError, ModelSetupError):
                continue
        time.sleep(1)
    raise ModelSetupError("No verified original ZIP was downloaded. Run again with the downloaded ZIP path.")


def configure(destination, archive=None, downloads=None, opener=None, allow_browser=False):
    if archive is not None:
        imported = import_archive(archive, destination)
        print("Imported the supplied author-original Tda ZIP.")
        return imported
    if is_ready(destination):
        print("Verified the existing Tda model; no download needed.")
        return Path(destination)
    downloads = Path(downloads) if downloads is not None else Path.home() / "Downloads"
    candidate = downloads / ARCHIVE_NAME
    if candidate.is_file():
        try:
            imported = import_archive(candidate, destination)
            print("Reused the verified author-original ZIP in Downloads.")
            return imported
        except ModelSetupError:
            pass
    print(f"Obtaining the original Tda ZIP from {AUTHOR_URL}")
    try:
        data = download_archive(opener=opener)
    except ModelSetupError as error:
        if not allow_browser:
            raise
        print(error)
        return import_archive(wait_for_author_archive(downloads), destination)
    return import_bytes(data, destination)


def installed_app(candidate=None):
    if sys.platform != "darwin":
        raise ModelSetupError("Automatic application is supported on macOS. Use --destination to import files elsewhere.")
    candidates = ([Path(candidate).expanduser()] if candidate is not None else [
        Path("/Applications/Miku Desktop.app"), Path.home() / "Applications/Miku Desktop.app",
    ])
    for app in candidates:
        try:
            with (app / "Contents/Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            if (isinstance(info, dict) and info.get("CFBundleIdentifier") == "com.qimake.MikuDesktop"
                    and info.get("CFBundleExecutable") == "MikuDesktop"
                    and (app / "Contents/MacOS/MikuDesktop").is_file()):
                return app.resolve()
        except (OSError, ValueError, plistlib.InvalidFileException):
            continue
    raise ModelSetupError("Install Miku Desktop first, or use --app /path/to/Miku\\ Desktop.app to select it.")


def apply_model(app):
    # A fresh instance asks the existing app to save and quit before taking its place.
    try:
        subprocess.run(["/usr/bin/open", "-n", str(app), "--args", "--select-tda-classic"], check=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        raise ModelSetupError("The model was imported, but Miku Desktop could not be reopened. Open the app again to apply it.") from None
    print(f"Requested reopening Miku Desktop to apply the verified Tda model: {app}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", nargs="?", help="Author-original ZIP; otherwise reuse Downloads or obtain it from the author")
    location = parser.add_mutually_exclusive_group()
    location.add_argument("--user", action="store_true", help="Configure this user's installed app instead of a source-tree model")
    location.add_argument("--destination", type=Path, help="Use a specific model directory")
    parser.add_argument("--apply", action="store_true", help="Download, import and reopen the installed macOS app with Tda (implies --user)")
    parser.add_argument("--app", type=Path, help="Installed Miku Desktop.app to reopen with --apply")
    parser.add_argument("--no-browser", action="store_true", help="Do not open the author page if an automatic download is unavailable")
    parser.add_argument("--verify", action="store_true", help="Verify all installed model assets without changing or downloading files")
    options = parser.parse_args(argv)
    if options.apply and (options.destination is not None or options.verify):
        parser.error("--apply cannot be combined with --destination or --verify")
    if options.app is not None and not options.apply:
        parser.error("--app requires --apply")
    destination = options.destination
    if destination is None:
        destination = (Path.home() / "Library/Application Support/MikuDesktop/CharacterModels/tda" if options.user or options.apply
                       else Path(__file__).resolve().parent.parent / "Wallpaper/assets/companion-model/tda")
    try:
        app = installed_app(options.app) if options.apply else None
        if options.verify:
            if not is_ready(destination):
                raise ModelSetupError("The Tda model has not been completely configured.")
        else:
            configure(destination, archive=options.archive, allow_browser=options.apply and not options.no_browser)
        print(f"Tda v1.1 ready: {destination}")
        if app is not None:
            apply_model(app)
    except (ModelSetupError, OSError, zipfile.BadZipFile) as error:
        recovery = (f'python3 "{Path(__file__).resolve()}" --apply <author-original.zip>' if options.apply
                    else "./scripts/install-app.sh --tda-archive <author-original.zip>")
        if options.apply and options.app is not None:
            recovery += f' --app "{options.app}"'
        print(f"Tda setup failed: {error}\nObtain the author's original ZIP at {AUTHOR_URL}, then run {recovery}.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
