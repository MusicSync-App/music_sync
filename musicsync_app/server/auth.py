"""Google OAuth access-token -> verified email, with a 10 minute cache keyed by sha256(token)."""

from __future__ import annotations

import hashlib
import time
from typing import Awaitable, Callable

from errors import ApiError, unauthorized

USERINFO_URL = "https://www.googleapis.com/oauth2/v3/userinfo"
CACHE_TTL = 600
MAX_TOKEN_LEN = 4096

# Returns the userinfo JSON for a valid token, None for an invalid/expired token.
# Raises for transient failures (Google unreachable).
UserinfoFetcher = Callable[[str], Awaitable["dict | None"]]


class GoogleUserinfo:
    """Default fetcher (real HTTP call). httpx client is created lazily."""

    def __init__(self) -> None:
        self._client = None

    async def __call__(self, token: str) -> dict | None:
        import httpx

        if self._client is None:
            self._client = httpx.AsyncClient(timeout=httpx.Timeout(10.0, connect=5.0))
        try:
            r = await self._client.get(USERINFO_URL, headers={"Authorization": f"Bearer {token}"})
        except httpx.HTTPError as e:
            raise ApiError(503, "auth_unavailable",
                           "Nu am putut verifica contul Google. Încearcă din nou.") from e
        if r.status_code in (400, 401, 403):
            return None
        if r.status_code != 200:
            raise ApiError(503, "auth_unavailable", "Nu am putut verifica contul Google. Încearcă din nou.")
        return r.json()

    async def aclose(self) -> None:
        if self._client is not None:
            await self._client.aclose()


class Authenticator:
    def __init__(self, fetch: UserinfoFetcher, admin_emails: set[str]):
        self._fetch = fetch
        self._admins = {e.strip().lower() for e in admin_emails if e.strip()}
        self._cache: dict[str, tuple[float, str]] = {}

    def is_admin(self, email: str) -> bool:
        return email.lower() in self._admins

    async def email_for(self, authorization: str | None) -> str:
        if not authorization:
            raise unauthorized()
        scheme, _, token = authorization.partition(" ")
        token = token.strip()
        if scheme.lower() != "bearer" or not token or len(token) > MAX_TOKEN_LEN:
            raise unauthorized()

        key = hashlib.sha256(token.encode()).hexdigest()
        now = time.monotonic()
        hit = self._cache.get(key)
        if hit and hit[0] > now:
            return hit[1]

        info = await self._fetch(token)
        if not info:
            raise unauthorized()
        email = info.get("email")
        verified = info.get("email_verified")
        if isinstance(verified, str):
            verified = verified.lower() == "true"
        if not isinstance(email, str) or not email or verified is not True:
            raise unauthorized()
        email = email.strip().lower()

        if len(self._cache) > 5000:  # crude bound; drop expired entries
            self._cache = {k: v for k, v in self._cache.items() if v[0] > now}
        self._cache[key] = (now + CACHE_TTL, email)
        return email
