import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'geo.dart';
import 'place_locator.dart';
import 'radio_station.dart';

/// Catalogul inclus în aplicație: posturi adunate offline (Radio Garden,
/// onlineradiobox, TuneIn, live24.gr, instant.audio, radio.net) pentru
/// Balcani, Turcia, Cipru, Caucaz și Asia Centrală — doar cele care NU sunt
/// deja în Radio Browser. Generat de `tools/radio_harvest/harvest.py`.
const String kStationBundleAsset = 'assets/radio/stations_bundle.json.gz';

const String kBundleUuidPrefix = 'bundle-';
const String kRadioGardenUuidPrefix = 'rg-';

/// Postul vine din Radio Browser (doar acelea pot primi "click"-uri în API).
bool isRadioBrowserStation(RadioStation s) =>
    !s.isManual && !s.uuid.startsWith(kBundleUuidPrefix) && !s.uuid.startsWith(kRadioGardenUuidPrefix);

/// Poziția unui post Radio Browser fără coordonate, găsită de harvester în
/// alt catalog (același post, cu oraș cunoscut).
typedef GeoHint = ({double lat, double lon, LocationPrecision precision, String city});

class StationBundle {
  final Map<String, List<RadioStation>> byCountry;
  final String generated;

  /// uuid Radio Browser -> poziție.
  final Map<String, GeoHint> rbGeo;

  const StationBundle(this.byCountry, {this.generated = '', this.rbGeo = const {}});

  static const StationBundle empty = StationBundle({});

  List<RadioStation> forCountry(String countryCode) => byCountry[countryCode.toUpperCase()] ?? const [];

  /// Țara are posturi în catalog (atunci nu mai cerem nimic de la Radio Garden).
  bool covers(String countryCode) => byCountry.containsKey(countryCode.toUpperCase());

  Iterable<RadioStation> get all => byCountry.values.expand((l) => l);

  int get length => byCountry.values.fold(0, (n, l) => n + l.length);

  /// Căutare după nume (subșir, fără diacritice/majuscule).
  List<RadioStation> search(String query, {String? countryCode, int limit = 30}) {
    final q = foldDiacritics(query).trim();
    if (q.isEmpty) return const [];
    final source = countryCode == null ? all : forCountry(countryCode);
    return source.where((s) => foldDiacritics(s.name).contains(q)).take(limit).toList();
  }

  static StationBundle? _cached;
  static Future<StationBundle>? _loading;

  /// Încărcat o singură dată (decomprimat și parsat pe alt isolate). Dacă
  /// asset-ul lipsește sau e corupt, catalogul e gol — aplicația merge mai
  /// departe doar cu Radio Browser.
  static Future<StationBundle> load() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _loading ??= () async {
      try {
        final data = await rootBundle.load(kStationBundleAsset);
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        _cached = await compute(decodeStationBundle, bytes);
      } catch (e) {
        debugPrint('Catalogul de posturi nu a putut fi încărcat: $e');
        _cached = empty;
      }
      return _cached!;
    }();
  }
}

/// Fișierul .json.gz -> catalog.
StationBundle decodeStationBundle(Uint8List gzBytes) =>
    parseStationBundle(utf8.decode(gzip.decode(gzBytes)));

/// Formatul compact scris de harvester: `{"fields": [...], "stations": [[...], ...]}`.
StationBundle parseStationBundle(String raw) {
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final fields = (decoded['fields'] as List).cast<String>();
  final idx = {for (var i = 0; i < fields.length; i++) fields[i]: i};
  final byCountry = <String, List<RadioStation>>{};

  for (final row in (decoded['stations'] as List).whereType<List>()) {
    T? get<T>(String f) {
      final i = idx[f];
      if (i == null || i >= row.length) return null;
      final v = row[i];
      return v is T ? v : null;
    }

    final id = get<String>('id') ?? '';
    final name = (get<String>('name') ?? '').trim();
    final url = get<String>('url') ?? '';
    final cc = (get<String>('cc') ?? '').toUpperCase();
    if (id.isEmpty || name.isEmpty || url.isEmpty || cc.isEmpty) continue;
    final precision = _precisionOf(get<num>('precision'));
    (byCountry[cc] ??= []).add(RadioStation(
      uuid: '$kBundleUuidPrefix$id',
      name: name,
      streamUrl: url,
      homepage: get<String>('homepage') ?? '',
      favicon: get<String>('logo') ?? '',
      countryCode: cc,
      state: get<String>('city') ?? '',
      tags: get<String>('tags') ?? '',
      isHls: url.toLowerCase().contains('.m3u8'),
      lat: get<num>('lat')?.toDouble(),
      lon: get<num>('lon')?.toDouble(),
      precision: precision,
      frequency: get<String>('freq') ?? '',
    ));
  }
  final hints = <String, GeoHint>{};
  final rawHints = decoded['rbgeo'];
  if (rawHints is Map) {
    rawHints.forEach((uuid, v) {
      if (uuid is! String || v is! List || v.length < 2 || v[0] is! num || v[1] is! num) return;
      hints[uuid] = (
        lat: (v[0] as num).toDouble(),
        lon: (v[1] as num).toDouble(),
        precision: _precisionOf(v.length > 2 ? v[2] : null),
        city: v.length > 3 && v[3] is String ? v[3] as String : '',
      );
    });
  }
  return StationBundle(byCountry, generated: decoded['generated'] as String? ?? '', rbGeo: hints);
}

