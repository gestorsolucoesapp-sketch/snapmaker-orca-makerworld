import asyncio
import hashlib
import io
import json
from uuid import uuid4

import pytest

from usb_sync import import_one


class FakePhone:
    def __init__(self, payload):
        self.payload = io.BytesIO(payload)
        self.written = {}

    async def fopen(self, path):
        return 1

    async def fread(self, handle, size):
        return self.payload.read(size)

    async def fclose(self, handle):
        pass

    async def set_file_contents(self, path, data):
        self.written[path] = json.loads(data)


def test_cable_copy_only_acknowledges_matching_bytes(tmp_path):
    payload = b"original-photo-bytes"
    identifier = str(uuid4()).upper()
    manifest = {"id": identifier, "fileName": f"{identifier}.jpg", "name": "IMG_001.jpg",
                "size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
    phone = FakePhone(payload)
    receipt = asyncio.run(import_one(phone, manifest, tmp_path))
    assert (tmp_path / receipt["folder"] / "IMG_001.jpg").read_bytes() == payload
    assert phone.written[f"/Documents/CableQueue/{identifier}.receipt.json"]["sha256"] == manifest["sha256"]
    assert not list(tmp_path.rglob("*.partial"))


def test_cable_copy_rejects_wrong_checksum_without_receipt(tmp_path):
    identifier = str(uuid4()).upper()
    manifest = {"id": identifier, "fileName": f"{identifier}.jpg", "name": "IMG_001.jpg",
                "size": 5, "sha256": hashlib.sha256(b"other").hexdigest()}
    phone = FakePhone(b"photo")
    with pytest.raises(IOError, match="checksum"):
        asyncio.run(import_one(phone, manifest, tmp_path))
    assert not any("receipt.json" in path for path in phone.written)
    assert not list(tmp_path.rglob("*.partial"))
