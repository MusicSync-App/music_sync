import hashlib
import io
import json

import pytest
from PIL import Image

from conftest import (ADMIN, APP, CONTENT, PENDING, USER, USER2, content_index, make_image,
                      submit)

COUNTRY_META = {"kind": "country", "countryCode": "MD", "name": "Moldova",
                "colorValue": 4280391411, "keywords": ["muzica moldoveneasca", "hore"]}


def approve(client, sub_id, body=None):
    if body is None:
        return client.post(f"/api/admin/submissions/{sub_id}/approve", headers=ADMIN)
    return client.post(f"/api/admin/submissions/{sub_id}/approve", headers=ADMIN, json=body)


# ------------------------------------------------------------------ health / manifest
def test_health(client):
    assert client.get("/health").json() == {"ok": True}


def test_manifest_with_release(client, storage):
    version = {"versionCode": 2, "versionName": "1.1.0",
               "apkUrl": f"https://github.com/{APP}/releases/download/v1.1.0+2/app-release.apk",
               "sha256": "ab" * 32, "size": 123, "notes": "Noutăți", "minSupported": 1,
               "publishedAt": "2026-11-01T00:00:00Z"}
    storage.releases[APP] = {"version.json": json.dumps(version).encode(), "app-release.apk": b"x"}
    r = client.get("/api/manifest")
    assert r.status_code == 200
    body = r.json()
    assert body["app"] == version
    head = storage.repos[CONTENT]["head"]
    assert body["content"] == {
        "revision": head,
        "indexUrl": f"https://raw.githubusercontent.com/{CONTENT}/{head}/index.json",
        "baseUrl": f"https://raw.githubusercontent.com/{CONTENT}/{head}/",
    }


def test_manifest_without_release_and_cache(client, storage):
    r = client.get("/api/manifest").json()
    assert r["app"] is None
    first = r["content"]["revision"]
    storage.seed(CONTENT, {"x.txt": b"1"})  # external change: cached for 5 min
    assert client.get("/api/manifest").json()["content"]["revision"] == first


def test_manifest_invalidated_after_content_change(client, storage):
    before = client.get("/api/manifest").json()["content"]["revision"]
    r = client.delete("/api/admin/themes/c_ro", headers=ADMIN)
    assert r.status_code == 200
    after = client.get("/api/manifest").json()["content"]["revision"]
    assert after == r.json()["revision"] != before


# ------------------------------------------------------------------ auth
def test_auth_missing_token(client):
    r = client.get("/api/me")
    assert r.status_code == 401
    assert r.json()["error"] == "unauthorized"
    assert "message" in r.json()


@pytest.mark.parametrize("header", ["Bearer nope", "Basic tok-user", "Bearer ", "Bearer tok-unverified"])
def test_auth_bad_token(client, header):
    assert client.get("/api/me", headers={"Authorization": header}).status_code == 401


def test_me_and_cache(client, userinfo):
    r = client.get("/api/me", headers=USER)
    assert r.json() == {"email": "user@example.com", "isAdmin": False}
    client.get("/api/me", headers=USER)
    assert userinfo.calls == 1  # cached by sha256(token)
    assert client.get("/api/me", headers=ADMIN).json()["isAdmin"] is True


@pytest.mark.parametrize("method,path", [
    ("get", "/api/admin/submissions"),
    ("get", "/api/admin/submissions/01ARZ3NDEKTSV4RRFFQ69G5FAV/photos/0"),
    ("post", "/api/admin/submissions/01ARZ3NDEKTSV4RRFFQ69G5FAV/approve"),
    ("post", "/api/admin/submissions/01ARZ3NDEKTSV4RRFFQ69G5FAV/reject"),
    ("delete", "/api/admin/themes/c_ro"),
    ("delete", "/api/admin/themes/c_ro/photos/" + "a" * 64),
])
def test_admin_endpoints_forbidden_for_users(client, method, path):
    assert getattr(client, method)(path, headers=USER).status_code == 403
    assert getattr(client, method)(path).status_code == 401


