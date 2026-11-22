"""API error type. Every error response is JSON {"error": code, "message": <Romanian text>}."""

from __future__ import annotations


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(code)
        self.status = status
        self.code = code
        self.message = message


# Common errors (Romanian, user-facing messages).
def unauthorized() -> ApiError:
    return ApiError(401, "unauthorized", "Autentificare necesară. Conectează-te din nou cu contul Google.")


def forbidden() -> ApiError:
    return ApiError(403, "forbidden", "Nu ai drepturi de administrator.")


def not_found(what: str = "Resursa") -> ApiError:
    return ApiError(404, "not_found", f"{what} nu a fost găsită.")


def bad_request(code: str, message: str) -> ApiError:
    return ApiError(400, code, message)
