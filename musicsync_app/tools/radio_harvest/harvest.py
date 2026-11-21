"""Offline harvester for the bundled radio catalogue (assets/radio/stations_bundle.json.gz).

Crawls public station directories for the Balkans, Turkey, Cyprus, the Caucasus and
Central Asia, resolves real stream URLs, geolocates stations, dedupes them against
each other and against Radio Browser (which the app already queries live), checks
that each stream answers with audio and writes a compact gzipped JSON asset.

Usage (from musicsync_app/):
    python tools/radio_harvest/harvest.py                 # crawl + verify + write asset
    python tools/radio_harvest/harvest.py --skip-verify   # reuse cached verification only
    python tools/radio_harvest/harvest.py --countries GR,TR

Needs Python 3.10+ and `requests`. Every HTTP GET is cached under
tools/radio_harvest/.cache (gitignored), so re-runs do not hit the sites again;
delete that folder to refresh. Requests are rate limited per host (1-2 connections,
several hundred ms apart) and use the User-Agent "MusicSync/1.0".

Sources (see SOURCES below): Radio Garden (places + channel lists; robots.txt
disallows /api/ara/content/listen/, so those redirects are NOT crawled here, the
app resolves them on playback), onlineradiobox.com, TuneIn public OPML
(opml.radiotime.com), live24.gr, the instant.audio network (bg-radio.org,
radios.hr, radiostanice.rs, siradio.si, radiofona.com.gr, radio.org.ro) and radio.net.
"""

from __future__ import annotations

import argparse
import faulthandler
import gzip
import hashlib
import json
import math
import os
import re
import sys
import threading
import time
import unicodedata
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urljoin, urlparse

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'geo'))
import build_places as places  # noqa: E402  (place table + normalisation shared with the app)

UA = 'MusicSync/1.0'
HERE = Path(__file__).resolve().parent
APP = HERE.parent.parent
CACHE = HERE / '.cache'
WORK = HERE / '.work'
OUT = APP / 'assets' / 'radio' / 'stations_bundle.json.gz'

# cc -> per-source identifiers (None = source has nothing for that country).
COUNTRIES: dict[str, dict] = {
    'GR': dict(rg='Greece', tunein='r101244', orb='gr', rnet='greece'),
    'AL': dict(rg='Albania', tunein='r100288', orb='al', rnet='albania'),
    'MK': dict(rg='North Macedonia', tunein='r101263', orb='mk', rnet='macedonia'),
    'BG': dict(rg='Bulgaria', tunein='r101225', orb='bg', rnet='bulgaria'),
    'RS': dict(rg='Serbia', tunein='r101357', orb='rs', rnet='serbia'),
    'ME': dict(rg='Montenegro', tunein='r101358', orb='me', rnet='montenegro'),
    'BA': dict(rg='Bosnia and Herzegovina', tunein='r100309', orb='ba', rnet='bosnia-and-herzegovina'),
    'HR': dict(rg='Croatia', tunein='r100331', orb='hr', rnet='croatia'),
    'SI': dict(rg='Slovenia', tunein='r100411', orb='si', rnet='slovenia'),
    'XK': dict(rg='Kosovo', tunein='r102406', orb='xk', rnet='kosovo'),
    'RO': dict(rg='Romania', tunein='r101287', orb='ro', rnet='romania'),
    'MD': dict(rg='Moldova', tunein='r101273', orb='md', rnet='moldova'),
    'CY': dict(rg='Cyprus', tunein='r101231', orb='cy', rnet='cyprus'),
    'TR': dict(rg='Türkiye', tunein='r101308', orb='tr', rnet='turkey'),
    'GE': dict(rg='Georgia', tunein='r101435', orb='ge', rnet=None),  # radio.net 'georgia' = the US state
    'AM': dict(rg='Armenia', tunein='r100295', orb='am', rnet='armenia'),
    'AZ': dict(rg='Azerbaijan', tunein='r101222', orb='az', rnet='azerbaijan'),
    'KZ': dict(rg='Kazakhstan', tunein='r100362', orb='kz', rnet='kazakhstan'),
    'UZ': dict(rg='Uzbekistan', tunein='r101311', orb='uz', rnet='uzbekistan'),
    'KG': dict(rg='Kyrgyzstan', tunein='r101257', orb='kg', rnet=None),
    'TJ': dict(rg='Tajikistan', tunein=None, orb='tj', rnet=None),
    'TM': dict(rg=None, tunein=None, orb='tm', rnet=None),
}

INSTANT_AUDIO_SITES = {
    'bg-radio.org': 'BG',
    'radios.hr': 'HR',
    'radiostanice.rs': 'RS',
    'siradio.si': 'SI',
    'radiofona.com.gr': 'GR',
    'radio.org.ro': 'RO',
}

# host -> (parallel connections, minimum seconds between requests on one connection)
HOST_LIMITS = {
    'opml.radiotime.com': (2, 0.25),
    'radio.garden': (2, 0.3),
    'api.instant.audio': (2, 0.3),
    'onlineradiobox.com': (1, 0.8),
    'www.radio.net': (1, 0.8),
    'live24.gr': (1, 0.6),
}
DEFAULT_LIMIT = (1, 0.6)


# ── HTTP with cache + per-host politeness ──────────────────────────────────

