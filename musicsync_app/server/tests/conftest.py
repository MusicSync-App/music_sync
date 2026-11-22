import io
import json
import os
import sys

import pytest
from fastapi.testclient import TestClient
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import Settings, create_app  # noqa: E402
from storage import MemoryStorage  # noqa: E402

CONTENT = "test-org/musicsync-content"
PENDING = "test-org/musicsync-pending"
APP = "test-org/music_sync"

TOKENS = {
    "tok-user": {"email": "User@Example.com", "email_verified": True},
    "tok-user2": {"email": "other@example.com", "email_verified": True},
    "tok-admin": {"email": "admin@example.com", "email_verified": True},
    "tok-unverified": {"email": "x@example.com", "email_verified": False},
}

USER = {"Authorization": "Bearer tok-user"}
USER2 = {"Authorization": "Bearer tok-user2"}
ADMIN = {"Authorization": "Bearer tok-admin"}


class FakeUserinfo:
    def __init__(self):
        self.calls = 0

    async def __call__(self, token):
        self.calls += 1
        return TOKENS.get(token)


def make_image(fmt="JPEG", size=(800, 600), color=(200, 30, 40), mode="RGB") -> bytes:
    img = Image.new(mode, size, color)
    buf = io.BytesIO()
    img.save(buf, fmt)
    return buf.getvalue()


@pytest.fixture
def storage():
    s = MemoryStorage()
    existing = {
        "version": 1,
        "updatedAt": "2026-01-01T00:00:00Z",
        "themes": [
            {"id": "c_ro", "builtin": False, "countryCode": "RO", "name": "România",
             "colorValue": 4294198070, "keywords": ["manele"],
             "photos": [{"path": "photos/" + "a" * 64 + ".jpg", "sha256": "a" * 64, "w": 10, "h": 10}],
             "updatedAt": "2026-01-01T00:00:00Z"},
        ],
    }
    s.seed(CONTENT, {"index.json": json.dumps(existing).encode(), "photos/" + "a" * 64 + ".jpg": b"old"})
    s.seed(PENDING, {"README.md": b"pending"})
    return s


@pytest.fixture
def userinfo():
    return FakeUserinfo()


@pytest.fixture
def settings():
    return Settings(content_repo=CONTENT, pending_repo=PENDING, app_repo=APP,
                    admin_emails={"admin@example.com"}, max_submissions_per_day=5)


@pytest.fixture
def client(storage, userinfo, settings):
    app = create_app(settings, storage, userinfo)
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c


def submit(client, meta, photos=(), headers=USER):
    files = [("photos", (f"p{i}.jpg", data, "image/jpeg")) for i, data in enumerate(photos)]
    return client.post("/api/submissions", data={"meta": json.dumps(meta)},
                       files=files or None, headers=headers)


def content_index(storage):
    return json.loads(storage.files(CONTENT)["index.json"])
