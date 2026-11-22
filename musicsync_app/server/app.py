"""MusicSync update + community-themes server.

Start: uvicorn app:app --host 0.0.0.0 --port $PORT
Contract: see README.md. All persistent state lives in GitHub repos (Render's disk is ephemeral).
"""

from __future__ import annotations

import asyncio
import copy
import hashlib
import json
import logging
import os
import secrets
import time
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from starlette.concurrency import run_in_threadpool
from starlette.exceptions import HTTPException as StarletteHTTPException

import content as content_mod
import validation as v
from auth import Authenticator, GoogleUserinfo, UserinfoFetcher
from errors import ApiError, bad_request, forbidden, not_found
from storage import Storage, StorageError, atomic_update

log = logging.getLogger("musicsync")

MAX_PHOTOS = 10
MAX_PHOTO_BYTES = 8 * 1024 * 1024
MAX_SUBMISSION_BODY = MAX_PHOTOS * MAX_PHOTO_BYTES + 1024 * 1024
MANIFEST_TTL = 300
SUBMISSIONS_INDEX = "submissions.json"  # aggregate of all submission metas in PENDING_REPO

IMAGE_MESSAGES = {
    "invalid_image": "Una dintre poze nu este o imagine validă.",
    "unsupported_format": "Sunt acceptate doar poze JPEG, PNG sau WEBP.",
    "image_too_large": "Una dintre poze are o rezoluție prea mare.",
    "image_too_small": "Una dintre poze este prea mică.",
}


# --------------------------------------------------------------------------- settings
@dataclass
class Settings:
    content_repo: str
    pending_repo: str
    app_repo: str
    admin_emails: set[str] = field(default_factory=set)
    max_submissions_per_day: int = 5
    github_token: str = ""
    branch: str = "main"

    @classmethod
    def from_env(cls) -> "Settings":
        try:
            limit = int(os.environ.get("MAX_SUBMISSIONS_PER_DAY", "5"))
        except ValueError:
            limit = 5
        return cls(
            content_repo=os.environ.get("CONTENT_REPO", "").strip(),
            pending_repo=os.environ.get("PENDING_REPO", "").strip(),
            app_repo=os.environ.get("APP_REPO", "").strip(),
            admin_emails={e.strip().lower() for e in os.environ.get("ADMIN_EMAILS", "").split(",") if e.strip()},
            max_submissions_per_day=max(0, limit),
            github_token=os.environ.get("GITHUB_TOKEN", "").strip(),
            branch=os.environ.get("GIT_BRANCH", "main").strip() or "main",
        )


# --------------------------------------------------------------------------- helpers
_ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def new_ulid() -> str:
    n = (int(time.time() * 1000) << 80) | secrets.randbits(80)
    return "".join(_ULID_ALPHABET[(n >> (5 * i)) & 31] for i in reversed(range(26)))


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_iso(s: str) -> datetime | None:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError, TypeError):
        return None


def raw_base(repo: str, sha: str) -> str:
    return f"https://raw.githubusercontent.com/{repo}/{sha}/"


# --------------------------------------------------------------------------- body size limit
class BodyLimitMiddleware:
    """Pure ASGI middleware: hard cap on the request body size of one POST path
    (checked from Content-Length up front, and by counting bytes for chunked uploads)."""

    def __init__(self, app, path: str, limit: int):
        self.app = app
        self.path = path
        self.limit = limit

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST" or scope["path"] != self.path:
            return await self.app(scope, receive, send)

        async def reject(status: int, code: str, message: str):
            body = json.dumps({"error": code, "message": message}, ensure_ascii=False).encode()
            await send({"type": "http.response.start", "status": status,
                        "headers": [(b"content-type", b"application/json"),
                                    (b"content-length", str(len(body)).encode())]})
            await send({"type": "http.response.body", "body": body})

        for name, value in scope.get("headers", []):
            if name == b"content-length":
                try:
                    too_big = int(value) > self.limit
                except ValueError:
                    return await reject(400, "bad_request", "Cerere invalidă.")
                if too_big:
                    return await reject(413, "too_large", "Cererea este prea mare.")

        received = 0

        async def counting_receive():
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.limit:
                    raise ApiError(413, "too_large", "Cererea este prea mare.")
            return message

        return await self.app(scope, counting_receive, send)