class Http:
    def __init__(self, offline: bool = False):
        self.offline = offline
        self.session = requests.Session()
        self.session.headers['User-Agent'] = UA
        adapter = requests.adapters.HTTPAdapter(pool_connections=32, pool_maxsize=32)
        self.session.mount('https://', adapter)
        self.session.mount('http://', adapter)
        self._lock = threading.Lock()
        self._sems: dict[str, threading.Semaphore] = {}
        self._last: dict[str, float] = defaultdict(float)
        self.requests = Counter()
        CACHE.mkdir(parents=True, exist_ok=True)

    def _slot(self, host: str):
        with self._lock:
            if host not in self._sems:
                self._sems[host] = threading.Semaphore(HOST_LIMITS.get(host, DEFAULT_LIMIT)[0])
            return self._sems[host]

    def _wait(self, host: str):
        gap = HOST_LIMITS.get(host, DEFAULT_LIMIT)[1]
        while True:
            with self._lock:
                now = time.monotonic()
                ready = self._last[host] + gap
                if now >= ready:
                    self._last[host] = now
                    return
            time.sleep(ready - now)

    def get(self, url: str) -> str | None:
        heartbeat()
        key = hashlib.sha1(url.encode()).hexdigest()
        path = CACHE / key[:2] / key
        if path.exists():
            text = path.read_text(encoding='utf-8')
            return None if text == '\x00' else text
        if self.offline:
            return None
        host = urlparse(url).hostname or ''
        text = None
        with self._slot(host):
            for attempt in range(3):
                self._wait(host)
                try:
                    r = self.session.get(url, timeout=25)
                    self.requests[host] += 1
                    if r.status_code in (429, 500, 502, 503, 504):
                        time.sleep(3 * (attempt + 1))
                        continue
                    if r.status_code == 200:
                        r.encoding = r.encoding if r.encoding and 'charset' in r.headers.get('content-type', '') else 'utf-8'
                        text = r.text
                    break
                except requests.RequestException:
                    time.sleep(2 * (attempt + 1))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text if text is not None else '\x00', encoding='utf-8')
        return text

    def get_json(self, url: str):
        text = self.get(url)
        if not text:
            return None
        try:
            return json.loads(text)
        except ValueError:
            return None


def pmap(fn, items, workers=8):
    items = list(items)
    with ThreadPoolExecutor(workers) as ex:
        return list(ex.map(fn, items))


WATCHDOG_SECONDS = 180


def heartbeat():
    """Re-arm the watchdog: if nothing calls this for WATCHDOG_SECONDS the process dumps every
    thread's stack to stderr and exits with code 1, so run_until_done.sh restarts it (all pages
    and stream checks are cached on disk, so a restart only costs a minute or two)."""
    faulthandler.dump_traceback_later(WATCHDOG_SECONDS, exit=True)


def log(*a):
    heartbeat()
    print(*a, flush=True)


# ── Model ─────────────────────────────────────────────────────────────────

@dataclass
class Station:
    name: str
    cc: str
    src: str
    streams: list[str] = field(default_factory=list)
    city: str = ''
    lat: float | None = None
    lon: float | None = None
    precision: int = 0  # 0 exact, 1 city, 2 country
    freq: str = ''
    homepage: str = ''
    logo: str = ''
    tags: str = ''
    stream_host: str = ''  # Radio Garden only gives the host of its stream
    verified: str = ''  # verified stream url

    def to_json(self):
        return self.__dict__

    @staticmethod
    def from_json(d):
        return Station(**d)


# ── Normalisation (mirrors lib/radio/station_bundle.dart) ─────────────────