LocationPrecision _precisionOf(Object? v) => switch (v is num ? v.toInt() : 0) {
      1 => LocationPrecision.city,
      2 => LocationPrecision.country,
      _ => LocationPrecision.exact,
    };

/// Pune pe hartă posturile fără poziție (sau puse doar la capitală) pentru
/// care catalogul știe orașul. Restul rămân neschimbate.
List<RadioStation> applyGeoHints(List<RadioStation> stations, Map<String, GeoHint> hints) {
  if (hints.isEmpty) return stations;
  return [
    for (final s in stations)
      if ((!s.hasLocation || s.precision == LocationPrecision.country) && hints[s.uuid] != null)
        s.withLocation(hints[s.uuid]!.lat, hints[s.uuid]!.lon, hints[s.uuid]!.precision,
            state: s.state.isEmpty && hints[s.uuid]!.city.isNotEmpty ? hints[s.uuid]!.city : null)
      else
        s,
  ];
}

// ── Eliminarea duplicatelor între surse ─────────────────────────────────────

const Set<String> _kNameStopWords = {
  'radio', 'radyo', 'radijo', 'radiostanica', 'ραδιο', 'ραδιοφωνο', 'радио', 'радіо', 'fm', 'am', 'online', 'live',
  'the', 'web', 'webradio', 'stream', 'official', 'hd', 'tv',
};

final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Cheia numelui: fără diacritice, fără cuvinte generice ("Radio", "FM").
/// "Ράδιο Λαμία 93.6" și "Radio Lamia 93,6 FM" nu se potrivesc (alfabete
/// diferite), dar "Radio Kiss FM" și "Kiss" da.
String stationNameKey(String name) {
  final tokens = foldDiacritics(name).replaceAll('ς', 'σ').split(_nonWord).where((t) => t.isNotEmpty).toList();
  final kept = tokens.where((t) => !_kNameStopWords.contains(t)).join();
  return kept.isNotEmpty ? kept : tokens.join();
}

/// Cheia stream-ului: gazdă + port + cale, fără schemă, extensie sau "/;".
String streamKey(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return url.trim().toLowerCase();
  var host = uri.host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  final port = (uri.hasPort && uri.port != 80 && uri.port != 443) ? ':${uri.port}' : '';
  final path = uri.path
      .replaceAll(RegExp(r'(/;|;|/+)$'), '')
      .replaceAll(RegExp(r'\.(mp3|aac|aacp|ogg|m3u8?|pls)$', caseSensitive: false), '');
  return '$host$port$path'.toLowerCase();
}

bool _samePlace(RadioStation a, RadioStation b) {
  if (!a.hasLocation || !b.hasLocation) return true;
  if (a.precision == LocationPrecision.country || b.precision == LocationPrecision.country) return true;
  return haversineKm(a.lat!, a.lon!, b.lat!, b.lon!) < 60;
}

/// [primary] (Radio Browser) + posturile din [extra] care nu sunt deja acolo:
/// același uuid, același stream sau același nume în aceeași țară/zonă.
List<RadioStation> mergeStations(List<RadioStation> primary, Iterable<RadioStation> extra) {
  final uuids = <String>{for (final s in primary) s.uuid};
  final streams = <String>{for (final s in primary) streamKey(s.streamUrl)};
  final names = <String, List<RadioStation>>{};
  void indexName(RadioStation s) {
    final key = stationNameKey(s.name);
    if (key.length >= 3) (names['${s.countryCode}|$key'] ??= []).add(s);
  }

  primary.forEach(indexName);
  final result = List<RadioStation>.from(primary);
  for (final s in extra) {
    if (!uuids.add(s.uuid)) continue;
    final sk = streamKey(s.streamUrl);
    if (streams.contains(sk)) continue;
    final key = stationNameKey(s.name);
    if (key.length >= 3 && (names['${s.countryCode}|$key']?.any((p) => _samePlace(p, s)) ?? false)) continue;
    streams.add(sk);
    indexName(s);
    result.add(s);
  }
  return result;
}

/// Pentru compute(): (primary, extra) -> listă combinată.
List<RadioStation> mergeStationLists((List<RadioStation>, List<RadioStation>) lists) =>
    mergeStations(lists.$1, lists.$2);
