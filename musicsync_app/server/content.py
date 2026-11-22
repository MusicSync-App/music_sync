"""Pure functions over the CONTENT_REPO index.json document."""

from __future__ import annotations

import copy
import json

from errors import ApiError
from validation import BUILTIN_THEMES

INDEX_PATH = "index.json"


def empty_index(now: str) -> dict:
    return {"version": 1, "updatedAt": now, "themes": []}


def load_index(raw: bytes | None, now: str) -> dict:
    if raw is None:
        return empty_index(now)
    data = json.loads(raw)
    if not isinstance(data, dict) or not isinstance(data.get("themes"), list):
        raise ValueError("index.json is malformed")
    return data


def dump_json(data) -> bytes:
    return (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def find_theme(index: dict, theme_id: str) -> dict | None:
    return next((t for t in index["themes"] if t.get("id") == theme_id), None)


def referenced_paths(index: dict) -> set[str]:
    return {p["path"] for t in index["themes"] for p in t.get("photos", [])}


def _union_keywords(existing: list[str], new: list[str]) -> list[str]:
    out = list(existing)
    seen = {k.casefold() for k in existing}
    for k in new:
        if k.casefold() not in seen:
            seen.add(k.casefold())
            out.append(k)
    return out


def _append_photos(theme: dict, photos: list[dict]) -> None:
    have = {p["sha256"] for p in theme.setdefault("photos", [])}
    for p in photos:
        if p["sha256"] not in have:
            have.add(p["sha256"])
            theme["photos"].append(p)


def apply_approval(index: dict, sub: dict, photos: list[dict], edits: dict, now: str) -> tuple[dict, str]:
    """Return (new_index, target_theme_id). `photos` are index photo entries
    ({"path","sha256","w","h"}) already stored (or about to be stored) in the content repo."""
    index = copy.deepcopy(index)
    keywords = edits.get("keywords", sub.get("keywords") or [])

    if sub["kind"] == "country":
        cc = sub["countryCode"]
        theme = next((t for t in index["themes"]
                      if not t.get("builtin") and t.get("countryCode") == cc), None)
        if theme is None:
            theme = {
                "id": f"c_{cc.lower()}",
                "builtin": False,
                "countryCode": cc,
                "name": edits.get("name", sub["name"]),
                "colorValue": edits.get("colorValue", sub["colorValue"]),
                "keywords": [],
                "photos": [],
                "updatedAt": now,
            }
            index["themes"].append(theme)
        else:
            # Merge: keep the existing look unless the admin explicitly edited it.
            if "name" in edits:
                theme["name"] = edits["name"]
            if "colorValue" in edits:
                theme["colorValue"] = edits["colorValue"]
        theme["keywords"] = _union_keywords(theme.get("keywords") or [], keywords)
    else:  # photos
        theme_id = sub["themeId"]
        theme = find_theme(index, theme_id)
        if theme is None:
            if theme_id not in BUILTIN_THEMES:
                raise ApiError(409, "theme_not_found",
                               "Tema pentru care au fost trimise pozele nu mai există.")
            b = BUILTIN_THEMES[theme_id]
            theme = {
                "id": theme_id,
                "builtin": True,
                "countryCode": b["countryCode"],
                "name": b["name"],
                "colorValue": None,
                "keywords": [],
                "photos": [],
                "updatedAt": now,
            }
            index["themes"].append(theme)
        if keywords:
            theme["keywords"] = _union_keywords(theme.get("keywords") or [], keywords)

    _append_photos(theme, photos)
    theme["updatedAt"] = now
    index["updatedAt"] = now
    return index, theme["id"]


def remove_theme(index: dict, theme_id: str, now: str) -> tuple[dict, list[str]]:
    """Return (new_index, photo paths no longer referenced)."""
    index = copy.deepcopy(index)
    theme = find_theme(index, theme_id)
    if theme is None:
        raise ApiError(404, "not_found", "Tema nu a fost găsită.")
    index["themes"] = [t for t in index["themes"] if t is not theme]
    index["updatedAt"] = now
    still = referenced_paths(index)
    orphans = sorted({p["path"] for p in theme.get("photos", [])} - still)
    return index, orphans


def remove_photo(index: dict, theme_id: str, photo_sha: str, now: str) -> tuple[dict, list[str]]:
    index = copy.deepcopy(index)
    theme = find_theme(index, theme_id)
    if theme is None:
        raise ApiError(404, "not_found", "Tema nu a fost găsită.")
    victim = next((p for p in theme.get("photos", []) if p.get("sha256") == photo_sha), None)
    if victim is None:
        raise ApiError(404, "not_found", "Poza nu a fost găsită.")
    theme["photos"] = [p for p in theme["photos"] if p is not victim]
    theme["updatedAt"] = now
    index["updatedAt"] = now
    orphans = [] if victim["path"] in referenced_paths(index) else [victim["path"]]
    return index, orphans
