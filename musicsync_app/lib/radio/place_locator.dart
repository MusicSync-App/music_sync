import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'radio_station.dart';

const String _kPlacesAsset = 'assets/geo/places.json';

const Map<String, String> _kFold = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a', 'ă': 'a', 'ą': 'a', 'ǎ': 'a',
  'ç': 'c', 'ć': 'c', 'ĉ': 'c', 'ċ': 'c', 'č': 'c', 'ď': 'd', 'đ': 'd',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e', 'ĕ': 'e', 'ė': 'e', 'ę': 'e', 'ě': 'e', 'ə': 'e',
  'ĝ': 'g', 'ğ': 'g', 'ġ': 'g', 'ģ': 'g', 'ĥ': 'h', 'ħ': 'h',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ĩ': 'i', 'ī': 'i', 'ĭ': 'i', 'į': 'i', 'ı': 'i', 'ǐ': 'i',
  'ĵ': 'j', 'ķ': 'k', 'ĺ': 'l', 'ļ': 'l', 'ľ': 'l', 'ŀ': 'l', 'ł': 'l',
  'ñ': 'n', 'ń': 'n', 'ņ': 'n', 'ň': 'n', 'ŉ': 'n',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o', 'ŏ': 'o', 'ő': 'o', 'ǒ': 'o',
  'ŕ': 'r', 'ŗ': 'r', 'ř': 'r', 'ś': 's', 'ŝ': 's', 'ş': 's', 'š': 's', 'ș': 's',
  'ţ': 't', 'ť': 't', 'ŧ': 't', 'ț': 't',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ũ': 'u', 'ū': 'u', 'ŭ': 'u', 'ů': 'u', 'ű': 'u', 'ų': 'u', 'ǔ': 'u',
  'ŵ': 'w', 'ý': 'y', 'ÿ': 'y', 'ŷ': 'y', 'ź': 'z', 'ż': 'z', 'ž': 'z',
  'ß': 'ss', 'æ': 'ae', 'œ': 'oe', 'þ': 'th',
  'ά': 'α', 'ἀ': 'α', 'ἁ': 'α', 'ὰ': 'α', 'ᾶ': 'α', 'έ': 'ε', 'ἐ': 'ε', 'ἑ': 'ε', 'ὲ': 'ε',
  'ή': 'η', 'ἠ': 'η', 'ἡ': 'η', 'ὴ': 'η', 'ῆ': 'η', 'ί': 'ι', 'ϊ': 'ι', 'ΐ': 'ι', 'ἰ': 'ι', 'ἱ': 'ι', 'ὶ': 'ι', 'ῖ': 'ι',
  'ό': 'ο', 'ὀ': 'ο', 'ὁ': 'ο', 'ὸ': 'ο', 'ύ': 'υ', 'ϋ': 'υ', 'ΰ': 'υ', 'ὐ': 'υ', 'ὑ': 'υ', 'ὺ': 'υ', 'ῦ': 'υ',
  'ώ': 'ω', 'ὠ': 'ω', 'ὡ': 'ω', 'ὼ': 'ω', 'ῶ': 'ω', 'ς': 'σ',
};

final RegExp _keep = RegExp(r'[^0-9a-zα-ωа-яёіїєґ]');

/// Cheia de căutare a unui nume de loc — identică cu `normalize()` din
/// `tools/geo/build_places.py`, care a generat `assets/geo/places.json`
/// (fără diacritice, doar litere și cifre).
String normalizePlaceName(String name) => foldDiacritics(name).replaceAll(_keep, '');

/// Litere mici, fără diacritice (și fără accentele grecești), cu literele
/// "intruse" dintr-un alt alfabet corectate (vezi [fixHomoglyphs]).
String foldDiacritics(String text) {
  final lower = fixHomoglyphs(text.toLowerCase());
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final c = String.fromCharCode(rune);
    buffer.write(_kFold[c] ?? c);
  }
  return buffer.toString();
}

