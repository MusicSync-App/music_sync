"""Rebuilds the place table of assets/geo/places.json for the app's focus countries.

The table lets the app put Radio Browser stations without coordinates on the map by the
city / region / island they declare (lib/radio/place_locator.dart). For the countries in
TARGETS the entries are regenerated from the GeoNames country dumps; every other country
is kept exactly as it is in the current file.

    python tools/geo/build_places.py                 # downloads the dumps (cached in tools/geo/.cache)
    python tools/geo/build_places.py --stats GR      # print what a country contributes

Entry format: places[cc][key] = [lat, lon, tier]
  tier 0  village / small town (< 5 000 inhabitants or unknown)
  tier 1  town  >= 5 000
  tier 2  city  >= 50 000
  tier 3  area: region, prefecture, province, well-known island or island group (point =
          GeoNames representative point, normally the main town); obscure islets get tier 0
Old entries of the other countries use 1 for "big city" and 0 otherwise, which the app reads
the same way (>= 1 may match a word of the station name).

Keys are produced by normalize() below, which must stay identical to normalizePlaceName() in
place_locator.dart (the fold table is read from that file). GeoNames data: CC BY 4.0.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent
PLACES = APP / 'assets' / 'geo' / 'places.json'
CACHE = HERE / '.cache'

TARGETS = ['GR', 'CY', 'TR', 'AL', 'MK', 'BG', 'RS', 'ME', 'BA', 'HR', 'SI', 'XK', 'RO', 'MD',
           'GE', 'AM', 'AZ', 'KZ', 'UZ', 'KG', 'TJ', 'TM']

POPULATED = {'PPL', 'PPLA', 'PPLA2', 'PPLA3', 'PPLA4', 'PPLA5', 'PPLC', 'PPLF', 'PPLG', 'PPLL', 'PPLR', 'PPLS'}
SEATS = {'PPLA', 'PPLA2', 'PPLA3', 'PPLC'}
AREAS = {('A', 'ADM1'), ('A', 'ADM2'), ('A', 'ADM3'), ('A', 'ADMD'), ('T', 'ISL'), ('T', 'ISLS'), ('T', 'PEN'),
         ('L', 'RGN'), ('L', 'RGNH')}
# Municipalities (ADM3) are named after their towns in Greece (Kallikratis "dimoi"); elsewhere
# they mostly add noise.
ADM3_COUNTRIES = {'GR'}
# Words that only say what kind of area it is: "Nomos Kozanis", "Kozani Regional Unit", "Konya İli".
ADMIN_WORDS = {
    'nomos', 'nomou', 'periferia', 'perifereia', 'periphery', 'periferiaki', 'perifereiaki', 'enotita', 'dimos',
    'demos', 'regional', 'unit', 'region', 'prefecture', 'province', 'provincia', 'district', 'municipality',
    'municipal', 'county', 'oblast', 'oblys', 'oblysy', 'viloyati', 'viloyat', 'wiloyat', 'welayaty', 'rayon',
    'raion', 'raioni', 'rajon', 'judetul', 'judet', 'judeţul', 'okrug', 'opstina', 'opcina', 'obcina', 'obshtina',
    'grad', 'il', 'ili', 'ilce', 'ilcesi', 'of', 'the', 'municipiul', 'oras', 'city', 'island', 'islands', 'nisos',
    'nisoi', 'nissos', 'mkhare', 'marz', 'qarku', 'rrethi', 'bashkia', 'komuna', 'kanton', 'canton', 'zupanija',
    'županija', 'περιφέρεια', 'περιφερειακή', 'ενότητα', 'νομός', 'δήμος', 'νήσος', 'νησί', 'νησιά', 'область',
    'облыс', 'район', 'община', 'општина', 'округ', 'вилоят', 'остров', 'oblasti', 'municipiu',
}
# Place names that are also ordinary words in station names / web addresses.
TOO_COMMON = {
    'radio', 'music', 'sport', 'power', 'party', 'dance', 'retro', 'metro', 'super', 'smooth', 'classic', 'lounge',
    'mega', 'star', 'stars', 'gold', 'golden', 'love', 'kiss', 'best', 'hits', 'live', 'online', 'media', 'news',
    'center', 'centre', 'video', 'nova', 'alfa', 'alpha', 'omega', 'delta', 'sigma', 'zeta', 'kappa', 'lambda',
    'beta', 'gamma', 'tango', 'salsa', 'jazz', 'rock', 'blues', 'disco', 'funky', 'house', 'trance', 'urban',
    'magic', 'happy', 'vision', 'planet', 'world', 'global', 'galaxy', 'energy', 'family', 'kids', 'christian',
    'orthodox', 'radyo', 'muzik', 'muzika', 'glas', 'glasba', 'zvuk', 'boom', 'fresh', 'royal', 'imperial',
    'victoria', 'aurora', 'sunny', 'summer', 'winter', 'paradise', 'atlantis', 'olympia', 'olimpia', 'arena',
    'palma', 'marina', 'stella', 'luna', 'sole', 'maria', 'elena', 'sofia', 'diana', 'nina', 'dora', 'lili',
    'dimotika', 'dimotiko', 'nisiotika', 'anadolu', 'avala', 'pink', 'naxi', 'play', 'top', 'hit', 'mix', 'max', 'one', 'lider', 'kral', 'power', 'number',
}

_SCRIPT_OK = re.compile(r'^[\s\w\'’.,()\-/]+$')


# ── Normalisation (mirror of place_locator.dart) ──────────────────────────

def _load_fold():
    src = (APP / 'lib' / 'radio' / 'place_locator.dart').read_text(encoding='utf-8')
    start = src.index('const Map<String, String> _kFold')
    block = src[start:src.index('};', start)]
    return dict(re.findall(r"'(.)': '([^']*)'", block))


FOLD = _load_fold()
KEEP = re.compile(r'[^0-9a-zα-ωа-яёіїєґ]')
GREEK = re.compile(r'[Ͱ-Ͽἀ-῿]')
CYRILLIC = re.compile(r'[Ѐ-ӿ]')
LATIN = re.compile(r'[a-zÀ-ɏ]')
TO_LATIN = dict(zip('αβεζηικνορτυχάέίόύаеорсухвкмнтіјѕ', 'abezhiknoptyxaeioyaeopcyxbkmhtijs'))
TO_GREEK = dict(zip('abeziknoptxyhm', 'αβεζικνορτχυημ'))
TO_CYRILLIC = dict(zip('abekmhopctyxi', 'авекмнорстухі'))


def fix_homoglyphs(text: str) -> str:
    """'Αthens' (Greek capital Alpha) -> 'athens': inside a word, letters of a minority
    script that look like letters of the main script are replaced by those letters."""
    out = []
    for word in re.split(r'(\s+)', text):
        latin, greek, cyr = len(LATIN.findall(word)), len(GREEK.findall(word)), len(CYRILLIC.findall(word))
        if latin and (greek or cyr) and latin >= greek + cyr:
            word = ''.join(TO_LATIN.get(c, c) for c in word)
        elif greek and (latin or cyr) and greek > latin + cyr:
            word = ''.join(TO_GREEK.get(c, c) for c in word)
        elif cyr and (latin or greek) and cyr > latin + greek:
            word = ''.join(TO_CYRILLIC.get(c, c) for c in word)
        out.append(word)
    return ''.join(out)


def fold(text: str) -> str:
    return ''.join(FOLD.get(c, c) for c in fix_homoglyphs(text.lower()))


def normalize(name: str) -> str:
    """Identical to normalizePlaceName() in place_locator.dart."""
    return KEEP.sub('', fold(name))


def name_variants(name: str) -> set[str]:
    """Key of the full name plus the key without admin words ("Nomos Kozanis" -> "kozanis")."""
    keys = {normalize(name)}
    words = [w for w in re.split(r"[\s\-/,()'’.]+", name) if w]
    core = [w for w in words if normalize(w) not in {normalize(a) for a in ADMIN_WORDS}]
    if core and len(core) < len(words):
        keys.add(normalize(' '.join(core)))
    return {k for k in keys if len(k) >= 3}



# ── GeoNames ─────────────────────────────────────────────────────────────

def dump(cc: str) -> str:
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f'{cc}.zip'
    if not path.exists():
        req = urllib.request.Request(f'https://download.geonames.org/export/dump/{cc}.zip',
                                     headers={'User-Agent': 'MusicSync/1.0'})
        path.write_bytes(urllib.request.urlopen(req, timeout=120).read())
        time.sleep(1)
    with zipfile.ZipFile(path) as z:
        return z.read(f'{cc}.txt').decode('utf-8')


def usable(name: str) -> bool:
    if not name or any(c.isdigit() for c in name) or not _SCRIPT_OK.match(name):
        return False
    for c in name:  # Latin, Greek or Cyrillic letters only
        if c.isalpha() and not (LATIN.match(c.lower()) or GREEK.match(c) or CYRILLIC.match(c)):
            return False
    return True


def tier_of(fclass: str, fcode: str, pop: int, alt_count: int = 0) -> int:
    if fclass != 'P':
        # Islets, capes and minor regions: usable as a declared location, but too obscure to be
        # looked for inside station names or web addresses ("Apollon", "Fanos").
        if fcode in ('ISL', 'PEN', 'RGN') and alt_count < 10:
            return 0
        return 3
    if pop >= 50000:
        return 2
    if pop >= 5000:
        return 1
    return 0


def rank(fclass: str, tier: int, pop: int) -> tuple:
    """Which entry wins when two features share a key: towns >= 5k, then areas, then villages."""
    if fclass == 'P' and tier >= 1:
        return (3, pop)
    if fclass != 'P':
        return (2, pop)
    return (1, pop)


def build_country(cc: str, stats=False) -> dict[str, list]:
    best: dict[str, tuple] = {}
    for line in dump(cc).splitlines():
        f = line.split('\t')
        if len(f) < 15:
            continue
        name, ascii_name, alts, lat, lon, fclass, fcode, pop = f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[14]
        pop = int(pop or 0)
        if fclass == 'P':
            if fcode not in POPULATED:
                continue
            if pop < 500 and fcode not in SEATS:
                continue
        elif (fclass, fcode) in AREAS:
            if fcode == 'ADM3' and cc not in ADM3_COUNTRIES:
                continue
            alt_list = [a for a in alts.split(',') if a]
            # Islets and minor localities have no alternate names; notable ones have many.
            if fcode in ('ISL', 'PEN', 'RGN') and len(alt_list) < 3:
                continue
        else:
            continue
        tier = tier_of(fclass, fcode, pop, len([a for a in alts.split(',') if a]))
        names = {name, ascii_name, *[a for a in alts.split(',') if a]}
        entry = [round(float(lat), 3), round(float(lon), 3), tier]
        r = rank(fclass, tier, pop)
        for n in names:
            if not usable(n):
                continue
            for key in name_variants(n):
                if key in TOO_COMMON and tier < 2:
                    continue
                if key not in best or r > best[key][0]:
                    best[key] = (r, entry)
    result = {k: v[1] for k, v in best.items()}
    if stats:
        tiers = {}
        for v in result.values():
            tiers[v[2]] = tiers.get(v[2], 0) + 1
        print(cc, len(result), 'keys', tiers)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stats', nargs='*')
    args = ap.parse_args()
    if args.stats:
        for cc in args.stats:
            build_country(cc, stats=True)
        return
    data = json.loads(PLACES.read_text(encoding='utf-8'))
    first_run = data.get('format') != 2
    places = {cc: read_entries(v) for cc, v in data['places'].items()}
    for cc in TARGETS:
        fresh = build_country(cc)
        old = places.get(cc, {})
        if first_run:  # never lose a key of the original hand-made table (its flag 1 = big city)
            for k, v in old.items():
                fresh.setdefault(k, [v[0], v[1], 2 if v[2] == 1 else 0])
        places[cc] = fresh
        print(f'{cc}: {len(old)} -> {len(fresh)} keys', flush=True)
    out = {'format': 2, 'capitals': data['capitals'], 'places': {cc: write_entries(m) for cc, m in sorted(places.items())}}
    PLACES.write_text(json.dumps(out, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    print(f'wrote {PLACES} ({PLACES.stat().st_size / 1e6:.2f} MB)')


def read_entries(value) -> dict[str, list]:
    """Format 1: {key: [lat, lon, tier]}; format 2: [[lat, lon, tier, "key1 key2 ..."], ...]."""
    if isinstance(value, dict):
        return dict(value)
    return {k: e[:3] for e in value for k in e[3].split(' ')}


def write_entries(keys: dict[str, list]) -> list:
    """Keys sharing a point are stored once with that point (much smaller than format 1)."""
    groups: dict[tuple, list[str]] = {}
    for k, v in keys.items():
        groups.setdefault(tuple(v), []).append(k)
    return [[*v, ' '.join(sorted(ks))] for v, ks in sorted(groups.items())]


if __name__ == '__main__':
    sys.exit(main())
