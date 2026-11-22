"""GitHub implementation of the Storage protocol (REST + Git Data API).

Multi-file changes are written as ONE commit: blobs -> tree (on top of the parent tree) ->
commit -> fast-forward ref update. A non fast-forward ref update raises RefConflict so the
caller (storage.atomic_update) can rebuild and retry.
"""

from __future__ import annotations

import asyncio
import base64
import logging
from urllib.parse import quote

import httpx

from storage import Changes, RefConflict, StorageError

log = logging.getLogger("musicsync.github")

API = "https://api.github.com"


class GitHubStorage:
    def __init__(self, token: str, branch: str = "main", client: httpx.AsyncClient | None = None):
        self._branch = branch
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "musicsync-server",
        }
        if token:
            headers["Authorization"] = f"Bearer {token}"
        self._client = client or httpx.AsyncClient(
            base_url=API, headers=headers, timeout=httpx.Timeout(30.0, connect=10.0)
        )
        self._blob_sem = asyncio.Semaphore(4)

    async def aclose(self) -> None:
        await self._client.aclose()

    # ------------------------------------------------------------------ helpers
    async def _req(self, method: str, url: str, ok=(200, 201), **kw) -> httpx.Response:
        try:
            r = await self._client.request(method, url, **kw)
        except httpx.HTTPError as e:
            raise StorageError(f"GitHub request failed: {method} {url}: {type(e).__name__}") from e
        if r.status_code not in ok:
            # Never include request headers (token) in errors; body is GitHub's message only.
            raise StorageError(f"GitHub {method} {url} -> {r.status_code}: {r.text[:300]}")
        return r

    # ------------------------------------------------------------------ Storage
    async def get_head(self, repo: str) -> str | None:
        r = await self._req("GET", f"/repos/{repo}/git/ref/heads/{self._branch}", ok=(200, 404, 409))
        if r.status_code != 200:
            return None  # 404: no branch yet / 409: empty repository
        return r.json()["object"]["sha"]

    async def read_file(self, repo: str, path: str, ref: str) -> bytes | None:
        r = await self._req(
            "GET",
            f"/repos/{repo}/contents/{quote(path)}",
            params={"ref": ref},
            headers={"Accept": "application/vnd.github.raw+json"},
            ok=(200, 404),
        )
        if r.status_code == 404:
            return None
        return r.content

    async def _create_blob(self, repo: str, data: bytes) -> str:
        async with self._blob_sem:
            r = await self._req(
                "POST",
                f"/repos/{repo}/git/blobs",
                json={"content": base64.b64encode(data).decode("ascii"), "encoding": "base64"},
            )
        return r.json()["sha"]

    async def _init_empty_repo(self, repo: str) -> None:
        # The Git Data API does not work on a repository without commits; the Contents API does.
        await self._req(
            "PUT",
            f"/repos/{repo}/contents/README.md",
            json={
                "message": "Initialize repository",
                "content": base64.b64encode(b"# MusicSync data\n").decode("ascii"),
                "branch": self._branch,
            },
            ok=(200, 201, 422),
        )

    async def commit(self, repo: str, parent: str | None, changes: Changes, message: str) -> str:
        if parent is None:
            await self._init_empty_repo(repo)
            raise RefConflict("repository was empty; initialized, retry")

        r = await self._req("GET", f"/repos/{repo}/git/commits/{parent}")
        base_tree = r.json()["tree"]["sha"]

        items = list(changes.items())
        blob_shas = await asyncio.gather(
            *[self._create_blob(repo, data) for _, data in items if data is not None]
        )
        it = iter(blob_shas)
        tree = []
        for path, data in items:
            tree.append({"path": path, "mode": "100644", "type": "blob",
                         "sha": next(it) if data is not None else None})

        r = await self._req("POST", f"/repos/{repo}/git/trees", json={"base_tree": base_tree, "tree": tree})
        tree_sha = r.json()["sha"]
        r = await self._req(
            "POST", f"/repos/{repo}/git/commits",
            json={"message": message, "tree": tree_sha, "parents": [parent]},
        )
        commit_sha = r.json()["sha"]
        r = await self._req(
            "PATCH", f"/repos/{repo}/git/refs/heads/{self._branch}",
            json={"sha": commit_sha, "force": False},
            ok=(200, 409, 422),
        )
        if r.status_code != 200:
            raise RefConflict(f"ref update rejected ({r.status_code})")
        return commit_sha

    async def latest_release_asset(self, repo: str, asset_name: str) -> bytes | None:
        r = await self._req("GET", f"/repos/{repo}/releases/latest", ok=(200, 404))
        if r.status_code == 404:
            return None
        asset = next((a for a in r.json().get("assets", []) if a.get("name") == asset_name), None)
        if asset is None:
            return None
        # API asset URL works for private repos too; it redirects to a signed CDN URL
        # (httpx drops the Authorization header on the cross-origin redirect).
        r = await self._req(
            "GET", asset["url"],
            headers={"Accept": "application/octet-stream"},
            follow_redirects=True,
        )
        return r.content
