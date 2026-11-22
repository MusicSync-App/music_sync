"""Storage abstraction (git-repo-like) + in-memory fake + atomic read-modify-write helper.

The real implementation is `github_storage.GitHubStorage`. Everything else in the server only
talks to the `Storage` protocol, so tests can run against `MemoryStorage`.
"""

from __future__ import annotations

import hashlib
import itertools
from typing import Awaitable, Callable, Mapping, Protocol

# A change set: path -> new file bytes, or None to delete the file.
Changes = Mapping[str, "bytes | None"]


class StorageError(Exception):
    """Backend failure (network, GitHub 5xx, bad config...)."""


class RefConflict(StorageError):
    """The branch head moved between reading it and updating it (non fast-forward)."""


class Storage(Protocol):
    async def get_head(self, repo: str) -> str | None:
        """Commit sha of the main branch, or None if the repo is empty."""

    async def read_file(self, repo: str, path: str, ref: str) -> bytes | None:
        """File bytes at commit `ref`, or None if it does not exist."""

    async def commit(self, repo: str, parent: str | None, changes: Changes, message: str) -> str:
        """Create ONE commit on top of `parent` applying `changes` and move the branch to it.

        Raises RefConflict if the branch head is no longer `parent`. Returns the new commit sha.
        """

    async def latest_release_asset(self, repo: str, asset_name: str) -> bytes | None:
        """Bytes of asset `asset_name` of the latest (non-draft, non-prerelease) release, or None."""

    async def aclose(self) -> None: ...


async def atomic_update(
    storage: Storage,
    repo: str,
    message: str,
    build: Callable[[str | None], Awaitable[Changes]],
    retries: int = 3,
) -> tuple[str, str | None]:
    """Read-modify-write with optimistic concurrency.

    `build(head)` computes the change set from the repo state at `head`. If the ref update races
    with another writer, the head is re-read and `build` is called again (at most `retries` retries).
    Returns (new_head, old_head).
    """
    last: Exception | None = None
    for _ in range(retries + 1):
        head = await storage.get_head(repo)
        changes = await build(head)
        try:
            new_head = await storage.commit(repo, head, changes, message)
            return new_head, head
        except RefConflict as e:
            last = e
    raise StorageError(f"ref update kept conflicting on {repo}") from last


class MemoryStorage:
    """In-memory fake used by tests. Mirrors the GitHub semantics we rely on."""

    def __init__(self) -> None:
        # repo -> {"head": sha|None, "commits": {sha: {path: bytes}}}
        self.repos: dict[str, dict] = {}
        # repo -> {asset_name: bytes} of the latest release (absent = no release)
        self.releases: dict[str, dict[str, bytes]] = {}
        # Test hook: the next N commits lose a race (another writer advances the head first).
        self.fail_next_commits = 0
        self.commit_count = 0
        self._counter = itertools.count(1)

    def _repo(self, repo: str) -> dict:
        return self.repos.setdefault(repo, {"head": None, "commits": {}})

    def _new_sha(self) -> str:
        return hashlib.sha1(f"commit-{next(self._counter)}".encode()).hexdigest()

    def files(self, repo: str, ref: str | None = None) -> dict[str, bytes]:
        r = self._repo(repo)
        ref = ref or r["head"]
        return dict(r["commits"].get(ref, {})) if ref else {}

    def seed(self, repo: str, files: Mapping[str, bytes]) -> str:
        r = self._repo(repo)
        base = self.files(repo)
        base.update(files)
        sha = self._new_sha()
        r["commits"][sha] = base
        r["head"] = sha
        return sha

    async def get_head(self, repo: str) -> str | None:
        return self._repo(repo)["head"]

    async def read_file(self, repo: str, path: str, ref: str) -> bytes | None:
        commit = self._repo(repo)["commits"].get(ref)
        if commit is None:
            raise StorageError(f"unknown ref {ref}")
        return commit.get(path)

    async def commit(self, repo: str, parent: str | None, changes: Changes, message: str) -> str:
        r = self._repo(repo)
        if self.fail_next_commits > 0:
            self.fail_next_commits -= 1
            self.seed(repo, {"_other_writer.txt": f"{self._new_sha()}".encode()})
        if r["head"] != parent:
            raise RefConflict("not a fast-forward")
        files = self.files(repo, parent)
        for path, data in changes.items():
            if data is None:
                if path not in files:
                    raise StorageError(f"cannot delete missing {path}")
                del files[path]
            else:
                files[path] = bytes(data)
        sha = self._new_sha()
        r["commits"][sha] = files
        r["head"] = sha
        self.commit_count += 1
        return sha

    async def latest_release_asset(self, repo: str, asset_name: str) -> bytes | None:
        return self.releases.get(repo, {}).get(asset_name)

    async def aclose(self) -> None:
        return None
