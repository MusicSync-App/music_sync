import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../radio/geo.dart' show flagEmoji;
import 'app_themes.dart';
import 'country_detector.dart';
import 'theme_photos.dart';

const String kUserThemesPrefsKey = 'user_country_themes';
const String kUserThemeIdPrefix = 'user_';

/// O țară adăugată din "Alege tema" -> "Adaugă țară".
class UserThemeSpec {
  /// Cod ISO (din assets/geo/countries.json), ex. "RO".
  final String code;
  final String name;

  /// Culoarea principală (ARGB).
  final int accent;

  /// Cuvinte pentru detecția automată (limbă, gen, artiști...).
  final List<String> keywords;

  /// Numele țării din listă (engleză) — folosit și el la detecție.
  final String countryName;

  UserThemeSpec({
    required String code,
    required this.name,
    required this.accent,
    this.keywords = const [],
    String? countryName,
  })  : code = code.toUpperCase(),
        countryName = countryName ?? name;

  String get id => themeIdForCountry(code);
  String get emoji => flagEmoji(code);
  Color get accentColor => Color(accent);
  String get photoFolder => 'user_${code.toLowerCase()}';

  /// Cuvintele folosite efectiv la detecție (+ numele țării).
  List<String> get detectionKeywords => {
        ...keywords.map((k) => k.trim()).where((k) => k.isNotEmpty),
        name.trim(),
        countryName.trim(),
      }.where((k) => k.length >= 2).toList();

  Map<String, dynamic> toJson() => {
        'code': code,
        'name': name,
        'accent': accent,
        'keywords': keywords,
        'countryName': countryName,
      };

  factory UserThemeSpec.fromJson(Map<String, dynamic> j) => UserThemeSpec(
        code: j['code'] as String,
        name: j['name'] as String? ?? j['code'] as String,
        accent: (j['accent'] as num?)?.toInt() ?? 0xFF1A5FA8,
        keywords: [for (final k in (j['keywords'] as List? ?? const [])) k.toString()],
        countryName: j['countryName'] as String?,
      );
}

String themeIdForCountry(String code) => '$kUserThemeIdPrefix${code.toLowerCase()}';

bool isUserThemeId(String id) => id.startsWith(kUserThemeIdPrefix);

/// "manele, românesc,  Zamfir" -> ["manele", "românesc", "Zamfir"].
List<String> parseKeywordInput(String input) {
  final seen = <String>{};
  return [
    for (final k in input.split(RegExp(r'[,;\n]')))
      if (k.trim().length >= 2 && seen.add(k.trim().toLowerCase())) k.trim(),
  ];
}

String encodeUserThemes(List<UserThemeSpec> specs) => jsonEncode(specs.map((s) => s.toJson()).toList());

List<UserThemeSpec> decodeUserThemes(String? raw) {
  if (raw == null || raw.isEmpty) return [];
  try {
    final out = <UserThemeSpec>[];
    for (final e in jsonDecode(raw) as List) {
      try {
        out.add(UserThemeSpec.fromJson(Map<String, dynamic>.from(e as Map)));
      } catch (_) {} // o intrare stricată nu le strică pe celelalte
    }
    return out;
  } catch (_) {
    return [];
  }
}

Color _hsl(double hue, double sat, double light) =>
    HSLColor.fromAHSL(1, hue % 360, sat.clamp(0.0, 1.0), light.clamp(0.0, 1.0)).toColor();

/// Tema completă derivată dintr-o singură culoare (fundal închis în nuanța
/// culorii, card puțin mai deschis, text aproape alb, culori de player).
CountryTheme buildUserTheme(UserThemeSpec spec) =>
    buildColorTheme(id: spec.id, name: spec.name, accent: spec.accentColor, photoFolder: spec.photoFolder);