final RegExp _latin = RegExp(r'[a-zÀ-ɏ]');
final RegExp _greek = RegExp(r'[Ͱ-Ͽἀ-῿]');
final RegExp _cyrillic = RegExp(r'[Ѐ-ӿ]');
final RegExp _word = RegExp(r'\S+');

Map<String, String> _zip(String from, String to) => {for (var i = 0; i < from.length; i++) from[i]: to[i]};
final Map<String, String> _toLatin = _zip('αβεζηικνορτυχάέίόύаеорсухвкмнтіјѕ', 'abezhiknoptyxaeioyaeopcyxbkmhtijs');
final Map<String, String> _toGreek = _zip('abeziknoptxyhm', 'αβεζικνορτχυημ');
final Map<String, String> _toCyrillic = _zip('abekmhopctyxi', 'авекмнорстухі');

/// "Αthens" scris cu Alfa grecesc -> "athens": într-un cuvânt (deja cu litere
/// mici), literele din alfabetul minoritar care arată ca litere din alfabetul
/// principal sunt înlocuite cu acestea. Cuvintele dintr-un singur alfabet rămân
/// neschimbate.
String fixHomoglyphs(String lower) => lower.replaceAllMapped(_word, (m) {
      final word = m.group(0)!;
      final latin = _latin.allMatches(word).length;
      final greek = _greek.allMatches(word).length;
      final cyr = _cyrillic.allMatches(word).length;
      Map<String, String>? map;
      if (latin > 0 && greek + cyr > 0 && latin >= greek + cyr) {
        map = _toLatin;
      } else if (greek > 0 && latin + cyr > 0 && greek > latin + cyr) {
        map = _toGreek;
      } else if (cyr > 0 && latin + greek > 0 && cyr > latin + greek) {
        map = _toCyrillic;
      }
      if (map == null) return word;
      final buffer = StringBuffer();
      for (final rune in word.runes) {
        final c = String.fromCharCode(rune);
        buffer.write(map[c] ?? c);
      }
      return buffer.toString();
    });

final RegExp _stateSplit = RegExp(r'[,/()\-]|\s+');
final RegExp _nameSplit = RegExp(r'[\s\-_.,|/()!:+&]+');

/// Cuvinte care nu indică un loc, chiar dacă există o localitate cu acel nume.
const Set<String> _kStopWords = {
  'region', 'province', 'city', 'state', 'county', 'district', 'prefecture', 'radio', 'online', 'music', 'radyo',
  'radijo', 'ραδιο', 'радио', 'muzik', 'muzika', 'sport', 'power', 'party', 'dance', 'retro', 'metro',
  'super', 'smooth', 'classic', 'lounge', 'mega', 'stars', 'golden', 'love', 'hits', 'live', 'media', 'news',
  'center', 'centre', 'video', 'nova', 'alpha', 'omega', 'delta', 'sigma', 'kappa', 'lambda', 'gamma', 'tango',
  'salsa', 'blues', 'disco', 'funky', 'house', 'trance', 'urban', 'magic', 'happy', 'vision', 'planet', 'world',
  'global', 'galaxy', 'energy', 'family', 'christian', 'orthodox', 'fresh', 'royal', 'imperial', 'victoria',
  'aurora', 'sunny', 'summer', 'winter', 'paradise', 'atlantis', 'olympia', 'arena', 'palma', 'marina', 'stella',
  'maria', 'elena', 'sofia', 'diana', 'avala', 'stream', 'station', 'channel', 'kanal', 'network', 'today',
  'island', 'islands', 'greek', 'hellas', 'ellas', 'turkiye', 'turkey', 'turk', 'romania', 'serbia', 'srbija',
  'bulgaria', 'albania', 'shqip', 'shqiptar', 'cyprus', 'kibris', 'balkan', 'europe', 'radiostanica',
  'laika', 'laiko', 'rebetiko', 'folk', 'traditional', 'oldies', 'chill', 'relax', 'gospel', 'nostalji',
  'arabesk', 'turku', 'haber', 'manele', 'narodna', 'zabavna', 'popular', 'player', 'official', 'english',
  'anadolu', 'anatolia', 'elliniko', 'ellinikos', 'apollon', 'makedonija', 'dimotika', 'dimotiko', 'nisiotika',
};