_GREEK_FOLD = str.maketrans({'ς': 'σ'})
_SPECIAL = {'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'þ': 'th', 'ı': 'i', 'ł': 'l', 'đ': 'd', 'ħ': 'h', 'ø': 'o', 'ə': 'e'}
NAME_STOP = {
    'radio', 'radyo', 'radijo', 'radiostanica', 'ραδιο', 'ραδιοφωνο', 'радио', 'радіо', 'fm', 'am', 'online', 'live',
    'the', 'web', 'webradio', 'stream', 'official', 'hd', 'tv',
}
FREQ_RE = re.compile(r'(?<![\d.,])(8[7-9]|9\d|10[0-8])[.,](\d{1,2})(?!\d)')


def fold(s: str) -> str:
    s = s.lower().translate(_GREEK_FOLD)
    s = ''.join(_SPECIAL.get(c, c) for c in s)
    s = unicodedata.normalize('NFKD', s)
    return ''.join(c for c in s if not unicodedata.combining(c))


def name_key(name: str) -> str:
    tokens = re.split(r'[^\w]+', fold(name))
    kept = [t for t in tokens if t and t not in NAME_STOP]
    key = ''.join(kept)
    return key or ''.join(tokens)


def stream_key(url: str) -> str:
    u = urlparse(url.strip())
    host = (u.hostname or '').lower()
    if host.startswith('www.'):
        host = host[4:]
    path = re.sub(r'/+$|;$|/;$', '', u.path or '')
    path = re.sub(r'\.(mp3|aac|aacp|ogg|m3u8?|pls)$', '', path, flags=re.I)
    port = f':{u.port}' if u.port and u.port not in (80, 443) else ''
    return f'{host}{port}{path}'.lower()


def extract_freq(name: str) -> str:
    m = FREQ_RE.search(name)
    return f'{m.group(1)}.{m.group(2)[0]}' if m else ''


def haversine(a_lat, a_lon, b_lat, b_lon):
    r = math.radians
    d = math.sin(r(b_lat - a_lat) / 2) ** 2 + math.cos(r(a_lat)) * math.cos(r(b_lat)) * math.sin(r(b_lon - a_lon) / 2) ** 2
    return 6371 * 2 * math.asin(math.sqrt(d))


# ── Geocoding: Radio Garden places + the app's GeoNames table ─────────────

class Geocoder:
    """City / station name / web address -> point, with the app's place table
    (tools/geo/build_places.py) plus Radio Garden's places."""

    def __init__(self, rg_places: list[dict]):
        places_json = json.loads((APP / 'assets' / 'geo' / 'places.json').read_text(encoding='utf-8'))
        self.places = {cc: places.read_entries(v) for cc, v in places_json['places'].items()}
        self.capitals = places_json['capitals']
        self.rg: dict[str, dict[str, tuple[float, float]]] = defaultdict(dict)
        name_to_cc = {v['rg']: cc for cc, v in COUNTRIES.items() if v['rg']}
        for p in rg_places:
            cc = name_to_cc.get(p.get('country'))
            if cc:
                self.rg[cc].setdefault(self.norm(p['title']), (p['geo'][1], p['geo'][0]))

    @staticmethod
    def norm(name: str) -> str:
        """Identical to normalizePlaceName() in place_locator.dart."""
        return places.normalize(name)

    def locate(self, cc: str, city: str, name: str, homepage: str = ''):
        """(lat, lon, precision): declared city, a town/region in the name, one in the web
        address, else the capital (precision 2)."""
        table = self.places.get(cc, {})
        rg = self.rg.get(cc, {})
        if city:
            candidates = [city] + [t for t in re.split(r'[,/()\-]|\s+', city) if len(t) >= 4]
            for c in candidates:
                k = self.norm(c)
                if not k:
                    continue
                if k in table:
                    return table[k][0], table[k][1], 1
                if k in rg:
                    return rg[k][0], rg[k][1], 1

        def notable(k):
            p = table.get(k)
            return p is not None and p[2] >= 1 and k not in places.TOO_COMMON

        words = [self.norm(t) for t in re.split(r'[\s\-_.,|/()!:+&]+', name)]
        words = [w for w in words if w]
        for k in [a + b for a, b in zip(words, words[1:])] + words:
            if len(k) >= 5 and notable(k):
                return table[k][0], table[k][1], 1
        host = (urlparse(homepage).hostname or '').lower()
        if host and not any(g in host for g in ('facebook', 'youtube', 'instagram', 'live24', 'radio.garden', 'tunein',
                                                  'onlineradiobox', 'radio.net', 'zeno.fm', 'blogspot', 'wordpress')):
            for label in host.split('.')[:-1]:
                label = self.norm(label)
                for ln in range(min(len(label), 24), 4, -1):
                    for i in range(0, len(label) - ln + 1):
                        k = label[i:i + ln]
                        if notable(k):
                            return table[k][0], table[k][1], 1
        cap = self.capitals.get(cc)
        if cap:
            return cap[0], cap[1], 2
        return None, None, 2


# ── Sources ───────────────────────────────────────────────────────────────

RG = 'https://radio.garden/api/ara/content'


def rg_listen_url(channel_id: str) -> str:
    return f'{RG}/listen/{channel_id}/channel.mp3'


def src_radio_garden(http: Http, ccs) -> tuple[list[Station], list[dict]]:
    data = http.get_json(f'{RG}/places')
    places = data['data']['list'] if data else []
    wanted = {COUNTRIES[cc]['rg']: cc for cc in ccs if COUNTRIES[cc]['rg']}
    todo = [p for p in places if p.get('country') in wanted]
    log(f'[rg] {len(todo)} places')

    def one(p):
        res = []
        page = http.get_json(f"{RG}/page/{p['id']}/channels")
        if not page:
            return res
        for block in page.get('data', {}).get('content', []):
            for item in block.get('items', []):
                ch = item.get('page') or {}
                if ch.get('type') != 'channel':
                    continue
                cid = ch['url'].rstrip('/').split('/')[-1]
                res.append(Station(
                    name=ch.get('title', '').strip(), cc=wanted[p['country']], src='rg',
                    streams=[rg_listen_url(cid)], city=p['title'], lat=p['geo'][1], lon=p['geo'][0],
                    precision=0, stream_host=(ch.get('stream') or '').lower(),
                ))
        return res

    out = [s for chunk in pmap(one, todo, 4) for s in chunk]
    return out, places


_ORB_LI = re.compile(r'<li class="stations__station"[^>]*>(.*?)</li>\s*(?=<li class="stations__station"|</ul>)', re.S)


def _attr(tag: str, name: str) -> str:
    m = re.search(rf'\s{name}="([^"]*)"', tag)
    return unescape(m.group(1)) if m else ''


def unescape(s: str) -> str:
    import html
    return html.unescape(s).strip()


def parse_orb_list(html_text: str) -> list[dict]:
    res = []
    for m in re.finditer(r'<button[^>]*class="b-play station_play"[^>]*>', html_text):
        tag = m.group(0)
        stream = _attr(tag, 'stream')
        if not stream:
            continue
        # tags live in the <li> just before the button
        start = html_text.rfind('<li class="stations__station"', 0, m.start())
        chunk = html_text[start:m.start()] if start >= 0 else ''
        tags = re.findall(r'/genre/[^"]+/" class="ajax">([^<]+)<', chunk)
        logo = _attr(tag, 'radioImg')
        res.append(dict(id=_attr(tag, 'radioId'), name=_attr(tag, 'radioName'), stream=stream,
                        logo=('https:' + logo) if logo.startswith('//') else logo,
                        tags=','.join(unescape(t) for t in tags)))
    return res


def _max_page(html_text: str) -> int:
    pages = [int(x) for x in re.findall(r'\?p=(\d+)', html_text)]
    return max(pages) if pages else 0


def src_onlineradiobox(http: Http, ccs) -> list[Station]:
    out: list[Station] = []
    for cc in ccs:
        code = COUNTRIES[cc]['orb']
        if not code:
            continue
        base = f'https://onlineradiobox.com/{code}/'
        home = http.get(base)
        if not home:
            continue
        by_id: dict[str, Station] = {}

        def add(items, city=''):
            for it in items:
                s = by_id.get(it['id'])
                if s is None:
                    by_id[it['id']] = Station(name=it['name'], cc=cc, src='orb', streams=[it['stream']], logo=it['logo'],
                                              tags=it['tags'], city=city)
                elif city and not s.city:
                    s.city = city

        def pages(url, first):
            yield first
            for p in range(1, _max_page(first) + 1):
                t = http.get(f'{url}?p={p}')
                if t:
                    yield t

        regions = sorted(set(re.findall(rf'href="/{code}/([^"/?]+-)/"', home)))
        region_pages = pmap(lambda r: http.get(f'{base}{r}/'), regions, 2)
        cities = set()
        for t in region_pages:
            if t:
                cities.update(c for c in re.findall(rf'href="/{code}/([A-Z][^"/?]*)"', t) if not c.endswith('-'))
        cities -= set(regions)

        def city_items(c):
            url = f'{base}{c}'
            first = http.get(url)
            if not first:
                return c, []
            return c, [it for t in pages(url, first) for it in parse_orb_list(t)]

        for c, items in pmap(city_items, sorted(cities), 2):
            add(items, c.replace('_', ' ').split('-')[0])
        for t in pages(base, home):
            add(parse_orb_list(t))
        log(f'[orb] {cc}: {len(regions)} regions, {len(cities)} cities, {len(by_id)} stations')
        out.extend(by_id.values())
    return out


OPML = 'https://opml.radiotime.com'


def _opml(http: Http, url: str):
    url = url.replace('http://', 'https://')
    sep = '&' if '?' in url else '?'
    return http.get_json(f'{url}{sep}render=json')


def _opml_walk(http: Http, url: str, depth=0):
    """Audio outlines of a TuneIn browse page, following 'more stations' pages."""
    data = _opml(http, url)
    if not data:
        return []
    found = []

    def visit(nodes):
        for n in nodes:
            if n.get('type') == 'audio' and n.get('item') == 'station':
                found.append(n)
            elif n.get('type') == 'link' and n.get('key') in ('nextStations', 'nextShows') and depth < 30 and n.get('key') == 'nextStations':
                found.extend(_opml_walk(http, n['URL'], depth + 1))
            if n.get('children'):
                visit(n['children'])

    visit(data.get('body', []))
    return found


def clean_tunein_name(text: str) -> str:
    return re.sub(r'\s*\([^()]*\)\s*$', '', text).strip()


def src_tunein(http: Http, ccs) -> list[Station]:
    out = []
    for cc in ccs:
        rid = COUNTRIES[cc]['tunein']
        if not rid:
            continue
        root = _opml(http, f'{OPML}/Browse.ashx?id={rid}')
        if not root:
            continue
        cities = [(n['text'], n['URL']) for n in root.get('body', [])
                  if n.get('type') == 'link' and re.fullmatch(r'r\d+', n.get('guide_id') or '')]
        letters = []
        by_name = _opml(http, f'{OPML}/Browse.ashx?id={rid}&pivot=name&filter=country')
        for n in (by_name or {}).get('body', []):
            if n.get('type') == 'link':
                letters.append(n['URL'])
        stations: dict[str, Station] = {}
        for city, url in cities:
            for n in _opml_walk(http, url):
                gid = n['guide_id']
                stations.setdefault(gid, Station(name=clean_tunein_name(n['text']), cc=cc, src='tunein', city=city,
                                                 logo=n.get('image', ''), freq=extract_freq(n['text'])))
        for url in [f'{OPML}/Browse.ashx?id={rid}'] + letters:
            for n in _opml_walk(http, url):
                gid = n['guide_id']
                stations.setdefault(gid, Station(name=clean_tunein_name(n['text']), cc=cc, src='tunein',
                                                 logo=n.get('image', ''), freq=extract_freq(n['text'])))

        def tune(item):
            gid, s = item
            data = _opml(http, f'{OPML}/Tune.ashx?id={gid}')
            urls = []
            for b in (data or {}).get('body', []):
                u = b.get('url')
                if u and 'notcompatible' not in u and 'nostream' not in u:
                    urls.append((-int(b.get('reliability') or 0), u))
            s.streams = [u for _, u in sorted(urls)]
            return s

        tuned = pmap(tune, stations.items(), 2)
        log(f'[tunein] {cc}: {len(cities)} cities, {len(tuned)} stations')
        out.extend(s for s in tuned if s.streams)
    return out


def live24_stream_candidates(src: str) -> list[str]:
    """live24 configs sometimes point at the SHOUTcast v2 status page (index.html?sid=N)."""
    m = re.match(r'(https?://[^/]+)/index\.html\?sid=(\d+)', src)
    if m:
        return [f'{m.group(1)}/stream/{m.group(2)}/', f'{m.group(1)}/;']
    return [src]


def parse_live24_station(html_text: str) -> dict | None:
    def cfg(key):
        m = re.search(rf"\b{key}:\s*'([^']*)'", html_text)
        return unescape(m.group(1)) if m else ''

    src = cfg('streamsrc')
    name = cfg('radioStationName').rstrip(' -')
    if not src or src == '-1' or not name:
        return None
    mobile = cfg('mobileStream')
    streams = live24_stream_candidates(src)
    if mobile and mobile != '-1' and mobile.startswith('http'):
        streams.append(mobile)
    return dict(name=name, streams=streams, homepage=cfg('station_website'), city=cfg('area'))


def src_live24(http: Http, ccs) -> list[Station]:
    if 'GR' not in ccs:
        return []
    base = 'https://live24.gr'
    listing = http.get(f'{base}/list.jsp') or ''
    areas = sorted(set(re.findall(r'radio\.jsp\?aid=(\d+)', listing)), key=int)
    links = set(re.findall(r'href="(/radio/[^"]+)"', listing))
    for t in pmap(lambda a: http.get(f'{base}/radio.jsp?aid={a}'), areas, 1):
        if t:
            links.update(re.findall(r'href="(/radio/[^"]+)"', t))
    links = sorted(l.replace('&amp;', '&') for l in links)

    def one(link):
        t = http.get(base + link)
        info = parse_live24_station(t or '')
        if not info:
            return None
        return Station(name=info['name'], cc='GR', src='live24', streams=info['streams'], homepage=info['homepage'],
                       city=info['city'], freq=extract_freq(info['name']))

    out = [s for s in pmap(one, links, 1) if s]
    log(f'[live24] {len(areas)} areas, {len(links)} pages, {len(out)} stations')
    return out


def split_city(title: str) -> tuple[str, str]:
    m = re.match(r'^(.*?)\s*\(([^()]+)\)\s*$', title)
    return (m.group(1).strip(), m.group(2).strip()) if m else (title.strip(), '')


def src_instant_audio(http: Http, ccs) -> list[Station]:
    out = []
    skip = re.compile(r'^(dmca|zanr|zanrovi|zhanr|zhanrove|gen|genuri|eidos|eide|zanri|pomoc|pomos|ajutor|boetheia|'
                      r'politika|politica|politike|ukljuc|vkljuc|dobavete|adauga|symperil|static)', re.I)
    for site, cc in INSTANT_AUDIO_SITES.items():
        if cc not in ccs:
            continue
        home = http.get(f'https://{site}/') or ''
        m = re.search(r'api\.instant\.audio/data/streams/(\d+)/', home)
        if not m:
            log(f'[instant] {site}: no site id')
            continue
        site_id = m.group(1)
        sitemap = http.get(f'https://{site}/sitemap.xml') or ''  # the homepage shows only part of the list
        found = re.findall(rf'href="https://{re.escape(site)}/([a-z0-9][a-z0-9-]*)/"', home)
        found += re.findall(rf'<loc>https://{re.escape(site)}/([a-z0-9][a-z0-9-]*)/</loc>', sitemap)
        slugs = sorted({s for s in found if not skip.match(s)})

        def one(slug):
            d = http.get_json(f'https://api.instant.audio/data/streams/{site_id}/{slug}')
            if not d or not d.get('success'):
                return None
            st = d['result']['station']
            streams = []
            for s in sorted(d['result'].get('streams', []), key=lambda s: (s.get('isContainer', False), s.get('id', 0))):
                if 'html' in (s.get('mime') or '').lower():
                    continue
                streams.append(s['url'])
            if not streams:
                return None
            name, city = split_city(st.get('title') or slug)
            signal = st.get('signal') or ''
            return Station(name=name, cc=cc, src='instant', streams=streams, city=city, homepage=st.get('url') or '',
                           logo=f"https://cdn.instant.audio/images/logos/{site.replace('.', '-')}/{slug}.png",
                           freq=extract_freq(signal) or extract_freq(name))

        res = [s for s in pmap(one, slugs, 2) if s]
        log(f'[instant] {site}: {len(slugs)} slugs, {len(res)} stations')
        out.extend(res)
    return out


def _next_f_text(html_text: str) -> str:
    # The string literals are decoded with the C JSON scanner: a regex over these
    # ~600 KB pages took seconds per page.
    parts = []
    decoder = json.JSONDecoder()
    marker = 'self.__next_f.push([1,'
    pos = html_text.find(marker)
    while pos >= 0:
        start = pos + len(marker)
        try:
            value, end = decoder.raw_decode(html_text, start)
            if isinstance(value, str):
                parts.append(value)
            pos = html_text.find(marker, end)
        except ValueError:
            pos = html_text.find(marker, start)
    return ''.join(parts)


def parse_radionet_station(html_text: str) -> dict | None:
    text = _next_f_text(html_text)
    i = text.find('"pageBroadcast":')
    if i < 0:
        return None
    try:
        obj, _ = json.JSONDecoder().raw_decode(text, i + len('"pageBroadcast":'))
    except ValueError:
        return None
    streams = [s['url'] for s in obj.get('streams', []) if s.get('url') and s.get('status', 'VALID') == 'VALID']
    if not streams:
        return None
    return dict(name=obj.get('name', ''), streams=streams, city=obj.get('city') or '', homepage=obj.get('homepageUrl') or '',
                logo=obj.get('logo300x300') or obj.get('logo175x175') or '', tags=','.join(obj.get('genres') or []))


def src_radionet(http: Http, ccs) -> list[Station]:
    out = []
    for cc in ccs:
        slug = COUNTRIES[cc]['rnet']
        if not slug:
            continue
        url = f'https://www.radio.net/country/{slug}'
        first = http.get(url) or ''
        m = re.search(r'"numberOfItems":"(\d+)"', first)
        total = int(m.group(1)) if m else 0
        ids = re.findall(r'"url":"https://www\.radio\.net/s/([^"/]+)"', first)
        per_page = max(len(set(ids)), 1)
        for p in range(2, math.ceil(total / per_page) + 1):
            ids += re.findall(r'"url":"https://www\.radio\.net/s/([^"/]+)"', http.get(f'{url}?p={p}') or '')
        ids = list(dict.fromkeys(ids))

        def one(sid):
            info = parse_radionet_station(http.get(f'https://www.radio.net/s/{sid}') or '')
            if not info:
                return None
            return Station(name=info['name'], cc=cc, src='rnet', streams=info['streams'], city=info['city'],
                           homepage=info['homepage'], logo=info['logo'], tags=info['tags'], freq=extract_freq(info['name']))

        res = [s for s in pmap(one, ids, 1) if s]
        log(f'[rnet] {cc}: {total} listed, {len(ids)} ids, {len(res)} with streams')
        out.extend(res)
    return out


def radio_browser(http: Http, cc: str) -> list[dict]:
    for host in ('de1.api.radio-browser.info', 'nl1.api.radio-browser.info', 'at1.api.radio-browser.info'):
        data = http.get_json(f'https://{host}/json/stations/search?countrycode={cc}&hidebroken=true&limit=20000')
        if data is not None:
            return data
    return []


# ── Stream verification ───────────────────────────────────────────────────

AUDIO_PATH = re.compile(r'(\.mp3|\.aac|\.aacp|\.ogg|\.opus|\.m3u8?|\.pls)(\?|$)|/stream|/live|/listen|/;|:\d{4,5}(/|$)', re.I)


def parse_playlist(body: str) -> str | None:
    for raw in body.splitlines():
        line = raw.strip()
        m = re.match(r'^File\d+\s*=\s*(\S+)', line, re.I)
        if m:
            return m.group(1)
        if line.startswith(('http://', 'https://')):
            return line
    return None


def _read_capped(r, max_bytes: int, seconds: float) -> bytes:
    """Read at most max_bytes, giving up after `seconds` total (streams that trickle forever)."""
    deadline = time.monotonic() + seconds
    buf = bytearray()
    for chunk in r.iter_content(8192):
        buf += chunk
        if len(buf) >= max_bytes or time.monotonic() > deadline:
            break
    return bytes(buf[:max_bytes])


class Verifier:
    def __init__(self):
        self.path = WORK / 'verify_cache.json'
        self.cache: dict[str, str] = json.loads(self.path.read_text('utf-8')) if self.path.exists() else {}
        self.lock = threading.Lock()
        self.host_sems: dict[str, threading.Semaphore] = {}

    def save(self):
        WORK.mkdir(parents=True, exist_ok=True)
        with self.lock:
            self.path.write_text(json.dumps(self.cache), encoding='utf-8')

    def _sem(self, host):
        with self.lock:
            return self.host_sems.setdefault(host, threading.Semaphore(2))

    def check(self, url: str, depth=0) -> str:
        """'' if dead, else the playable url (playlists are followed)."""
        with self.lock:
            if url in self.cache:
                return self.cache[url]
        result = ''
        inner = None
        host = urlparse(url).hostname or ''
        try:
            with self._sem(host):
                with requests.get(url, stream=True, timeout=(6, 8), allow_redirects=True,
                                  headers={'User-Agent': UA, 'Icy-MetaData': '0'}) as r:
                    ctype = r.headers.get('content-type', '').lower()
                    icy = any(k.lower().startswith('icy-') for k in r.headers)
                    if r.status_code < 400:
                        if 'mpegurl' in ctype or 'scpls' in ctype or re.search(r'\.(m3u8?|pls)(\?|$)', url, re.I):
                            body = _read_capped(r, 200000, 12).decode('utf-8', 'replace')
                            if body.lstrip().startswith('#EXTM3U') and '#EXT-X-' in body:
                                result = url  # HLS
                            elif depth < 2:
                                inner = parse_playlist(body)
                        elif icy or ctype.startswith('audio/') or 'ogg' in ctype or 'aac' in ctype or 'mpeg' in ctype or \
                                ('octet-stream' in ctype and AUDIO_PATH.search(url)):
                            chunk = next(r.iter_content(2048), b'')
                            if chunk and not chunk.lstrip().startswith((b'<', b'{')):
                                result = url
        except Exception:
            result = ''
        # Follow the playlist only after releasing this host's semaphore: recursing while
        # holding it deadlocks when two threads do it on the same host.
        if not result and inner:
            result = self.check(inner, depth + 1)
        with self.lock:
            self.cache[url] = result
        return result


def verify_all(stations: list[Station], offline: bool):
    ver = Verifier()
    todo = [s for s in stations if s.src != 'rg']
    done = [0]

    def one(s: Station):
        for u in s.streams[:4]:
            if offline:
                ok = ver.cache.get(u, '')
            else:
                ok = ver.check(u)
            if ok:
                s.verified = ok
                break
        heartbeat()
        done[0] += 1
        if done[0] % 100 == 0:
            ver.save()
        if done[0] % 500 == 0:
            log(f'[verify] {done[0]}/{len(todo)}')

    pmap(one, todo, 24)
    ver.save()


# ── Dedupe ────────────────────────────────────────────────────────────────

SOURCE_RANK = {'live24': 0, 'instant': 1, 'rnet': 2, 'orb': 3, 'tunein': 4, 'rg': 5}


def same_place(a: Station, b: Station) -> bool:
    if a.lat is None or b.lat is None or a.precision == 2 or b.precision == 2:
        return True
    return haversine(a.lat, a.lon, b.lat, b.lon) < 60


def merge(stations: list[Station]) -> list[Station]:
    """Union of records that share a stream or (same country, same name key, compatible place)."""
    parent = list(range(len(stations)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    # Position of each group's first precisely placed member: a record placed only at the
    # capital must not chain two different local stations ("Kiss" Athens / "Kiss" Thessaloniki).
    gloc: dict[int, tuple[float, float]] = {}

    def precise(s: Station):
        return (s.lat, s.lon) if s.lat is not None and s.precision != 2 else None

    def union(i, j):
        ri, rj = find(i), find(j)
        if ri != rj:
            parent[ri] = rj
            if rj not in gloc and ri in gloc:
                gloc[rj] = gloc[ri]

    def compatible(i, j):
        a, b = gloc.get(find(i)), gloc.get(find(j))
        return a is None or b is None or haversine(a[0], a[1], b[0], b[1]) < 60

    for i, s in enumerate(stations):
        if precise(s):
            gloc[i] = precise(s)

    by_stream: dict[str, int] = {}
    by_name: dict[tuple, list[int]] = defaultdict(list)
    for i, s in enumerate(stations):
        if s.verified:
            k = stream_key(s.verified)
            if k in by_stream:
                union(i, by_stream[k])
            else:
                by_stream[k] = i
        nk = name_key(s.name)
        if len(nk) >= 3:
            for j in by_name[(s.cc, nk)]:
                if same_place(s, stations[j]) and compatible(i, j):
                    union(i, j)
                    break
            by_name[(s.cc, nk)].append(i)

    groups: dict[int, list[Station]] = defaultdict(list)
    for i, s in enumerate(stations):
        groups[find(i)].append(s)

    merged = []
    for members in groups.values():
        members.sort(key=lambda s: SOURCE_RANK.get(s.src, 9))
        best = next((m for m in members if m.verified), None)
        rg = next((m for m in members if m.src == 'rg'), None)
        if best is None and rg is None:
            continue  # nothing playable
        base = best or rg
        out = Station(**{**base.__dict__})
        out.src = ','.join(sorted({m.src for m in members}, key=lambda x: SOURCE_RANK.get(x, 9)))
        out.streams = [base.verified or base.streams[0]]
        for m in members:  # fill gaps from other sources
            out.homepage = out.homepage or m.homepage
            out.logo = out.logo or m.logo
            out.freq = out.freq or m.freq
            out.tags = out.tags or m.tags
            out.city = out.city or m.city
        if rg is not None:  # Radio Garden coordinates are the most precise we have
            out.lat, out.lon, out.precision = rg.lat, rg.lon, 0
            out.city = rg.city
        merged.append(out)
    return merged


def drop_radio_browser_dupes(stations: list[Station], rb: list[dict]) -> tuple[list[Station], list[tuple[Station, dict]]]:
    """Splits harvested stations into new ones and (station, Radio Browser record) duplicates."""
    rb_streams: dict[str, dict] = {}
    rb_names = defaultdict(list)
    for r in rb:
        for u in (r.get('url_resolved'), r.get('url')):
            if u:
                rb_streams.setdefault(stream_key(u), r)
        nk = name_key(r.get('name') or '')
        if len(nk) >= 3:
            rb_names[nk].append(r)
    kept, dupes = [], []
    for s in stations:
        match = rb_streams.get(stream_key(s.streams[0]))
        if match is None:
            for r in rb_names.get(name_key(s.name), []):
                lat, lon = r.get('geo_lat'), r.get('geo_long')
                if lat is None or s.lat is None or s.precision == 2 or haversine(lat, lon, s.lat, s.lon) < 60:
                    match = r
                    break
        if match is None:
            kept.append(s)
        else:
            dupes.append((s, match))
    return kept, dupes


def geo_hints(dupes: list[tuple[Station, dict]]) -> dict[str, list]:
    """Radio Browser stations without coordinates that another source places in a town:
    uuid -> [lat, lon, precision, city]. The app applies them before its own guessing."""
    hints = {}
    for s, r in dupes:
        uuid = r.get('stationuuid')
        if not uuid or r.get('geo_lat') is not None or s.lat is None or s.precision == 2:
            continue
        hints[uuid] = [round(s.lat, 4), round(s.lon, 4), s.precision, s.city]
    return hints


# ── Main ──────────────────────────────────────────────────────────────────

def station_id(s: Station) -> str:
    return hashlib.sha1(f'{s.cc}|{name_key(s.name)}|{s.city}'.encode()).hexdigest()[:12]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--countries', default=','.join(COUNTRIES))
    ap.add_argument('--skip-verify', action='store_true', help='only use cached verification results')
    ap.add_argument('--offline', action='store_true', help='only use the HTTP cache')
    ap.add_argument('--sources', default='rg,orb,tunein,live24,instant,rnet')
    args = ap.parse_args()
    heartbeat()
    ccs = [c.strip().upper() for c in args.countries.split(',') if c.strip()]
    sources = set(args.sources.split(','))
    http = Http(offline=args.offline)
    WORK.mkdir(parents=True, exist_ok=True)

    raw: list[Station] = []
    rg_stations, rg_places = src_radio_garden(http, ccs) if 'rg' in sources else ([], [])
    if not rg_places:
        rg_places = (http.get_json(f'{RG}/places') or {}).get('data', {}).get('list', [])
    raw += rg_stations
    log(f'[rg] {len(rg_stations)} channels')
    fns = dict(orb=src_onlineradiobox, tunein=src_tunein, live24=src_live24, instant=src_instant_audio, rnet=src_radionet)
    with ThreadPoolExecutor(len(fns)) as ex:  # different hosts -> run sources side by side
        futures = {k: ex.submit(fn, http, ccs) for k, fn in fns.items() if k in sources}
        for k, f in futures.items():
            res = f.result()
            log(f'[{k}] total {len(res)}')
            raw += res
    raw = [s for s in raw if s.name and s.streams and s.cc]
    (WORK / 'raw.json').write_text(json.dumps([s.to_json() for s in raw], ensure_ascii=False), encoding='utf-8')
    log(f'raw records: {len(raw)}  requests: {dict(http.requests)}')

    verify_all(raw, offline=args.skip_verify or args.offline)
    log(f"verified: {sum(1 for s in raw if s.verified)} / {sum(1 for s in raw if s.src != 'rg')}")

    geo = Geocoder(rg_places)
    for s in raw:
        if s.lat is None:
            s.lat, s.lon, s.precision = geo.locate(s.cc, s.city, s.name, s.homepage)
        s.freq = s.freq or extract_freq(s.name)

    merged = merge(raw)
    final: list[Station] = []
    hints: dict[str, list] = {}
    report = {}
    for cc in ccs:
        rb = radio_browser(http, cc)
        mine = [s for s in merged if s.cc == cc]
        kept, dupes = drop_radio_browser_dupes(mine, rb)
        final += kept
        cc_hints = geo_hints(dupes)
        hints.update(cc_hints)
        report[cc] = dict(radio_browser=len(rb), harvested=len(mine), duplicates_of_rb=len(dupes), added=len(kept),
                          rb_geo_hints=len(cc_hints),
                          total=len(rb) + len(kept), rg_only=sum(1 for s in kept if s.src == 'rg'))
    final.sort(key=lambda s: (s.cc, s.name.lower()))

    fields = ['id', 'name', 'cc', 'city', 'lat', 'lon', 'precision', 'freq', 'url', 'homepage', 'logo', 'tags', 'src']
    rows = [[station_id(s), s.name, s.cc, s.city, round(s.lat, 4) if s.lat is not None else None,
             round(s.lon, 4) if s.lon is not None else None, s.precision, s.freq, s.streams[0], s.homepage, s.logo,
             s.tags[:80], s.src] for s in final]
    doc = dict(version=1, generated=time.strftime('%Y-%m-%d'), fields=fields, stations=rows, rbgeo=hints)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    data = json.dumps(doc, ensure_ascii=False, separators=(',', ':')).encode('utf-8')
    OUT.write_bytes(gzip.compress(data, 9, mtime=0))
    (WORK / 'report.json').write_text(json.dumps(report, indent=1), encoding='utf-8')
    log(f'wrote {OUT} ({len(rows)} stations, {len(data) / 1e6:.2f} MB json, {OUT.stat().st_size / 1e6:.2f} MB gz)')
    log(f"{'cc':4}{'RB':>6}{'added':>7}{'total':>7}{'rg-only':>9}{'hints':>7}")
    for cc, r in report.items():
        log(f"{cc:4}{r['radio_browser']:>6}{r['added']:>7}{r['total']:>7}{r['rg_only']:>9}{r['rb_geo_hints']:>7}")


if __name__ == '__main__':
    sys.exit(main())
