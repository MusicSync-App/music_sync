"""Parser / dedupe tests for harvest.py:  python -m unittest tools/radio_harvest/test_harvest.py"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import harvest as h  # noqa: E402


class ParseTests(unittest.TestCase):
    def test_orb_list(self):
        html = '''<li class="stations__station" role="listitem" radioID="15543">
          <ul class="stations__station__tags" role="list">
          <li><a href="/gr/genre/rock/" class="ajax">rock</a></li>
          <li><a href="/gr/genre/r_n_b/" class="ajax">r&#39;n&#39;b</a></li></ul>
          <button  listeners="50" class="b-play station_play" stream="https://i4.streams.ovh/sc/bluesrad/stream"
           streamType="mp3" radioId="gr.bluesradio" radioImg="//cdn.onlineradiobox.com/img/l/3/15543.v20.png"
           radioName="Blues &amp; Soul"></button></li>'''
        [item] = h.parse_orb_list(html)
        self.assertEqual(item['id'], 'gr.bluesradio')
        self.assertEqual(item['name'], 'Blues & Soul')
        self.assertEqual(item['stream'], 'https://i4.streams.ovh/sc/bluesrad/stream')
        self.assertEqual(item['logo'], 'https://cdn.onlineradiobox.com/img/l/3/15543.v20.png')
        self.assertEqual(item['tags'], "rock,r'n'b")

    def test_live24_station(self):
        html = """L24 = { config: { service_id: 1311,
            streamsrc: 'https://loki.mental-media.gr:8038/index.html?sid=1', stream: this.streamsrc,
            station_website: 'http://www.ecclesia.gr', radioStationName: 'Church of Greece 89.5 -',
            mobileStream: '-1', area: 'Αθήνα' } }"""
        info = h.parse_live24_station(html)
        self.assertEqual(info['name'], 'Church of Greece 89.5')
        self.assertEqual(info['city'], 'Αθήνα')
        self.assertEqual(info['streams'], ['https://loki.mental-media.gr:8038/stream/1/', 'https://loki.mental-media.gr:8038/;'])
        self.assertIsNone(h.parse_live24_station('<html>no config</html>'))

    def test_radionet_station(self):
        payload = json.dumps('f:[{"pageBroadcast":{"id":"x","name":"Radyo X","city":"Izmir","homepageUrl":"https://x.tr",'
                             '"genres":["Pop"],"streams":[{"url":"https://s.x.tr/live","status":"VALID"},'
                             '{"url":"https://dead","status":"BROKEN"}]}}]')
        html = f'<script>self.__next_f.push([1,{payload}])</script>'
        info = h.parse_radionet_station(html)
        self.assertEqual(info['name'], 'Radyo X')
        self.assertEqual(info['city'], 'Izmir')
        self.assertEqual(info['streams'], ['https://s.x.tr/live'])

    def test_helpers(self):
        self.assertEqual(h.clean_tunein_name('Zoo Radio 90.8 (Top 40 & Pop Music)'), 'Zoo Radio 90.8')
        self.assertEqual(h.split_city('Дарик радио (София)'), ('Дарик радио', 'София'))
        self.assertEqual(h.extract_freq('Zoo 90,8'), '90.8')
        self.assertEqual(h.extract_freq('Radio 1234'), '')
        self.assertEqual(h.parse_playlist('[playlist]\nFile1=http://a/b\n'), 'http://a/b')
        self.assertEqual(h.parse_playlist('#EXTM3U\nhttp://c/d\n'), 'http://c/d')


class DedupeTests(unittest.TestCase):
    def test_keys(self):
        self.assertEqual(h.name_key('Radio Kiss FM'), h.name_key('kiss'))
        self.assertEqual(h.name_key('Radyo Güneş'), h.name_key('RADYO GUNES'))
        self.assertEqual(h.stream_key('http://www.a.gr:80/live/'), h.stream_key('https://a.gr/live'))
        self.assertEqual(h.stream_key('http://a.gr:8000/;'), 'a.gr:8000')

    def test_merge_prefers_verified_stream_and_radio_garden_position(self):
        rg = h.Station(name='Kiss FM', cc='GR', src='rg', streams=['https://radio.garden/x'], city='Athens',
                       lat=37.98, lon=23.72, precision=0)
        orb = h.Station(name='Radio Kiss', cc='GR', src='orb', streams=['https://kiss/live'], verified='https://kiss/live',
                        lat=37.98, lon=23.73, precision=2, logo='logo.png')
        far = h.Station(name='Kiss', cc='GR', src='tunein', streams=['https://kiss2/live'], verified='https://kiss2/live',
                        lat=40.64, lon=22.94, precision=1)
        dead = h.Station(name='Dead', cc='GR', src='orb', streams=['https://dead'])
        merged = sorted(h.merge([rg, orb, far, dead]), key=lambda s: s.lat)
        self.assertEqual(len(merged), 2)  # Atena (rg+orb), Salonic; cel fără stream verificat dispare
        athens = merged[0]
        self.assertEqual(athens.streams, ['https://kiss/live'])
        self.assertEqual((athens.lat, athens.precision, athens.city), (37.98, 0, 'Athens'))
        self.assertEqual(athens.logo, 'logo.png')
        self.assertEqual(athens.src, 'orb,rg')

    def test_drop_radio_browser_dupes(self):
        a = h.Station(name='Derti', cc='GR', src='orb', streams=['https://derti/live'], lat=37.9, lon=23.7, precision=1)
        b = h.Station(name='New One', cc='GR', src='orb', streams=['https://new/live'], lat=37.9, lon=23.7, precision=1)
        c = h.Station(name='Other', cc='GR', src='orb', streams=['http://rb-stream/x/'], lat=37.9, lon=23.7, precision=1)
        rb = [{'name': 'Derti 98.6', 'url': 'http://elsewhere'},
              {'name': 'Derti', 'url': 'http://elsewhere2', 'stationuuid': 'u-derti'},
              {'name': 'zzz', 'url_resolved': 'https://rb-stream/x', 'stationuuid': 'u-zzz', 'geo_lat': 1, 'geo_long': 2}]
        kept, dupes = h.drop_radio_browser_dupes([a, b, c], rb)
        self.assertEqual([s.name for s in kept], ['New One'])
        self.assertEqual(len(dupes), 2)
        # only the Radio Browser record without coordinates gets a hint
        self.assertEqual(h.geo_hints(dupes), {'u-derti': [37.9, 23.7, 1, '']})


if __name__ == '__main__':
    unittest.main()
