import asyncio
import base64
import json

import httpx
import pytest

from github_storage import API, GitHubStorage
from storage import RefConflict

REPO = "test-org/musicsync-content"


def make_storage(handler):
    client = httpx.AsyncClient(base_url=API, transport=httpx.MockTransport(handler),
                               headers={"Authorization": "Bearer secret"})
    return GitHubStorage("unused", client=client)


def run(coro):
    return asyncio.run(coro)


def test_commit_uses_git_data_api_in_one_commit():
    calls = []

    def handler(req: httpx.Request):
        calls.append((req.method, req.url.path))
        body = json.loads(req.content) if req.content else None
        p = req.url.path
        if p.endswith("/git/commits/parent1"):
            return httpx.Response(200, json={"tree": {"sha": "basetree"}})
        if p.endswith("/git/blobs"):
            assert body["encoding"] == "base64"
            return httpx.Response(201, json={"sha": "blob-" + base64.b64decode(body["content"]).decode()})
        if p.endswith("/git/trees"):
            assert body["base_tree"] == "basetree"
            entries = {e["path"]: e["sha"] for e in body["tree"]}
            assert entries == {"index.json": "blob-{}", "photos/a.jpg": "blob-A", "photos/old.jpg": None}
            return httpx.Response(201, json={"sha": "newtree"})
        if p.endswith("/git/commits"):
            assert body == {"message": "msg", "tree": "newtree", "parents": ["parent1"]}
            return httpx.Response(201, json={"sha": "newcommit"})
        if p.endswith("/git/refs/heads/main"):
            assert body == {"sha": "newcommit", "force": False}
            return httpx.Response(200, json={})
        raise AssertionError(p)

    s = make_storage(handler)
    sha = run(s.commit(REPO, "parent1", {"index.json": b"{}", "photos/a.jpg": b"A", "photos/old.jpg": None}, "msg"))
    assert sha == "newcommit"
    assert [c for c in calls if c[0] == "PATCH"] == [("PATCH", f"/repos/{REPO}/git/refs/heads/main")]


def test_ref_update_race_raises_conflict():
    def handler(req):
        p = req.url.path
        if "/git/commits/" in p:
            return httpx.Response(200, json={"tree": {"sha": "t"}})
        if p.endswith("/git/trees") or p.endswith("/git/commits") or p.endswith("/git/blobs"):
            return httpx.Response(201, json={"sha": "x"})
        return httpx.Response(422, json={"message": "Update is not a fast forward"})

    with pytest.raises(RefConflict):
        run(make_storage(handler).commit(REPO, "p", {"a": b"1"}, "m"))


def test_head_read_and_release_asset():
    def handler(req):
        p = req.url.path
        if p.endswith("/git/ref/heads/main"):
            return httpx.Response(200, json={"object": {"sha": "abc"}})
        if p.endswith("/contents/index.json"):
            assert req.url.params["ref"] == "abc"
            return httpx.Response(200, content=b"{\"version\":1}")
        if p.endswith("/contents/missing.json"):
            return httpx.Response(404, json={})
        if p.endswith("/releases/latest"):
            return httpx.Response(200, json={"assets": [
                {"name": "app-release.apk", "url": f"{API}/repos/o/r/releases/assets/1"},
                {"name": "version.json", "url": f"{API}/repos/o/r/releases/assets/2"}]})
        if p.endswith("/releases/assets/2"):
            assert req.headers["accept"] == "application/octet-stream"
            return httpx.Response(200, content=b"{\"versionCode\":3}")
        raise AssertionError(p)

    s = make_storage(handler)
    assert run(s.get_head(REPO)) == "abc"
    assert run(s.read_file(REPO, "index.json", "abc")) == b"{\"version\":1}"
    assert run(s.read_file(REPO, "missing.json", "abc")) is None
    assert run(s.latest_release_asset("o/r", "version.json")) == b"{\"versionCode\":3}"


def test_empty_repo_and_no_release():
    def handler(req):
        p = req.url.path
        if p.endswith("/git/ref/heads/main"):
            return httpx.Response(409, json={"message": "Git Repository is empty."})
        if p.endswith("/releases/latest"):
            return httpx.Response(404, json={})
        if req.method == "PUT":
            return httpx.Response(201, json={})
        raise AssertionError(p)

    s = make_storage(handler)
    assert run(s.get_head(REPO)) is None
    assert run(s.latest_release_asset("o/r", "version.json")) is None
    with pytest.raises(RefConflict):  # initializes the repo, caller retries
        run(s.commit(REPO, None, {"a": b"1"}, "m"))
