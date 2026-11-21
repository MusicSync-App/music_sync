import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicsync_app/radio/radio_garden.dart';
import 'package:musicsync_app/radio/radio_station.dart';
import 'package:musicsync_app/radio/station_bundle.dart';

RadioStation _rb(String name, String url, {String cc = 'GR', double? lat, double? lon}) =>
    RadioStation(uuid: 'rb-$name', name: name, streamUrl: url, countryCode: cc, lat: lat, lon: lon);

RadioStation _extra(String id, String name, String url, {String cc = 'GR', double? lat, double? lon}) =>
    RadioStation(uuid: '$kBundleUuidPrefix$id', name: name, streamUrl: url, countryCode: cc, lat: lat, lon: lon);

void main() {
  group('parseStationBundle', () {
    const raw = '{"version":1,"generated":"2026-11-21",'
        '"fields":["id","name","cc","city","lat","lon","precision","freq","url","homepage","logo","tags","src"],'
        '"stations":['
        '["a1","Derti 98.6","gr","Αθήνα",37.98,23.73,1,"98.6","https://derti.live24.gr/derty1000","http://www.derti.gr","","laika","live24"],'
        '["b2","Radio Energy","BG","София",42.69,23.32,0,"90.8","https://x.example/live.m3u8","","","","instant,rg"],'
        '["c3","","TR","",null,null,2,"","https://broken","","","",""],'
        '["d4","Capital FM","KZ","",51.16,71.47,2,"","http://kz.example:8000/;","","","","orb"]'
        ']}';

    test('maps rows to stations and skips incomplete ones', () {
      final bundle = parseStationBundle(raw);
      expect(bundle.generated, '2026-11-21');
      expect(bundle.length, 3);
      expect(bundle.covers('gr'), isTrue);
      expect(bundle.covers('TR'), isFalse); // singurul rând TR nu are nume

      final derti = bundle.forCountry('GR').single;
      expect(derti.uuid, 'bundle-a1');
      expect(derti.countryCode, 'GR');
      expect(derti.state, 'Αθήνα');
      expect(derti.precision, LocationPrecision.city);
      expect(derti.homepage, 'http://www.derti.gr');
      expect(isRadioBrowserStation(derti), isFalse);

      final energy = bundle.forCountry('BG').single;
      expect(energy.isHls, isTrue);
      expect(energy.precision, LocationPrecision.exact);
      expect(energy.fmFrequency, '90.8 FM'); // din câmpul freq, nu din nume
      expect(bundle.forCountry('KZ').single.precision, LocationPrecision.country);
    });

    test('decodes the gzipped form', () {
      final gz = gzip.encode(utf8.encode(raw));
      expect(decodeStationBundle(Uint8List.fromList(gz)).length, 3);
    });

    test('search ignores case and diacritics', () {
      final bundle = parseStationBundle(raw);
      expect(bundle.search('derti').map((s) => s.uuid), ['bundle-a1']);
      expect(bundle.search('ENERGY', countryCode: 'BG'), hasLength(1));
      expect(bundle.search('energy', countryCode: 'GR'), isEmpty);
    });

    test('frequency survives toJson/fromJson', () {
      final s = parseStationBundle(raw).forCountry('BG').single;
      final copy = RadioStation.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(copy.frequency, '90.8');
      expect(copy.withLocation(1, 2, LocationPrecision.city).frequency, '90.8');
    });
  });

  test('the generated asset parses and covers the target region', () {
    final file = File(kStationBundleAsset);
    if (!file.existsSync()) return; // asset-ul e generat de tools/radio_harvest
    final bundle = decodeStationBundle(file.readAsBytesSync());
    expect(bundle.length, greaterThan(1000));
    for (final cc in ['GR', 'TR', 'RO', 'BG', 'RS', 'AL', 'GE', 'KZ']) {
      expect(bundle.covers(cc), isTrue, reason: cc);
    }
    for (final s in bundle.all) {
      expect(s.hasLocation, isTrue, reason: s.name);
      expect(s.streamUrl, startsWith('http'));
    }
  });

  test('rbgeo hints place Radio Browser stations the other catalogues know', () {
    final bundle = parseStationBundle('{"fields":["id"],"stations":[],'
        '"rbgeo":{"u1":[37.75,26.97,1,"Samos"],"u2":[40.3,21.8,0,""],"bad":["x"]}}');
    expect(bundle.rbGeo.keys, unorderedEquals(['u1', 'u2']));
    final stations = [
      const RadioStation(uuid: 'u1', name: 'Anemos', streamUrl: 'http://a'),
      const RadioStation(uuid: 'u2', name: 'Ble', streamUrl: 'http://b', state: 'Kozani', lat: 37.98, lon: 23.73,
          precision: LocationPrecision.country),
      const RadioStation(uuid: 'u3', name: 'Other', streamUrl: 'http://c'),
      const RadioStation(uuid: 'u1', name: 'Has coords', streamUrl: 'http://d', lat: 1, lon: 2),
    ];
    final placed = applyGeoHints(stations, bundle.rbGeo);
    expect(placed[0].lat, 37.75);
    expect(placed[0].state, 'Samos');
    expect(placed[0].precision, LocationPrecision.city);
    expect(placed[1].lat, 40.3); // era doar la capitală
    expect(placed[1].state, 'Kozani'); // orașul declarat rămâne
    expect(placed[1].precision, LocationPrecision.exact);
    expect(identical(placed[2], stations[2]), isTrue);
    expect(placed[3].lat, 1); // coordonatele reale nu se schimbă
  });

  group('keys', () {
    test('stationNameKey drops generic words and accents', () {
      expect(stationNameKey('Radio Kiss FM'), stationNameKey('KISS'));
      expect(stationNameKey('Radyo Güneş'), stationNameKey('radyo gunes'));
      expect(stationNameKey('Ράδιο Λαμία'), stationNameKey('ΡΑΔΙΟ ΛΑΜΙΑ'));
      expect(stationNameKey('Radio'), 'radio'); // doar cuvinte generice -> păstrăm tot
      expect(stationNameKey('Derti 98.6'), isNot(stationNameKey('Derti 98.9')));
    });

    test('streamKey ignores scheme, default ports, trailing ; and extension', () {
      expect(streamKey('http://www.host.gr:80/live/'), streamKey('https://host.gr/live'));
      expect(streamKey('http://host.gr:8000/;'), 'host.gr:8000');
      expect(streamKey('https://host.gr/stream.mp3'), streamKey('https://host.gr/stream'));
      expect(streamKey('http://host.gr:8000/a'), isNot(streamKey('http://host.gr:8002/a')));
    });
  });

  group('mergeStations', () {
    test('keeps primary, drops extras with the same stream or name nearby', () {
      final primary = [
        _rb('Derti 98.6', 'http://derti.example/live', lat: 37.98, lon: 23.73),
        _rb('Kiss FM', 'http://kiss.example/live', lat: 37.98, lon: 23.73),
      ];
      final extra = [
        _extra('1', 'Something else', 'https://derti.example/live/'), // același stream
        _extra('2', 'Radio Kiss', 'http://other.example/a', lat: 38.0, lon: 23.7), // același nume, aceeași zonă
        _extra('3', 'Kiss FM', 'http://other.example/b', lat: 40.64, lon: 22.94), // alt Kiss, în Salonic
        _extra('4', 'Kiss FM', 'http://other.example/c', cc: 'CY'), // altă țară
        _extra('5', 'Brand New', 'http://new.example/x'),
        _extra('5', 'Brand New (dup uuid)', 'http://new.example/y'),
        _extra('6', 'Brand New copy', 'http://new.example/x'), // duplicat între extra
      ];
      final merged = mergeStations(primary, extra);
      expect(merged.take(2), primary);
      expect(merged.skip(2).map((s) => s.uuid), ['bundle-3', 'bundle-4', 'bundle-5']);
    });

    test('is idempotent (cache already containing the bundle)', () {
      final extra = [_extra('1', 'A', 'http://a.example/1'), _extra('2', 'B', 'http://b.example/1')];
      final once = mergeStations(const [], extra);
      expect(mergeStations(once, extra), hasLength(2));
    });
  });

  group('Radio Garden', () {
    const places = '{"data":{"list":['
        '{"size":176,"title":"Athens","geo":[23.7275,37.9838],"country":"Greece","id":"wtNFAzwK"},'
        '{"size":3,"title":"Larissa","geo":[22.4191,39.639],"country":"Greece","id":"lar"},'
        '{"size":9,"title":"Tashkent","geo":[69.24,41.3],"country":"Uzbekistan","id":"tas"},'
        '{"title":"Broken","country":"Greece"}'
        ']}}';
    const channels = '{"data":{"content":[{"itemsType":"channel","items":['
        '{"page":{"url":"/listen/radio-1234-gr-radio/b2vTgsd_","type":"channel","title":"1234.gr Radio"}},'
        '{"page":{"url":"/visit/athens/wtNFAzwK","type":"page","title":"Not a channel"}}'
        ']}]}}';

    test('parses places and channels', () {
      final parsed = parseRgPlaces(places);
      expect(parsed, hasLength(3));
      expect(parsed.first.lat, closeTo(37.98, 0.01));
      final stations = parseRgChannels(channels, parsed.first, 'GR');
      expect(stations, hasLength(1));
      final s = stations.single;
      expect(s.uuid, 'rg-b2vTgsd_');
      expect(s.streamUrl, 'https://radio.garden/api/ara/content/listen/b2vTgsd_/channel.mp3');
      expect(s.state, 'Athens');
      expect(s.countryCode, 'GR');
      expect(isRadioBrowserStation(s), isFalse);
    });

    test('maps Radio Garden country names to codes by position', () {
      final codes = rgCountryCodes(parseRgPlaces(places), (lat, lon) => lon > 60 ? 'UZ' : 'GR');
      expect(codes, {'Greece': 'GR', 'Uzbekistan': 'UZ'});
    });

    test('tolerates unexpected JSON', () {
      expect(parseRgPlaces('[]'), isEmpty);
      expect(parseRgChannels('{"data":{}}', parseRgPlaces(places).first, 'GR'), isEmpty);
    });
  });
}