# --------------------------------------------------------------------------- submissions store
class SubmissionStore:
    """All submission metas, cached in memory (this server is the only writer of PENDING_REPO).

    PENDING_REPO layout:
      submissions.json                  {"submissions": [meta, ...]}  (aggregate, one read on cold start)
      submissions/<id>/meta.json        meta (human-browsable copy)
      submissions/<id>/<n>.jpg          normalized photos
    """

    def __init__(self, storage: Storage, repo: str):
        self.storage = storage
        self.repo = repo
        self.lock = asyncio.Lock()
        self._metas: dict[str, dict] | None = None
        self._head: str | None = None

    async def _load_at(self, head: str | None) -> dict[str, dict]:
        if head is None:
            return {}
        raw = await self.storage.read_file(self.repo, SUBMISSIONS_INDEX, head)
        if raw is None:
            return {}
        data = json.loads(raw)
        return {m["id"]: m for m in data.get("submissions", [])}

    async def all(self) -> dict[str, dict]:
        if self._metas is None:
            async with self.lock:
                if self._metas is None:
                    head = await self.storage.get_head(self.repo)
                    self._metas = await self._load_at(head)
                    self._head = head
        return self._metas

    async def get(self, sub_id: str) -> dict:
        if not v.SUBMISSION_ID_RE.match(sub_id):
            raise not_found("Propunerea")
        meta = (await self.all()).get(sub_id)
        if meta is None:
            raise not_found("Propunerea")
        return meta

    async def read_photo(self, sub_id: str, n: int) -> bytes | None:
        head = await self.storage.get_head(self.repo)
        if head is None:
            return None
        return await self.storage.read_file(self.repo, f"submissions/{sub_id}/{n}.jpg", head)

    async def write(self, message: str, mutate) -> None:
        """mutate(metas) -> (extra_changes, changed_ids); may raise ApiError. Runs under the lock,
        re-run on ref-update conflicts."""
        await self.all()
        async with self.lock:
            result: dict = {}

            async def build(head):
                metas = self._metas if head == self._head else await self._load_at(head)
                metas = copy.deepcopy(metas)
                extra, changed = mutate(metas)
                changes = dict(extra)
                for sid in changed:
                    changes[f"submissions/{sid}/meta.json"] = content_mod.dump_json(metas[sid])
                ordered = sorted(metas.values(), key=lambda m: m["createdAt"])
                changes[SUBMISSIONS_INDEX] = content_mod.dump_json({"submissions": ordered})
                result["metas"] = metas
                return changes

            new_head, _ = await atomic_update(self.storage, self.repo, message, build)
            self._metas = result["metas"]
            self._head = new_head