/// La fel, pentru orice temă definită doar printr-o culoare (ex. temele comune).
CountryTheme buildColorTheme({
  required String id,
  required String name,
  required Color accent,
  required String photoFolder,
}) {
  final hsl = HSLColor.fromColor(accent);
  final h = hsl.hue;
  final s = hsl.saturation;

  return CountryTheme(
    id: id,
    name: name,
    scaffoldBackground: _hsl(h, s * 0.45, 0.07),
    cardBackground: _hsl(h, s * 0.4, 0.13),
    textColor: _hsl(h, 0.25, 0.93),
    accentColor: accent,
    photoFolder: photoFolder,
    playerMoods: {
      SongMood.chill: PlayerColors(
        gradientColors: [_hsl(h - 30, s * 0.5, 0.16), _hsl(h - 30, s * 0.55, 0.28)],
        textColor: _hsl(h - 30, 0.4, 0.9),
        accentColor: _hsl(h - 30, 0.5, 0.6),
      ),
      SongMood.acoustic: PlayerColors(
        gradientColors: [_hsl(30, 0.5, 0.18), _hsl(32, 0.5, 0.3)],
        textColor: const Color(0xFFFFF3E0),
        accentColor: accent,
      ),
      SongMood.energetic: PlayerColors(
        gradientColors: [_hsl(h, s, 0.22), _hsl(h, s, 0.4)],
        textColor: Colors.white,
        accentColor: _hsl(h + 150, 0.7, 0.55),
      ),
      SongMood.melancholic: PlayerColors(
        gradientColors: [_hsl(h, s * 0.2, 0.1), _hsl(h, s * 0.25, 0.17)],
        textColor: _hsl(h, 0.2, 0.8),
        accentColor: accent,
      ),
    },
  );
}

/// Temele (țările) adăugate de utilizator: salvate în preferințe (JSON),
/// pozele în datele aplicației (ThemePhotos). Sunt înregistrate în
/// [appThemes] și în detectorul de țară, deci apar și funcționează la fel
/// ca temele incluse. Temele incluse nu pot fi suprascrise (ID "user_xx").
class UserThemes extends ChangeNotifier {
  UserThemes._();
  static final UserThemes instance = UserThemes._();

  List<UserThemeSpec> _specs = [];
  List<UserThemeSpec> get specs => List.unmodifiable(_specs);

  UserThemeSpec? specFor(String themeId) => _specs.where((s) => s.id == themeId).firstOrNull;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final old in _specs) {
      _unregister(old.id);
    }
    _specs = decodeUserThemes(prefs.getString(kUserThemesPrefsKey));
    for (final spec in _specs) {
      _register(spec);
    }
    notifyListeners();
  }

  void _register(UserThemeSpec spec) {
    appThemes[spec.id] = buildUserTheme(spec);
    registerCustomTheme(spec.id, countryCode: spec.code, keywords: spec.detectionKeywords);
  }

  void _unregister(String id) {
    if (!isUserThemeId(id)) return; // temele incluse rămân neatinse
    appThemes.remove(id);
    unregisterCustomTheme(id);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kUserThemesPrefsKey, encodeUserThemes(_specs));
  }

  /// Adaugă (sau actualizează, pentru aceeași țară) și copiază pozele.
  Future<CountryTheme> save(UserThemeSpec spec, {List<String> photoPaths = const []}) async {
    _specs = [..._specs.where((s) => s.id != spec.id), spec];
    _register(spec);
    await _persist();
    final theme = appThemes[spec.id]!;
    if (photoPaths.isNotEmpty) await ThemePhotos.instance.addUserPhotos(theme, photoPaths);
    notifyListeners();
    return theme;
  }

  Future<void> remove(String themeId) async {
    final spec = specFor(themeId);
    if (spec == null) return;
    final theme = appThemes[themeId];
    _specs = _specs.where((s) => s.id != themeId).toList();
    _unregister(themeId);
    await _persist();
    if (theme != null) await ThemePhotos.instance.removeAllUserPhotos(theme);
    notifyListeners();
  }
}
