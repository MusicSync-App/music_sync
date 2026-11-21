import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicsync_app/radio/place_locator.dart';
import 'package:musicsync_app/radio/radio_station.dart';

RadioStation _s(String name,
        {String state = '',
        String cc = 'GR',
        String country = 'Greece',
        String homepage = '',
        String tags = '',
        double? lat,
        double? lon}) =>
    RadioStation(
        uuid: name,
        name: name,
        streamUrl: 'http://x',
        state: state,
        countryCode: cc,
        country: country,
        homepage: homepage,
        tags: tags,
        lat: lat,
        lon: lon);

void _expectNear(RadioStation? s, double lat, double lon, {double tol = 0.15}) {
  expect(s, isNotNull);
  expect(s!.precision, LocationPrecision.city, reason: s.name);
  expect(s.lat, closeTo(lat, tol), reason: s.name);
  expect(s.lon, closeTo(lon, tol), reason: s.name);
}

void main() {
  late PlaceLocator locator;

  setUpAll(() {
    locator = PlaceLocator.parse(File('assets/geo/places.json').readAsStringSync());
  });

  test('normalizePlaceName folds diacritics and Greek accents', () {
    expect(normalizePlaceName('İstanbul'), 'istanbul');
    expect(normalizePlaceName('Constanța'), 'constanta');
    expect(normalizePlaceName('Θεσσαλονίκη'), 'θεσσαλονικη');
    expect(normalizePlaceName('Athens, Greece'), 'athensgreece');
  });

  test('stations with real coordinates are unchanged', () {
    final s = _s('X', lat: 1, lon: 2);
    expect(identical(locator.place(s), s), isTrue);
  });

  test('state city name places the station in that city', () {
    final athens = locator.place(_s('Radio A', state: 'Athens'))!;
    expect(athens.precision, LocationPrecision.city);
    expect(athens.lat, closeTo(37.98, 0.1));

    // Variantă ortografică din alternatele GeoNames.
    final heraklion = locator.place(_s('Radio B', state: 'Heraclion'))!;
    expect(heraklion.lat, closeTo(35.33, 0.1));

    // "Athens Greece" -> bucata "Athens".
    final split = locator.place(_s('Radio C', state: 'Athens Greece'))!;
    expect(split.precision, LocationPrecision.city);
    expect(split.lon, closeTo(23.73, 0.1));
  });

  test('big city in the station name', () {
    final s = locator.place(_s('Radio Thessaloniki 94.5'))!;
    expect(s.precision, LocationPrecision.city);
    expect(s.lat, closeTo(40.64, 0.1));
  });

  test('national / online station goes to the capital, without distance', () {
    final s = locator.place(_s('Kral FM', cc: 'TR', country: 'Turkey'))!;
    expect(s.precision, LocationPrecision.country);
    expect(s.lat, closeTo(39.92, 0.1)); // Ankara
    expect(s.distanceKmFrom(39.9, 32.8), isNull);
  });

  test('unknown country stays without location', () {
    expect(locator.place(_s('X', cc: '', country: '')), isNull);
  });

  test('precision survives the offline cache round-trip', () {
    final s = locator.place(_s('Radio A', state: 'Athens'))!;
    expect(RadioStation.fromJson(s.toJson()).precision, LocationPrecision.city);
  });

  group('more signals than the declared city', () {
    test('town >= 5k in the station name (Kozani)', () {
      _expectNear(locator.place(_s('Ble 93.3 Kozani')), 40.30, 21.79);
    });

    test('islands and small towns as declared state', () {
      _expectNear(locator.place(_s('Anemos 95.6', state: 'Samos')), 37.75, 26.98, tol: 0.3);
      _expectNear(locator.place(_s('Aigaio News', state: 'Syros')), 37.44, 24.94, tol: 0.2);
      _expectNear(locator.place(_s('12 Gods Cafe', state: 'Pylos')), 36.91, 21.70, tol: 0.2);
      _expectNear(locator.place(_s('ANT1 South', state: 'Molaoi')), 36.80, 22.85, tol: 0.2);
    });

    test('regions go to the region, not the capital', () {
      _expectNear(locator.place(_s('X', state: 'Central Macedonia')), 40.6, 23.0, tol: 0.8);
      _expectNear(locator.place(_s('Y', state: 'Crete')), 35.25, 24.9, tol: 0.8);
      _expectNear(locator.place(_s('Z', state: 'Cyclades')), 37.0, 25.2, tol: 0.8);
    });

    test('Greek capital Alpha inside a Latin word (homoglyph)', () {
      expect(normalizePlaceName('Αthens'), 'athens');
      expect(normalizePlaceName('Αθήνα'), 'αθηνα'); // un singur alfabet: neschimbat
      _expectNear(locator.place(_s('ERA', state: 'Αthens')), 37.98, 23.73);
    });

    test('place inside the web address', () {
      _expectNear(locator.place(_s('Island FM', homepage: 'https://gozakynthos.gr/radio/live-island.html')), 37.78, 20.9);
      _expectNear(locator.place(_s('Anemos', homepage: 'https://www.samostoday.gr/')), 37.75, 26.98, tol: 0.3);
      // stream servers and social networks say nothing about the station
      expect(locator.place(_s('X', homepage: 'https://anadolu.liderhost.com.tr:10961/;', cc: 'TR', country: 'Turkey'))!.precision,
          LocationPrecision.country);
      expect(locator.place(_s('Y', homepage: 'https://www.facebook.com/samosradio'))!.precision, LocationPrecision.country);
    });

    test('tags', () {
      _expectNear(locator.place(_s('Some Radio', tags: 'pop,thessaloniki')), 40.64, 22.94);
    });

    test('common words never become places', () {
      for (final name in ['Radio Power', 'Super FM', 'Kiss FM', 'Best Radio', 'Metro FM', 'Arion Radio']) {
        expect(locator.place(_s(name))!.precision, LocationPrecision.country, reason: name);
      }
    });
  });

  test('parse reads both table formats', () {
    const v1 = '{"capitals":{"GR":[37.98,23.73]},"places":{"GR":{"kozani":[40.3,21.79,1]}}}';
    const v2 = '{"format":2,"capitals":{"GR":[37.98,23.73]},"places":{"GR":[[40.3,21.79,1,"kozani κοζανη"]]}}';
    for (final raw in [v1, v2]) {
      _expectNear(PlaceLocator.parse(raw).place(_s('Ble Kozani')), 40.3, 21.79);
    }
    _expectNear(PlaceLocator.parse(v2).place(_s('Ble', state: 'Κοζάνη')), 40.3, 21.79);
  });
}