# ------------------------------------------------------------------ submission validation
def test_submit_requires_auth(client):
    assert submit(client, COUNTRY_META, headers={}).status_code == 401


@pytest.mark.parametrize("meta", [
    {"kind": "nope"},
    {"kind": "country", "countryCode": "md", "name": "Moldova", "colorValue": 1},
    {"kind": "country", "countryCode": "MDA", "name": "Moldova", "colorValue": 1},
    {"kind": "country", "countryCode": "MD", "name": "x" * 41, "colorValue": 1},
    {"kind": "country", "countryCode": "MD", "name": "   ", "colorValue": 1},
    {"kind": "country", "countryCode": "MD", "name": "Moldova", "colorValue": -1},
    {"kind": "country", "countryCode": "MD", "name": "Moldova", "colorValue": 2 ** 32},
    {"kind": "country", "countryCode": "MD", "name": "Moldova", "colorValue": "red"},
    {"kind": "country", "countryCode": "MD", "name": "Moldova", "colorValue": True},
    {"kind": "country", "countryCode": "MD", "name": "Moldova", "colorValue": 1, "keywords": ["a"] * 21},
    {"kind": "country", "countryCode": "MD", "name": "Moldova", "colorValue": 1, "keywords": ["k" * 41]},
    {"kind": "country", "countryCode": "MD", "name": "Moldova", "colorValue": 1, "keywords": "abc"},
    {"kind": "photos", "themeId": "../etc"},
    {"kind": "photos", "themeId": "Bad-Id"},
])
def test_submit_bad_meta(client, meta):
    r = submit(client, meta, [make_image()])
    assert r.status_code == 400, r.text
    assert r.json()["error"] == "invalid_meta"


def test_submit_meta_not_json(client):
    r = client.post("/api/submissions", data={"meta": "{nope"}, headers=USER)
    assert r.status_code == 400 and r.json()["error"] == "invalid_meta"
    r = client.post("/api/submissions", data={"x": "1"}, headers=USER)
    assert r.status_code == 400 and r.json()["error"] == "invalid_meta"
    assert client.post("/api/submissions", headers=USER).status_code == 400


def test_submit_photos_needs_photo(client):
    r = submit(client, {"kind": "photos", "themeId": "grecia"})
    assert r.status_code == 400 and r.json()["error"] == "no_photos"


def test_submit_photos_unknown_theme(client):
    r = submit(client, {"kind": "photos", "themeId": "c_zz"}, [make_image()])
    assert r.status_code == 400 and r.json()["error"] == "theme_not_found"


def test_submit_bad_image(client):
    r = submit(client, COUNTRY_META, [b"definitely not an image"])
    assert r.status_code == 400 and r.json()["error"] == "invalid_image"


