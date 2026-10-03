"""Copy completed Guarda Mídias exports from a paired iPhone over USB.

The phone's original Photos assets are never removed by this process.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import secrets
import time
from datetime import datetime
from pathlib import Path

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService


BACKUP_DIR = Path(os.environ.get("MEDIA_BACKUP_DIR", r"D:\Backup-Midias-iPhone"))
BUNDLE_ID = os.environ.get("MEDIA_BUNDLE_ID", "com.gestorsolucoesapp.guardamidias.7DS8UWQ92T")
SERVER_URL = os.environ.get("MEDIA_SERVER_URL", "http://100.113.163.32:8765")
QUEUE = "/Documents/CableQueue"
CONNECTION_CONFIG = "/Library/Application Support/GuardaMidiasConnection.json"
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".gif",
                      ".mp4", ".mov", ".m4v", ".avi", ".dng", ".tif", ".tiff"}
MAX_SIZE = 8 * 1024**3


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_name(raw: str) -> str:
    name = Path(raw.replace("\\", "/")).name
    name = re.sub(r"[^\w.() -]", "_", name, flags=re.UNICODE).strip(" .")
    if not name or name.startswith(".") or len(name) > 180 or Path(name).suffix.lower() not in ALLOWED_EXTENSIONS:
        raise ValueError("Invalid media filename")
    return name


def validate_manifest(manifest: dict) -> tuple[str, str, int, str]:
    identifier = manifest.get("id", "")
    filename = manifest.get("fileName", "")
    digest = manifest.get("sha256", "")
    size = manifest.get("size")
    if not isinstance(identifier, str) or not re.fullmatch(r"[0-9A-Fa-f-]{36}", identifier):
        raise ValueError("Invalid transfer ID")
    if not isinstance(filename, str) or not re.fullmatch(re.escape(identifier) + r"\.[A-Za-z0-9]+", filename):
        raise ValueError("Invalid staged filename")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Invalid checksum")
    if not isinstance(size, int) or not 0 < size <= MAX_SIZE:
        raise ValueError("Invalid size")
    return identifier, safe_name(manifest.get("name", "")), size, digest


def destination(folder: Path, name: str, digest: str) -> tuple[Path, bool]:
    stem, extension = Path(name).stem, Path(name).suffix
    target = folder / name
    suffix = 2
    while target.exists():
        if target.is_file() and hash_file(target) == digest:
            return target, True
        target = folder / f"{stem} ({suffix}){extension}"
        suffix += 1
    return target, False


async def import_one(service: HouseArrestService, manifest: dict, backup_dir: Path = BACKUP_DIR) -> dict:
    identifier, name, size, digest = validate_manifest(manifest)
    remote = f"{QUEUE}/{manifest['fileName']}"
    folder = backup_dir / datetime.now().strftime("%Y-%m-%d")
    folder.mkdir(parents=True, exist_ok=True)
    partial = folder / f".{secrets.token_hex(16)}.partial"
    copied = 0
    started = time.monotonic()
    last_report = 0.0
    try:
        handle = await service.fopen(remote)
        try:
            actual_digest = hashlib.sha256()
            with partial.open("xb") as output:
                while copied < size:
                    chunk = await service.fread(handle, min(1024 * 1024, size - copied))
                    if not chunk:
                        raise IOError("USB transfer ended before the complete file arrived")
                    output.write(chunk)
                    actual_digest.update(chunk)
                    copied += len(chunk)
                    now = time.monotonic()
                    if now - last_report >= 1 or copied == size:
                        progress = {"bytes": copied, "total": size,
                                    "speed": copied / max(now - started, 0.1)}
                        await service.set_file_contents(
                            f"{QUEUE}/{identifier}.progress.json", json.dumps(progress).encode("utf-8"))
                        last_report = now
                output.flush()
                os.fsync(output.fileno())
        finally:
            await service.fclose(handle)
        if copied != size or actual_digest.hexdigest() != digest:
            raise IOError("USB copy failed checksum verification")
        target, duplicate = destination(folder, name, digest)
        if not duplicate:
            partial.replace(target)
        receipt = {"id": identifier, "name": target.name, "folder": folder.name,
                   "size": size, "sha256": digest, "duplicate": duplicate}
        with (backup_dir / "comprovantes-cabo.jsonl").open("a", encoding="utf-8") as log:
            log.write(json.dumps(receipt, ensure_ascii=False) + "\n")
            log.flush()
            os.fsync(log.fileno())
        await service.set_file_contents(
            f"{QUEUE}/{identifier}.receipt.json", json.dumps(receipt).encode("utf-8"))
        return receipt
    finally:
        partial.unlink(missing_ok=True)


async def sync_once() -> int:
    lockdown = await create_using_usbmux()
    async with await HouseArrestService.create(lockdown, BUNDLE_ID, documents_only=False) as service:
        token_file = BACKUP_DIR / ".access-token"
        if token_file.is_file():
            await service.makedirs("/Library/Application Support")
            config = {"serverURL": SERVER_URL, "accessCode": token_file.read_text(encoding="utf-8").strip()}
            await service.set_file_contents(CONNECTION_CONFIG, json.dumps(config).encode("utf-8"))
        if not await service.isdir(QUEUE):
            return 0
        names = await service.listdir(QUEUE)
        imported = 0
        for name in names:
            if not re.fullmatch(r"[0-9A-Fa-f-]{36}\.json", name):
                continue
            identifier = name[:-5]
            if f"{identifier}.receipt.json" in names:
                continue
            manifest = json.loads(await service.get_file_contents(f"{QUEUE}/{name}"))
            await import_one(service, manifest)
            imported += 1
        return imported


async def run_forever() -> None:
    last_error = ""
    while True:
        try:
            await sync_once()
            last_error = ""
        except Exception as error:
            message = f"{type(error).__name__}: {error}"
            if message != last_error:
                log_path = Path(__file__).resolve().parent / "usb-sync.log"
                with log_path.open("a", encoding="utf-8") as log:
                    log.write(f"{datetime.now().isoformat()} {message}\n")
                last_error = message
        await asyncio.sleep(3)


if __name__ == "__main__":
    asyncio.run(run_forever())
