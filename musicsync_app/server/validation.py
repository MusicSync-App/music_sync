"""Validation of client-supplied submission metadata and admin edits."""

from __future__ import annotations

import json
import re
import unicodedata

from errors import ApiError, bad_request

THEME_ID_RE = re.compile(r"^[a-z0-9_]{1,40}$")
COUNTRY_RE = re.compile(r"^[A-Z]{2}$")
SUBMISSION_ID_RE = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")  # ULID (Crockford base32)
PHOTO_SHA_RE = re.compile(r"^[0-9a-f]{64}$")

MAX_META_BYTES = 8 * 1024
MAX_NAME_LEN = 40
MAX_KEYWORDS = 20
MAX_KEYWORD_LEN = 40
MAX_REASON_LEN = 500
COLOR_MIN, COLOR_MAX = 0, 0xFFFFFFFF

# Built-in themes of the app (keys of `appThemes` in lib/themes/app_themes.dart).
# NOTE: 'central asia' contains a space, so it is accepted explicitly even though it does not
# match THEME_ID_RE.
BUILTIN_THEMES: dict[str, dict] = {
    "armenia": {"name": "Armenia", "countryCode": "AM"},
    "grecia": {"name": "Grecia", "countryCode": "GR"},
    "iran": {"name": "Iran", "countryCode": "IR"},
    "turcia": {"name": "Turcia", "countryCode": "TR"},
    "azerbaidjan": {"name": "Azerbaidjan", "countryCode": "AZ"},
    "kurdistan": {"name": "Kurdistan", "countryCode": None},
    "bosnia": {"name": "Bosnia", "countryCode": "BA"},
    "central asia": {"name": "Central Asia", "countryCode": None},
}


def bad_meta(message: str) -> ApiError:
    return bad_request("invalid_meta", message)


def valid_theme_id(theme_id: object) -> bool:
    return isinstance(theme_id, str) and (bool(THEME_ID_RE.match(theme_id)) or theme_id in BUILTIN_THEMES)


def _clean_text(value: object, field: str, max_len: int) -> str:
    if not isinstance(value, str):
        raise bad_meta(f"Câmpul „{field}” trebuie să fie text.")
    value = unicodedata.normalize("NFC", value).strip()
    if any(unicodedata.category(ch) in ("Cc", "Cf", "Cs", "Co") for ch in value):
        raise bad_meta(f"Câmpul „{field}” conține caractere nepermise.")
    if not value:
        raise bad_meta(f"Câmpul „{field}” nu poate fi gol.")
    if len(value) > max_len:
        raise bad_meta(f"Câmpul „{field}” poate avea cel mult {max_len} caractere.")
    return value


def clean_name(value: object) -> str:
    return _clean_text(value, "name", MAX_NAME_LEN)


def clean_color(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not (COLOR_MIN <= value <= COLOR_MAX):
        raise bad_meta("Culoarea (colorValue) trebuie să fie un număr ARGB între 0 și 4294967295.")
    return value


def clean_keywords(value: object) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise bad_meta("Cuvintele cheie trebuie să fie o listă.")
    if len(value) > MAX_KEYWORDS:
        raise bad_meta(f"Poți adăuga cel mult {MAX_KEYWORDS} cuvinte cheie.")
    out: list[str] = []
    seen: set[str] = set()
    for kw in value:
        kw = _clean_text(kw, "keywords", MAX_KEYWORD_LEN)
        k = kw.casefold()
        if k not in seen:
            seen.add(k)
            out.append(kw)
    return out


def parse_meta(raw: str | None) -> dict:
    """Parse + validate the `meta` form field. Returns a normalized dict."""
    if raw is None:
        raise bad_meta("Lipsește câmpul „meta”.")
    if len(raw.encode("utf-8", "surrogatepass")) > MAX_META_BYTES:
        raise bad_meta("Câmpul „meta” este prea mare.")
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError):
        raise bad_meta("Câmpul „meta” nu este JSON valid.")
    if not isinstance(data, dict):
        raise bad_meta("Câmpul „meta” trebuie să fie un obiect JSON.")

    kind = data.get("kind")
    out: dict = {"kind": kind, "themeId": None, "countryCode": None, "name": None,
                 "colorValue": None, "keywords": clean_keywords(data.get("keywords"))}

    if kind == "country":
        cc = data.get("countryCode")
        if not isinstance(cc, str) or not COUNTRY_RE.match(cc):
            raise bad_meta("Codul țării trebuie să aibă 2 litere mari (ex.: RO).")
        out["countryCode"] = cc
        out["name"] = clean_name(data.get("name"))
        out["colorValue"] = clean_color(data.get("colorValue"))
    elif kind == "photos":
        theme_id = data.get("themeId")
        if not valid_theme_id(theme_id):
            raise bad_meta("Tema aleasă (themeId) nu este validă.")
        out["themeId"] = theme_id
        # Optional, informational only.
        if data.get("name") is not None:
            out["name"] = clean_name(data.get("name"))
        cc = data.get("countryCode")
        if cc is not None:
            if not isinstance(cc, str) or not COUNTRY_RE.match(cc):
                raise bad_meta("Codul țării trebuie să aibă 2 litere mari (ex.: RO).")
            out["countryCode"] = cc
    else:
        raise bad_meta("Tipul propunerii (kind) trebuie să fie „country” sau „photos”.")
    return out


def parse_edits(data: object) -> dict:
    """Admin edits on approve: optional name / colorValue / keywords."""
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise bad_meta("Corpul cererii trebuie să fie un obiect JSON.")
    edits: dict = {}
    if data.get("name") is not None:
        edits["name"] = clean_name(data["name"])
    if data.get("colorValue") is not None:
        edits["colorValue"] = clean_color(data["colorValue"])
    if data.get("keywords") is not None:
        edits["keywords"] = clean_keywords(data["keywords"])
    return edits


def parse_reason(data: object) -> str:
    if not isinstance(data, dict):
        raise bad_meta("Corpul cererii trebuie să fie un obiect JSON.")
    reason = data.get("reason")
    if isinstance(reason, str):
        reason = " ".join(reason.split())  # collapse newlines/tabs
    if reason is None or (isinstance(reason, str) and not reason.strip()):
        return ""
    return _clean_text(reason, "reason", MAX_REASON_LEN)