/// Gazde care nu spun nimic despre locul postului (rețele sociale, cataloage,
/// servere de streaming).
const List<String> _kGenericHosts = [
  'facebook', 'youtube', 'instagram', 'twitter', 'x.com', 'tiktok', 'google', 'live24', 'radio.garden', 'tunein',
  'onlineradiobox', 'radio.net', 'radio.de', 'streema', 'mytuner', 'zeno.fm', 'mixcloud', 'soundcloud', 'xat.com',
  'shoutcast', 'icecast', 'streamtheworld', 'radiojar', 'radioking', 'radio.co', 'listen2myradio', 'laut.fm',
  'wixsite', 'blogspot', 'wordpress', 'weebly', 'ertecho', 'ertopen', 'ert.gr', 'trt.net', 'rtk', 'radioparadise',
];
const Set<String> _kGenericLabels = {
  'www', 'com', 'net', 'org', 'info', 'co', 'gov', 'edu', 'radio', 'live', 'stream', 'web', 'player', 'm', 'en',
};

/// Plasează pe hartă posturile Radio Browser fără coordonate (bază de date
/// GeoNames inclusă în aplicație, offline), după — în ordine — orașul /
/// regiunea declarată, numele postului, domeniul site-ului și etichete.
/// Doar cele fără niciun indiciu (naționale / online) ajung la capitala țării.
class PlaceLocator {
  /// țară -> nume normalizat -> [lat, lon, nivel]; nivel: 0 sat (< 5.000 loc.),
  /// 1 oraș >= 5.000, 2 oraș >= 50.000, 3 regiune / prefectură / insulă.
  final Map<String, Map<String, List<num>>> _places;
  final Map<String, List<num>> _capitals;

  PlaceLocator._(this._places, this._capitals);

  static PlaceLocator? _cached;

  static Future<PlaceLocator> load() async {
    if (_cached != null) return _cached!;
    final raw = await rootBundle.loadString(_kPlacesAsset);
    _cached = await compute(PlaceLocator.parse, raw);
    return _cached!;
  }

  /// Formatul 2: `{"format": 2, "places": {"GR": [[lat, lon, nivel, "cheie1 cheie2"], ...]}}`;
  /// formatul vechi: `{"places": {"GR": {"cheie": [lat, lon, mare]}}}`.
  static PlaceLocator parse(String raw) {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final places = <String, Map<String, List<num>>>{};
    (decoded['places'] as Map<String, dynamic>).forEach((cc, value) {
      final map = <String, List<num>>{};
      if (value is Map) {
        for (final e in value.entries) {
          map[e.key as String] = List<num>.from(e.value as List);
        }
      } else if (value is List) {
        for (final entry in value.whereType<List>()) {
          final point = <num>[entry[0] as num, entry[1] as num, entry[2] as num];
          for (final key in (entry[3] as String).split(' ')) {
            map[key] = point;
          }
        }
      }
      places[cc] = map;
    });
    final capitals = {
      for (final e in (decoded['capitals'] as Map<String, dynamic>).entries) e.key: List<num>.from(e.value as List),
    };
    return PlaceLocator._(places, capitals);
  }