# --------------------------------------------------------------------------- app factory
def create_app(
    settings: Settings | None = None,
    storage: Storage | None = None,
    userinfo: UserinfoFetcher | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    missing = [n for n, val in (("CONTENT_REPO", settings.content_repo), ("PENDING_REPO", settings.pending_repo),
                                ("APP_REPO", settings.app_repo)) if not val]
    if missing:
        log.warning("missing configuration: %s (set them in the Render dashboard)", ", ".join(missing))
    owns_userinfo = userinfo is None
    if storage is None:
        from github_storage import GitHubStorage

        storage = GitHubStorage(settings.github_token, branch=settings.branch)
    userinfo = userinfo or GoogleUserinfo()

    auth = Authenticator(userinfo, settings.admin_emails)
    subs = SubmissionStore(storage, settings.pending_repo)
    content_lock = asyncio.Lock()
    manifest_lock = asyncio.Lock()
    manifest_cache: dict = {"at": 0.0, "value": None}

    @asynccontextmanager
    async def lifespan(_app):
        yield
        await storage.aclose()
        if owns_userinfo and hasattr(userinfo, "aclose"):
            await userinfo.aclose()

    app = FastAPI(title="MusicSync server", docs_url=None, redoc_url=None, openapi_url=None,
                  lifespan=lifespan)
    app.state.settings = settings
    app.state.storage = storage
    app.state.subs = subs
    app.state.manifest_cache = manifest_cache

    # ---------------------------------------------------------------- errors
    def err(status: int, code: str, message: str) -> JSONResponse:
        return JSONResponse({"error": code, "message": message}, status_code=status)

    @app.exception_handler(ApiError)
    async def _api_error(_req, exc: ApiError):
        return err(exc.status, exc.code, exc.message)

    @app.exception_handler(StorageError)
    async def _storage_error(_req, exc: StorageError):
        log.error("storage error: %s", exc)
        return err(502, "storage_unavailable", "Serverul de stocare nu răspunde. Încearcă din nou mai târziu.")

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_req, exc: StarletteHTTPException):
        if exc.status_code == 404:
            return err(404, "not_found", "Resursa nu a fost găsită.")
        if exc.status_code == 405:
            return err(405, "method_not_allowed", "Metodă nepermisă.")
        return err(exc.status_code, "bad_request", "Cerere invalidă.")

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_req, _exc):
        return err(400, "bad_request", "Cerere invalidă.")

    @app.exception_handler(Exception)
    async def _unhandled(_req, exc: Exception):
        log.exception("unhandled error: %s", type(exc).__name__)
        return err(500, "internal", "A apărut o eroare pe server. Încearcă din nou mai târziu.")

    # ---------------------------------------------------------------- body limit
    app.add_middleware(BodyLimitMiddleware, path="/api/submissions", limit=MAX_SUBMISSION_BODY)

    # ---------------------------------------------------------------- auth deps
    async def current_email(request: Request) -> str:
        return await auth.email_for(request.headers.get("authorization"))

    async def current_admin(request: Request) -> str:
        email = await current_email(request)
        if not auth.is_admin(email):
            raise forbidden()
        return email

    # ---------------------------------------------------------------- public
    @app.get("/health")
    async def health():
        return {"ok": True}

    async def _build_manifest() -> dict:
        app_info = None
        if settings.app_repo:
            try:
                raw = await storage.latest_release_asset(settings.app_repo, "version.json")
                if raw is not None:
                    parsed = json.loads(raw)
                    app_info = parsed if isinstance(parsed, dict) else None
            except (StorageError, ValueError) as e:
                log.warning("could not read version.json: %s", e)
                prev = manifest_cache["value"]
                app_info = prev["app"] if prev else None
        head = await storage.get_head(settings.content_repo)
        content = None
        if head is not None:
            base = raw_base(settings.content_repo, head)
            content = {"revision": head, "indexUrl": base + content_mod.INDEX_PATH, "baseUrl": base}
        return {"app": app_info, "content": content}

    def _invalidate_manifest():
        manifest_cache["at"] = 0.0

    @app.get("/api/manifest")
    async def manifest():
        now = time.monotonic()
        if manifest_cache["value"] is not None and now - manifest_cache["at"] < MANIFEST_TTL:
            return manifest_cache["value"]
        async with manifest_lock:
            if manifest_cache["value"] is not None and time.monotonic() - manifest_cache["at"] < MANIFEST_TTL:
                return manifest_cache["value"]
            try:
                value = await _build_manifest()
            except StorageError:
                if manifest_cache["value"] is not None:  # serve stale rather than fail
                    return manifest_cache["value"]
                raise
            manifest_cache["value"] = value
            manifest_cache["at"] = time.monotonic()
            return value

    # ---------------------------------------------------------------- user
    @app.get("/api/me")
    async def me(request: Request):
        email = await current_email(request)
        return {"email": email, "isAdmin": auth.is_admin(email)}

    def _count_recent(metas: dict, email: str, now: datetime) -> int:
        since = now - timedelta(days=1)
        n = 0
        for m in metas.values():
            if m.get("submitterEmail") == email:
                created = parse_iso(m.get("createdAt", ""))
                if created and created > since:
                    n += 1
        return n

    def _rate_limited() -> ApiError:
        return ApiError(429, "rate_limited",
                        f"Ai atins limita de {settings.max_submissions_per_day} propuneri pe zi. "
                        "Încearcă din nou mâine.")

    async def _known_theme(theme_id: str) -> bool:
        if theme_id in v.BUILTIN_THEMES:
            return True
        head = await storage.get_head(settings.content_repo)
        if head is None:
            return False
        raw = await storage.read_file(settings.content_repo, content_mod.INDEX_PATH, head)
        if raw is None:
            return False
        return content_mod.find_theme(content_mod.load_index(raw, iso(utcnow())), theme_id) is not None

    @app.post("/api/submissions", status_code=201)
    async def submit(request: Request):
        email = await current_email(request)

        # Cheap rate-limit pre-check before parsing/decoding anything heavy.
        if _count_recent(await subs.all(), email, utcnow()) >= settings.max_submissions_per_day:
            raise _rate_limited()

        ctype = request.headers.get("content-type", "").lower()
        if not ctype.startswith(("multipart/form-data", "application/x-www-form-urlencoded")):
            raise bad_request("bad_request", "Cererea trebuie trimisă ca multipart/form-data.")
        try:
            form = await request.form(max_files=50, max_fields=20)
        except ApiError:
            raise
        except Exception:
            raise bad_request("bad_request", "Formular invalid.")

        try:
            meta_field = form.get("meta")
            if meta_field is not None and not isinstance(meta_field, str):
                raise v.bad_meta("Câmpul „meta” trebuie să fie text.")
            meta = v.parse_meta(meta_field)

            uploads = [f for key, f in form.multi_items() if key == "photos"]
            if any(isinstance(f, str) for f in uploads):
                raise bad_request("invalid_image", "Câmpul „photos” trebuie să conțină fișiere.")
            if len(uploads) > MAX_PHOTOS:
                raise bad_request("too_many_photos", f"Poți trimite cel mult {MAX_PHOTOS} poze.")
            if meta["kind"] == "photos" and not uploads:
                raise bad_request("no_photos", "Adaugă cel puțin o poză.")
            for f in uploads:
                if f.size is not None and f.size > MAX_PHOTO_BYTES:
                    raise ApiError(413, "photo_too_large", "Fiecare poză poate avea cel mult 8 MB.")

            if meta["kind"] == "photos" and not await _known_theme(meta["themeId"]):
                raise bad_request("theme_not_found", "Tema aleasă nu există.")

            from images import ImageRejected, process_image

            photos: list[tuple[bytes, dict]] = []
            for n, f in enumerate(uploads):
                data = await f.read(MAX_PHOTO_BYTES + 1)
                if len(data) > MAX_PHOTO_BYTES:
                    raise ApiError(413, "photo_too_large", "Fiecare poză poate avea cel mult 8 MB.")
                try:
                    jpeg, w, h = await run_in_threadpool(process_image, data)
                except ImageRejected as e:
                    raise bad_request(e.code, IMAGE_MESSAGES.get(e.code, IMAGE_MESSAGES["invalid_image"]))
                del data
                photos.append((jpeg, {"n": n, "sha256": hashlib.sha256(jpeg).hexdigest(), "w": w, "h": h}))
        finally:
            await form.close()

        sub_id = new_ulid()
        now = utcnow()
        record = {
            "id": sub_id,
            **meta,
            "photos": [p for _, p in photos],
            "submitterEmail": email,
            "createdAt": iso(now),
            "status": "pending",
        }

        def mutate(metas: dict):
            if _count_recent(metas, email, now) >= settings.max_submissions_per_day:
                raise _rate_limited()
            metas[sub_id] = record
            extra = {f"submissions/{sub_id}/{p['n']}.jpg": jpeg for jpeg, p in photos}
            return extra, [sub_id]

        await subs.write(f"Submission {sub_id} ({meta['kind']})", mutate)
        log.info("submission %s stored (%d photos)", sub_id, len(photos))
        return JSONResponse({"id": sub_id, "status": "pending"}, status_code=201)

    def _public_view(m: dict) -> dict:
        out = {k: m.get(k) for k in ("id", "kind", "name", "countryCode", "themeId", "status", "createdAt")}
        if m.get("reason"):
            out["reason"] = m["reason"]
        return out

    @app.get("/api/submissions/mine")
    async def mine(request: Request):
        email = await current_email(request)
        items = [m for m in (await subs.all()).values() if m.get("submitterEmail") == email]
        items.sort(key=lambda m: m["createdAt"], reverse=True)
        return [_public_view(m) for m in items]

    # ---------------------------------------------------------------- admin
    @app.get("/api/admin/submissions")
    async def admin_list(request: Request, status: str = "pending"):
        await current_admin(request)
        if status not in ("pending", "approved", "rejected", "all"):
            raise bad_request("bad_request", "Status invalid.")
        items = [m for m in (await subs.all()).values() if status == "all" or m.get("status") == status]
        items.sort(key=lambda m: m["createdAt"])
        out = []
        for m in items:
            d = copy.deepcopy(m)
            d["photoUrls"] = [f"/api/admin/submissions/{m['id']}/photos/{p['n']}" for p in m.get("photos", [])]
            out.append(d)
        return out

    @app.get("/api/admin/submissions/{sub_id}/photos/{n}")
    async def admin_photo(request: Request, sub_id: str, n: int):
        await current_admin(request)
        meta = await subs.get(sub_id)
        if not any(p["n"] == n for p in meta.get("photos", [])):
            raise not_found("Poza")
        data = await subs.read_photo(sub_id, n)
        if data is None:
            raise not_found("Poza")
        return Response(data, media_type="image/jpeg",
                        headers={"Cache-Control": "private, max-age=3600",
                                 "X-Content-Type-Options": "nosniff"})

    async def _json_body(request: Request, required: bool):
        body = await request.body()
        if not body.strip():
            if required:
                raise v.bad_meta("Corpul cererii lipsește.")
            return None
        if len(body) > 16 * 1024:
            raise v.bad_meta("Corpul cererii este prea mare.")
        try:
            return json.loads(body)
        except ValueError:
            raise v.bad_meta("Corpul cererii nu este JSON valid.")

    async def _update_content(message: str, mutate) -> str:
        """mutate(index, head) -> (new_index, extra_changes, result). Under the content lock."""
        async with content_lock:
            out: dict = {}

            async def build(head):
                raw = None
                if head is not None:
                    raw = await storage.read_file(settings.content_repo, content_mod.INDEX_PATH, head)
                index = content_mod.load_index(raw, iso(utcnow()))
                new_index, extra = mutate(index)
                changes = dict(extra)
                changes[content_mod.INDEX_PATH] = content_mod.dump_json(new_index)
                return changes

            new_head, _ = await atomic_update(storage, settings.content_repo, message, build)
            out["head"] = new_head
        _invalidate_manifest()
        return out["head"]

    @app.post("/api/admin/submissions/{sub_id}/approve")
    async def approve(request: Request, sub_id: str):
        admin = await current_admin(request)
        edits = v.parse_edits(await _json_body(request, required=False))
        sub = await subs.get(sub_id)
        if sub.get("status") != "pending":
            raise ApiError(409, "already_decided", "Propunerea a fost deja procesată.")

        files: dict[str, bytes] = {}
        entries: list[dict] = []
        for p in sub.get("photos", []):
            data = await subs.read_photo(sub_id, p["n"])
            if data is None:
                raise StorageError(f"photo {p['n']} of {sub_id} missing in pending repo")
            sha = hashlib.sha256(data).hexdigest()
            path = f"photos/{sha}.jpg"
            files[path] = data
            entries.append({"path": path, "sha256": sha, "w": p["w"], "h": p["h"]})

        result: dict = {}

        def mutate_content(index):
            new_index, theme_id = content_mod.apply_approval(index, sub, entries, edits, iso(utcnow()))
            result["themeId"] = theme_id
            existing = content_mod.referenced_paths(index)
            return new_index, {k: b for k, b in files.items() if k not in existing}

        revision = await _update_content(f"Approve submission {sub_id}", mutate_content)

        def mutate_subs(metas):
            m = metas.get(sub_id)
            if m is None:
                raise not_found("Propunerea")
            m["status"] = "approved"
            m["decidedAt"] = iso(utcnow())
            m["decidedBy"] = admin
            m["approvedThemeId"] = result["themeId"]
            m["contentRevision"] = revision
            if edits:
                m["adminEdits"] = edits
            return {}, [sub_id]

        await subs.write(f"Approve submission {sub_id}", mutate_subs)
        return {"ok": True, "revision": revision}

    @app.post("/api/admin/submissions/{sub_id}/reject")
    async def reject(request: Request, sub_id: str):
        admin = await current_admin(request)
        body = await _json_body(request, required=False)
        reason = v.parse_reason(body if body is not None else {})
        sub = await subs.get(sub_id)
        if sub.get("status") != "pending":
            raise ApiError(409, "already_decided", "Propunerea a fost deja procesată.")

        def mutate(metas):
            m = metas.get(sub_id)
            if m is None:
                raise not_found("Propunerea")
            if m.get("status") != "pending":
                raise ApiError(409, "already_decided", "Propunerea a fost deja procesată.")
            m["status"] = "rejected"
            m["decidedAt"] = iso(utcnow())
            m["decidedBy"] = admin
            if reason:
                m["reason"] = reason
            return {}, [sub_id]

        await subs.write(f"Reject submission {sub_id}", mutate)
        return {"ok": True}

    def _check_theme_id(theme_id: str):
        if not v.valid_theme_id(theme_id):
            raise not_found("Tema")

    @app.delete("/api/admin/themes/{theme_id}")
    async def delete_theme(request: Request, theme_id: str):
        await current_admin(request)
        _check_theme_id(theme_id)

        def mutate(index):
            new_index, orphans = content_mod.remove_theme(index, theme_id, iso(utcnow()))
            return new_index, {p: None for p in orphans}

        revision = await _update_content(f"Delete theme {theme_id}", mutate)
        return {"ok": True, "revision": revision}

    @app.delete("/api/admin/themes/{theme_id}/photos/{photo_sha}")
    async def delete_photo(request: Request, theme_id: str, photo_sha: str):
        await current_admin(request)
        _check_theme_id(theme_id)
        if not v.PHOTO_SHA_RE.match(photo_sha):
            raise not_found("Poza")

        def mutate(index):
            new_index, orphans = content_mod.remove_photo(index, theme_id, photo_sha, iso(utcnow()))
            return new_index, {p: None for p in orphans}

        revision = await _update_content(f"Delete photo {photo_sha[:12]} from {theme_id}", mutate)
        return {"ok": True, "revision": revision}

    return app


def _make_default_app() -> FastAPI:
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # httpx logs full request URLs at INFO; keep it quieter (tokens are never in URLs anyway).
    logging.getLogger("httpx").setLevel(logging.WARNING)
    return create_app()


app = _make_default_app()
