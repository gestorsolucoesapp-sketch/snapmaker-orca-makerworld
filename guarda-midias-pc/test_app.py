import hashlib

from fastapi.testclient import TestClient

import app as module


def test_upload_is_private_verified_and_deduplicated(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "BACKUP_DIR", tmp_path)
    monkeypatch.setattr(module, "TOKEN_FILE", tmp_path / ".access-token")
    client = TestClient(module.app)
    assert client.get("/api/files").status_code == 401
    headers = {"x-media-token": module.access_token()}
    content = b"sample-photo-content"
    response = client.put("/api/upload?name=IMG_001.jpg", headers=headers, content=content)
    assert response.status_code == 200
    receipt = response.json()
    assert receipt["sha256"] == hashlib.sha256(content).hexdigest()
    assert (tmp_path / receipt["folder"] / receipt["name"]).read_bytes() == content
    assert client.put("/api/upload?name=IMG_001.jpg", headers=headers, content=content).json()["duplicate"]
    listing = client.get("/api/files", headers=headers).json()
    assert len(listing["files"]) == 1
    assert listing["total_bytes"] == len(content)


def test_rejects_non_media_and_empty_files(tmp_path, monkeypatch):
    monkeypatch.setattr(module, "BACKUP_DIR", tmp_path)
    monkeypatch.setattr(module, "TOKEN_FILE", tmp_path / ".access-token")
    client = TestClient(module.app)
    headers = {"x-media-token": module.access_token()}
    assert client.put("/api/upload?name=secret.txt", headers=headers, content=b"x").status_code == 400
    assert client.put("/api/upload?name=photo.jpg", headers=headers, content=b"").status_code == 400
    assert not list(tmp_path.rglob("*.partial"))