  /// Postul cu poziție: neschimbat dacă are deja coordonate; altfel plasat
  /// după indicii sau la capitală; null dacă nici țara nu e cunoscută.
  RadioStation? place(RadioStation s) {
    if (s.hasLocation) return s;
    final cc = s.countryCode;
    final places = _places[cc];
    if (places != null) {
      final hit = locateInCountry(places, s, extraStop: {normalizePlaceName(s.country)});
      if (hit != null) return s.withLocation(hit[0].toDouble(), hit[1].toDouble(), LocationPrecision.city);
    }
    final capital = _capitals[cc];
    if (capital == null) return null;
    return s.withLocation(capital[0].toDouble(), capital[1].toDouble(), LocationPrecision.country);
  }
}

bool _isStop(String key, Set<String> extraStop) => _kStopWords.contains(key) || extraStop.contains(key);

/// Cuvintele (și perechile de cuvinte alăturate: "Nea Smyrni") unui text.
List<String> _keysOf(String text, RegExp split) {
  final words = text.split(split).map(normalizePlaceName).where((w) => w.isNotEmpty).toList();
  return [
    for (var i = 0; i + 1 < words.length; i++) '${words[i]}${words[i + 1]}',
    ...words,
  ];
}

/// Locul unui post după indicii (fără capitală). Expus pentru teste.
List<num>? locateInCountry(Map<String, List<num>> places, RadioStation s, {Set<String> extraStop = const {}}) {
  // Nu sate și insulițe: prea multe nume comune.
  bool notable(List<num> p, String key) => p[2] >= 1;

  // 1. Orașul / regiunea declarată: orice loc, inclusiv sate.
  final state = s.state.trim();
  if (state.isNotEmpty) {
    final whole = places[normalizePlaceName(state)];
    if (whole != null) return whole;
    for (final key in _keysOf(state, _stateSplit)) {
      if (key.length < 4 || _isStop(key, extraStop)) continue;
      final p = places[key];
      if (p != null) return p;
    }
  }

  // 2. Un oraș (>= 5.000 loc.) sau o regiune în numele postului ("Ble 93.3 Kozani").
  for (final key in _keysOf(s.name, _nameSplit)) {
    if (key.length < 5 || _isStop(key, extraStop)) continue;
    final p = places[key];
    if (p != null && notable(p, key)) return p;
  }

  // 3. Domeniul site-ului: "gozakynthos.gr" -> Zakynthos, "samostoday.gr" -> Samos.
  final fromHost = _placeInHost(places, s.homepage, extraStop, notable);
  if (fromHost != null) return fromHost;

  // 4. Etichete ("crete", "thessaloniki").
  for (final tag in s.tags.split(',')) {
    final key = normalizePlaceName(tag);
    if (key.length < 4 || _isStop(key, extraStop)) continue;
    final p = places[key];
    if (p != null && notable(p, key)) return p;
  }
  return null;
}

final RegExp _streamLike = RegExp(r'/stream|/;|\.(mp3|aac|m3u8?|pls)\b|/\d{4,5}/', caseSensitive: false);

List<num>? _placeInHost(
  Map<String, List<num>> places,
  String homepage,
  Set<String> extraStop,
  bool Function(List<num>, String) notable,
) {
  final uri = Uri.tryParse(homepage.trim());
  final host = uri?.host.toLowerCase() ?? '';
  if (uri == null || host.isEmpty || _kGenericHosts.any(host.contains)) return null;
  // Un link de stream pus ca site (server de streaming, nu postul).
  if (uri.hasPort || _streamLike.hasMatch(uri.path)) return null;
  final labels = host.split('.');
  if (labels.length > 1) labels.removeLast(); // domeniul de nivel superior
  for (final raw in labels) {
    final label = normalizePlaceName(raw);
    if (label.length < 5 || _kGenericLabels.contains(label)) continue;
    // Cea mai lungă bucată care e un loc cunoscut (minimum 5 litere).
    for (var len = label.length.clamp(0, 24); len >= 5; len--) {
      for (var start = 0; start + len <= label.length; start++) {
        final key = label.substring(start, start + len);
        if (_isStop(key, extraStop)) continue;
        final p = places[key];
        if (p != null && notable(p, key)) return p;
      }
    }
  }
  return null;
}