def test_submit_truncated_image(client):
    data = make_image()
    r = submit(client, COUNTRY_META, [data[: len(data) // 2]])
    assert r.status_code == 400 and r.json()["error"] == "invalid_image"


def test_submit_unsupported_format(client):
    r = submit(client, COUNTRY_META, [make_image("GIF")])
    assert r.status_code == 400 and r.json()["error"] == "unsupported_format"


def test_submit_decompression_bomb(client):
    buf = io.BytesIO()
    Image.new("1", (12000, 12000)).save(buf, "PNG")  # 144 MP, tiny file
    assert len(buf.getvalue()) < 1024 * 1024
    r = submit(client, COUNTRY_META, [buf.getvalue()])
    assert r.status_code == 400 and r.json()["error"] == "image_too_large"


def test_submit_too_many_photos(client):
    img = make_image(size=(64, 64))
    r = submit(client, COUNTRY_META, [img] * 11)
    assert r.status_code == 400 and r.json()["error"] == "too_many_photos"


def test_submit_oversize_photo(client):
    big = make_image(size=(64, 64)) + b"\0" * (8 * 1024 * 1024)
    r = submit(client, COUNTRY_META, [big])
    assert r.status_code == 413 and r.json()["error"] == "photo_too_large"


def test_submit_body_too_large(client):
    r = client.post("/api/submissions", headers={**USER, "Content-Length": str(200 * 1024 * 1024),
                                                  "Content-Type": "multipart/form-data; boundary=x"},
                    content=b"")
    assert r.status_code == 413


def test_image_normalization(client, storage):
    # Tall PNG with alpha + EXIF-less; must come out as JPEG with long side 1600.
    png = make_image("PNG", size=(1000, 3000), color=(10, 20, 30, 128), mode="RGBA")
    r = submit(client, COUNTRY_META, [png])
    assert r.status_code == 201, r.text
    sid = r.json()["id"]
    stored = storage.files(PENDING)[f"submissions/{sid}/0.jpg"]
    img = Image.open(io.BytesIO(stored))
    assert img.format == "JPEG" and img.size == (533, 1600)
    assert "exif" not in img.info


def test_exif_rotation_and_strip(client, storage):
    img = Image.new("RGB", (400, 200), (1, 2, 3))
    exif = Image.Exif()
    exif[0x0112] = 6  # rotate 90 CW
    exif[0x010F] = "SecretCam"
    buf = io.BytesIO()
    img.save(buf, "JPEG", exif=exif.tobytes())
    r = submit(client, COUNTRY_META, [buf.getvalue()])
    sid = r.json()["id"]
    out = Image.open(io.BytesIO(storage.files(PENDING)[f"submissions/{sid}/0.jpg"]))
    assert out.size == (200, 400)
    assert not out.getexif()


# ------------------------------------------------------------------ rate limit
def test_rate_limit(client, storage, settings):
    for _ in range(settings.max_submissions_per_day):
        assert submit(client, COUNTRY_META).status_code == 201
    r = submit(client, COUNTRY_META)
    assert r.status_code == 429 and r.json()["error"] == "rate_limited"
    # Other users unaffected.
    assert submit(client, COUNTRY_META, headers=USER2).status_code == 201


def test_rate_limit_survives_restart(storage, userinfo, settings):
    from fastapi.testclient import TestClient

    from app import create_app

    with TestClient(create_app(settings, storage, userinfo)) as c:
        for _ in range(settings.max_submissions_per_day):
            assert submit(c, COUNTRY_META).status_code == 201
    # Fresh process: state rebuilt from the pending repo (createdAt of stored submissions).
    with TestClient(create_app(settings, storage, userinfo)) as c:
        assert submit(c, COUNTRY_META).status_code == 429


def test_rate_limit_window_is_24h(client, storage):
    metas = {}
    for i in range(5):
        sid = f"01ARZ3NDEKTSV4RRFFQ69G5FA{i}"
        metas[sid] = {"id": sid, "kind": "country", "submitterEmail": "user@example.com",
                      "createdAt": "2020-01-01T00:00:00Z", "status": "pending", "photos": []}
    storage.seed(PENDING, {"submissions.json": json.dumps({"submissions": list(metas.values())}).encode()})
    assert submit(client, COUNTRY_META).status_code == 201


# ------------------------------------------------------------------ full flows
def test_full_country_flow_merge(client, storage):
    meta = {"kind": "country", "countryCode": "RO", "name": "Romania Noua",
            "colorValue": 4278190335, "keywords": ["Manele", "lautareasca"]}
    photos = [make_image(size=(2000, 1000), color=(1, 2, 3)), make_image("WEBP", color=(9, 9, 9))]
    r = submit(client, meta, photos)
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["status"] == "pending"
    sid = body["id"]

    pending_head_commits = storage.commit_count
    files = storage.files(PENDING)
    assert f"submissions/{sid}/meta.json" in files
    assert f"submissions/{sid}/0.jpg" in files and f"submissions/{sid}/1.jpg" in files
    stored_meta = json.loads(files[f"submissions/{sid}/meta.json"])
    assert stored_meta["submitterEmail"] == "user@example.com"
    assert stored_meta["status"] == "pending" and stored_meta["createdAt"].endswith("Z")

    mine = client.get("/api/submissions/mine", headers=USER).json()
    assert [m["id"] for m in mine] == [sid] and mine[0]["status"] == "pending"
    assert client.get("/api/submissions/mine", headers=USER2).json() == []

    lst = client.get("/api/admin/submissions?status=pending", headers=ADMIN).json()
    assert len(lst) == 1
    item = lst[0]
    assert item["submitterEmail"] == "user@example.com"
    assert item["photoUrls"] == [f"/api/admin/submissions/{sid}/photos/0", f"/api/admin/submissions/{sid}/photos/1"]

    ph = client.get(item["photoUrls"][0], headers=ADMIN)
    assert ph.status_code == 200 and ph.headers["content-type"] == "image/jpeg"
    assert Image.open(io.BytesIO(ph.content)).size == (1600, 800)
    assert client.get(f"/api/admin/submissions/{sid}/photos/5", headers=ADMIN).status_code == 404

    r = approve(client, sid)
    assert r.status_code == 200, r.text
    assert r.json()["ok"] is True
    assert r.json()["revision"] == storage.repos[CONTENT]["head"]
    assert storage.commit_count == pending_head_commits + 2  # one content commit + one pending commit

    idx = content_index(storage)
    assert [t["id"] for t in idx["themes"]] == ["c_ro"]  # merged, not duplicated
    t = idx["themes"][0]
    assert t["name"] == "România" and t["colorValue"] == 4294198070  # existing look kept
    assert t["keywords"] == ["manele", "lautareasca"]  # case-insensitive union
    assert len(t["photos"]) == 3
    content_files = storage.files(CONTENT)
    for p in t["photos"][1:]:
        assert p["path"] == f"photos/{p['sha256']}.jpg"
        assert hashlib.sha256(content_files[p["path"]]).hexdigest() == p["sha256"]
    assert {(p["w"], p["h"]) for p in t["photos"][1:]} == {(1600, 800), (800, 600)}

    mine = client.get("/api/submissions/mine", headers=USER).json()
    assert mine[0]["status"] == "approved"
    assert client.get("/api/admin/submissions", headers=ADMIN).json() == []
    assert approve(client, sid).status_code == 409


def test_country_flow_new_theme_with_edits(client, storage):
    sid = submit(client, COUNTRY_META, [make_image()]).json()["id"]
    r = approve(client, sid, {"name": "Republica Moldova", "keywords": ["hore"]})
    assert r.status_code == 200, r.text
    t = next(t for t in content_index(storage)["themes"] if t["id"] == "c_md")
    assert t["builtin"] is False and t["countryCode"] == "MD"
    assert t["name"] == "Republica Moldova" and t["colorValue"] == COUNTRY_META["colorValue"]
    assert t["keywords"] == ["hore"]
    assert len(t["photos"]) == 1


def test_country_without_photos(client, storage):
    r = submit(client, COUNTRY_META)
    assert r.status_code == 201, r.text
    assert approve(client, r.json()["id"]).status_code == 200
    t = next(t for t in content_index(storage)["themes"] if t["id"] == "c_md")
    assert t["photos"] == []


def test_photos_flow_builtin_target(client, storage):
    sid = submit(client, {"kind": "photos", "themeId": "grecia"}, [make_image()]).json()["id"]
    assert approve(client, sid).status_code == 200
    t = next(t for t in content_index(storage)["themes"] if t["id"] == "grecia")
    assert t["builtin"] is True and t["countryCode"] == "GR" and t["name"] == "Grecia"
    assert t["colorValue"] is None and len(t["photos"]) == 1

    # Second batch (including a duplicate) appends to the same builtin entry.
    sid2 = submit(client, {"kind": "photos", "themeId": "grecia"},
                  [make_image(), make_image(color=(0, 255, 0))]).json()["id"]
    assert approve(client, sid2).status_code == 200
    idx = content_index(storage)
    assert [x["id"] for x in idx["themes"]].count("grecia") == 1
    assert len(next(t for t in idx["themes"] if t["id"] == "grecia")["photos"]) == 2


def test_photos_flow_builtin_with_space_id(client, storage):
    sid = submit(client, {"kind": "photos", "themeId": "central asia"}, [make_image()]).json()["id"]
    assert approve(client, sid).status_code == 200
    assert any(t["id"] == "central asia" for t in content_index(storage)["themes"])


def test_photos_flow_shared_target(client, storage):
    sid = submit(client, {"kind": "photos", "themeId": "c_ro"}, [make_image()]).json()["id"]
    assert approve(client, sid).status_code == 200
    t = content_index(storage)["themes"][0]
    assert t["id"] == "c_ro" and len(t["photos"]) == 2


def test_approve_retries_on_ref_conflict(client, storage):
    sid = submit(client, COUNTRY_META, [make_image()]).json()["id"]
    storage.fail_next_commits = 2
    r = approve(client, sid)
    assert r.status_code == 200, r.text
    assert any(t["id"] == "c_md" for t in content_index(storage)["themes"])


def test_reject_flow(client, storage):
    sid = submit(client, COUNTRY_META, [make_image()]).json()["id"]
    before = storage.repos[CONTENT]["head"]
    r = client.post(f"/api/admin/submissions/{sid}/reject", headers=ADMIN, json={"reason": "Poze neclare"})
    assert r.json() == {"ok": True}
    assert storage.repos[CONTENT]["head"] == before
    mine = client.get("/api/submissions/mine", headers=USER).json()
    assert mine[0]["status"] == "rejected" and mine[0]["reason"] == "Poze neclare"
    assert client.get("/api/admin/submissions?status=rejected", headers=ADMIN).json()[0]["id"] == sid
    assert approve(client, sid).status_code == 409
    assert client.post(f"/api/admin/submissions/{sid}/reject", headers=ADMIN, json={}).status_code == 409


def test_unknown_submission(client):
    assert approve(client, "01ARZ3NDEKTSV4RRFFQ69G5FAV").status_code == 404
    assert approve(client, "../../x").status_code == 404


# ------------------------------------------------------------------ deletes
def test_delete_photo_and_theme(client, storage):
    sid = submit(client, {"kind": "photos", "themeId": "c_ro"}, [make_image()]).json()["id"]
    approve(client, sid)
    t = content_index(storage)["themes"][0]
    new_sha = t["photos"][1]["sha256"]

    r = client.delete(f"/api/admin/themes/c_ro/photos/{new_sha}", headers=ADMIN)
    assert r.status_code == 200 and r.json()["ok"] is True
    assert r.json()["revision"] == storage.repos[CONTENT]["head"]
    assert f"photos/{new_sha}.jpg" not in storage.files(CONTENT)
    assert [p["sha256"] for p in content_index(storage)["themes"][0]["photos"]] == ["a" * 64]
    assert client.delete(f"/api/admin/themes/c_ro/photos/{new_sha}", headers=ADMIN).status_code == 404
    assert client.delete("/api/admin/themes/c_ro/photos/zzz", headers=ADMIN).status_code == 404

    r = client.delete("/api/admin/themes/c_ro", headers=ADMIN)
    assert r.status_code == 200
    assert content_index(storage)["themes"] == []
    assert "photos/" + "a" * 64 + ".jpg" not in storage.files(CONTENT)
    assert client.delete("/api/admin/themes/c_ro", headers=ADMIN).status_code == 404


def test_error_shape_for_unknown_route(client):
    r = client.get("/nope")
    assert r.status_code == 404 and set(r.json()) == {"error", "message"}
