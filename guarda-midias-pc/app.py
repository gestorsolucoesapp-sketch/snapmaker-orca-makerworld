"""Private iPhone media receiver. Never deletes media from the phone."""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import asyncio
from datetime import datetime
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse


APP_DIR = Path(__file__).resolve().parent
STATIC_DIR = APP_DIR / "static"
BACKUP_DIR = Path(os.environ.get("MEDIA_BACKUP_DIR", r"D:\Backup-Midias-iPhone"))
TOKEN_FILE = BACKUP_DIR / ".access-token"
MAX_FILE_SIZE = 8 * 1024**3
ALLOWED_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".gif",
    ".mp4", ".mov", ".m4v", ".avi",
}
commit_lock = asyncio.Lock()


def access_token() -> str:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    if not TOKEN_FILE.exists():
        TOKEN_FILE.write_text(secrets.token_urlsafe(32), encoding="utf-8")
    return TOKEN_FILE.read_text(encoding="utf-8").strip()


def safe_name(raw: str) -> str:
    name = Path(raw.replace("\\", "/")).name
    name = re.sub(r"[^\w.() -]", "_", name, flags=re.UNICODE).strip(" .")
    if not name or name.startswith(".") or len(name) > 180:
        raise HTTPException(400, "Nome de arquivo inválido")
    if Path(name).suffix.lower() not in ALLOWED_EXTENSIONS:
        raise HTTPException(400, "Escolha uma foto ou um vídeo")
    return name


def require_token(request: Request) -> None:
    provided = request.headers.get("x-media-token", "")
    if not secrets.compare_digest(provided, access_token()):
        raise HTTPException(401, "Acesso não autorizado")


def available_name(folder: Path, name: str, digest: str) -> tuple[Path, bool]:
    stem, ext = Path(name).stem, Path(name).suffix
    candidate = folder / name
    count = 2
    while candidate.exists():
        if candidate.is_file() and hash_file(candidate) == digest:
            return candidate, True
        candidate = folder / f"{stem} ({count}){ext}"
        count += 1
    return candidate, False


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


app = FastAPI(title="Guarda Mídias")


@app.get("/")
def home() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/manifest.webmanifest")
def manifest() -> FileResponse:
    return FileResponse(STATIC_DIR / "manifest.webmanifest", media_type="application/manifest+json")


@app.get("/sw.js")
def service_worker() -> FileResponse:
    return FileResponse(STATIC_DIR / "sw.js", media_type="application/javascript")


@app.get("/icon.svg")
def icon() -> FileResponse:
    return FileResponse(STATIC_DIR / "icon.svg", media_type="image/svg+xml")


@app.get("/exifr-lite.umd.js")
def exifr_script() -> FileResponse:
    return FileResponse(STATIC_DIR / "exifr-lite.umd.js", media_type="application/javascript")


@app.get("/api/files")
def files(request: Request) -> JSONResponse:
    require_token(request)
    items = []
    for path in BACKUP_DIR.rglob("*"):
        if path.is_file() and path.suffix.lower() in ALLOWED_EXTENSIONS:
            stat = path.stat()
            items.append({"name": path.name, "folder": str(path.parent.relative_to(BACKUP_DIR)),
                          "size": stat.st_size, "modified": stat.st_mtime})
    items.sort(key=lambda item: item["modified"], reverse=True)
    return JSONResponse({"files": items, "total_bytes": sum(item["size"] for item in items)})


@app.put("/api/upload")
async def upload(request: Request, name: str) -> JSONResponse:
    require_token(request)
    filename = safe_name(name)
    date_folder = BACKUP_DIR / datetime.now().strftime("%Y-%m-%d")
    date_folder.mkdir(parents=True, exist_ok=True)
    temp = date_folder / f".{secrets.token_hex(16)}.partial"
    digest = hashlib.sha256()
    size = 0
    try:
        with temp.open("xb") as out:
            async for chunk in request.stream():
                size += len(chunk)
                if size > MAX_FILE_SIZE:
                    raise HTTPException(413, "Arquivo acima do limite de 8 GB")
                out.write(chunk)
                digest.update(chunk)
            out.flush()
            os.fsync(out.fileno())
        if size == 0:
            raise HTTPException(400, "Arquivo vazio")
        async with commit_lock:
            target, duplicate = available_name(date_folder, filename, digest.hexdigest())
            if not duplicate:
                temp.replace(target)
            receipt = {"name": target.name, "folder": date_folder.name, "size": size,
                       "sha256": digest.hexdigest(), "duplicate": duplicate}
            with (BACKUP_DIR / "comprovantes.jsonl").open("a", encoding="utf-8") as log:
                log.write(json.dumps(receipt, ensure_ascii=False) + "\n")
        return JSONResponse(receipt)
    finally:
        temp.unlink(missing_ok=True)
