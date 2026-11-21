import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'disk_cache.dart';
import 'radio_station.dart';
import 'station_bundle.dart';

/// Un loc (oraș) din Radio Garden, cu coordonatele lui.
class RgPlace {
  final String id;
  final String title;
  final String country;
  final double lat;
  final double lon;
  final int size;

  const RgPlace(this.id, this.title, this.country, this.lat, this.lon, this.size);
}

const String _kRgBase = 'https://radio.garden/api/ara/content';

/// Linkul de ascultare: Radio Garden răspunde cu redirect către stream-ul real
/// (player-ul urmează redirectul la redare).
String radioGardenListenUrl(String channelId) => '$_kRgBase/listen/$channelId/channel.mp3';

/// `{"data": {key: ...}}` -> valoarea, sau null.
Object? _dataField(Object? decoded, String key) {
  if (decoded is! Map) return null;
  final data = decoded['data'];
  return data is Map ? data[key] : null;
}

List<RgPlace> parseRgPlaces(String raw) {
  final list = _dataField(jsonDecode(raw), 'list');
  if (list is! List) return const [];
  final result = <RgPlace>[];
  for (final item in list.whereType<Map>()) {
    final geo = item['geo'];
    final id = item['id'];
    if (geo is! List || geo.length < 2 || id is! String) continue;
    result.add(RgPlace(
      id,
      (item['title'] as String? ?? '').trim(),
      item['country'] as String? ?? '',
      (geo[1] as num).toDouble(),
      (geo[0] as num).toDouble(),
      (item['size'] as num?)?.toInt() ?? 0,
    ));
  }
  return result;
}

/// Lista de posturi a unui loc (`/page/<id>/channels`).
List<RadioStation> parseRgChannels(String raw, RgPlace place, String countryCode) {
  final content = _dataField(jsonDecode(raw), 'content');
  if (content is! List) return const [];
  final result = <RadioStation>[];
  for (final block in content.whereType<Map>()) {
    final items = block['items'];
    if (items is! List) continue;
    for (final item in items.whereType<Map>()) {
      final page = item['page'];
      if (page is! Map || page['type'] != 'channel') continue;
      final url = page['url'] as String? ?? '';
      final id = url.split('/').where((s) => s.isNotEmpty).lastOrNull;
      final title = (page['title'] as String? ?? '').trim();
      if (id == null || title.isEmpty) continue;
      result.add(RadioStation(
        uuid: '$kRadioGardenUuidPrefix$id',
        name: title,
        streamUrl: radioGardenListenUrl(id),
        countryCode: countryCode,
        country: place.country,
        state: place.title,
        lat: place.lat,
        lon: place.lon,
      ));
    }
  }
  return result;
}

/// Țara fiecărui nume de țară din Radio Garden, după poziția celui mai mare
/// loc al ei (fără tabel de nume — granițele sunt deja în aplicație).
Map<String, String> rgCountryCodes(List<RgPlace> places, String? Function(double lat, double lon) countryAt) {
  final biggest = <String, RgPlace>{};
  for (final place in places) {
    final current = biggest[place.country];
    if (current == null || place.size > current.size) biggest[place.country] = place;
  }
  final result = <String, String>{};
  biggest.forEach((country, place) {
    final code = countryAt(place.lat, place.lon);
    if (code != null) result[country] = code;
  });
  return result;
}

/// Rezervă la rulare pentru țările care nu sunt în catalogul inclus: harta
/// se umple și cu posturile din Radio Garden (API-ul public al site-ului).
class RadioGardenClient {
  final String? Function(double lat, double lon) countryAt;

  RadioGardenClient({required this.countryAt});

  static const Duration _placesMaxAge = Duration(days: 14);

  List<RgPlace>? _places;
  Map<String, String>? _codes;
  final Map<String, List<RadioStation>> _byCountry = {};

  Future<String> _get(String url) async {
    final res = await http
        .get(Uri.parse(url), headers: {'User-Agent': kHttpUserAgent})
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    return utf8.decode(res.bodyBytes);
  }

  Future<List<RgPlace>> _loadPlaces() async {
    final cached = _places;
    if (cached != null) return cached;
    File? file;
    try {
      file = File(p.join(DiskCache.rootPath, 'rg_places.json'));
    } catch (_) {}
    String? raw;
    if (file != null && await file.exists() && DateTime.now().difference(await file.lastModified()) < _placesMaxAge) {
      raw = await file.readAsString();
    }
    if (raw == null) {
      try {
        raw = await _get('$_kRgBase/places');
        if (file != null) await file.writeAsString(raw);
      } catch (_) {
        // Fără internet: folosim și o listă veche, dacă există.
        if (file != null && await file.exists()) raw = await file.readAsString();
        if (raw == null) rethrow;
      }
    }
    final places = await compute(parseRgPlaces, raw);
    _places = places;
    return places;
  }

  /// Posturile Radio Garden ale țării [countryCode], din cele mai mari
  /// [maxPlaces] orașe (câte 4 cereri simultan).
  Future<List<RadioStation>> fetchCountry(String countryCode, {int maxPlaces = 40}) async {
    final code = countryCode.toUpperCase();
    final known = _byCountry[code];
    if (known != null) return known;

    final places = await _loadPlaces();
    final codes = _codes ??= rgCountryCodes(places, countryAt);
    final names = {for (final e in codes.entries) if (e.value == code) e.key};
    if (names.isEmpty) return _byCountry[code] = const [];
    final mine = places.where((pl) => names.contains(pl.country)).toList()..sort((a, b) => b.size.compareTo(a.size));
    final queue = mine.take(maxPlaces).toList();

    final stations = <String, RadioStation>{};
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final place = queue.removeAt(0);
        try {
          final raw = await _get('$_kRgBase/page/${place.id}/channels');
          for (final s in parseRgChannels(raw, place, code)) {
            stations.putIfAbsent(s.uuid, () => s);
          }
        } catch (_) {}
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    return _byCountry[code] = stations.values.toList();
  }
}
