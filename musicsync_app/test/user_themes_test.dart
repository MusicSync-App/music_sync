import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicsync_app/themes/app_themes.dart';
import 'package:musicsync_app/themes/country_detector.dart';
import 'package:musicsync_app/themes/user_themes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final builtInIds = appThemes.keys.toSet();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await UserThemes.instance.load(); // curăță temele din testul anterior
    clearCustomThemes();
  });

  group('UserThemeSpec persistence', () {
    test('JSON round-trip', () {
      final spec = UserThemeSpec(
        code: 'ro',
        name: 'România',
        accent: 0xFFF9A825,
        keywords: ['manele', 'Zamfir'],
        countryName: 'Romania',
      );
      final back = decodeUserThemes(encodeUserThemes([spec])).single;
      expect(back.code, 'RO');
      expect(back.id, 'user_ro');
      expect(back.name, 'România');
      expect(back.accent, 0xFFF9A825);
      expect(back.keywords, ['manele', 'Zamfir']);
      expect(back.countryName, 'Romania');
    });

    test('corrupt data is ignored, valid entries kept', () {
      expect(decodeUserThemes('garbage'), isEmpty);
      expect(decodeUserThemes(null), isEmpty);
      final mixed = decodeUserThemes('[{"code":"RS","name":"Srbija","accent":4280391411}, {"name": 5}]');
      expect(mixed.map((s) => s.id), ['user_rs']);
    });

    test('parseKeywordInput', () {
      expect(parseKeywordInput('manele, românesc;  Maria Tănase\nx, MANELE'), ['manele', 'românesc', 'Maria Tănase']);
    });

    test('save -> survives reload ("restart") -> delete', () async {
      final spec = UserThemeSpec(code: 'RO', name: 'România', accent: 0xFFF9A825, keywords: ['manele']);
      await UserThemes.instance.save(spec);
      expect(appThemes['user_ro']?.name, 'România');

      // "Repornire": golim registrul în memorie și citim din preferințe.
      appThemes.remove('user_ro');
      clearCustomThemes();
      await UserThemes.instance.load();
      expect(appThemes['user_ro']?.accentColor, const Color(0xFFF9A825));
      expect(UserThemes.instance.specs.single.keywords, ['manele']);
      expect(detectThemeForPlaylist(title: 'Manele 2024', songNames: []), 'user_ro');

      await UserThemes.instance.remove('user_ro');
      expect(appThemes.containsKey('user_ro'), isFalse);
      await UserThemes.instance.load();
      expect(UserThemes.instance.specs, isEmpty);
      expect(detectThemeForPlaylist(title: 'Manele 2024', songNames: []), kDefaultThemeId);
    });

    test('built-in themes are untouched; Greece stays the default', () async {
      await UserThemes.instance.save(UserThemeSpec(code: 'RO', name: 'România', accent: 0xFF000000));
      await UserThemes.instance.remove('grecia'); // nu e temă de utilizator -> nimic
      expect(appThemes.keys.toSet().containsAll(builtInIds), isTrue);
      expect(detectThemeForPlaylist(title: 'Gym mix', songNames: ['a.mp3']), 'grecia');
      expect(themeForCountryCode('FR'), 'grecia');
    });
  });

  group('buildUserTheme', () {
    test('derives a readable dark palette from the accent', () {
      final theme = buildUserTheme(UserThemeSpec(code: 'RO', name: 'România', accent: 0xFFF9A825));
      expect(theme.id, 'user_ro');
      expect(theme.photoFolder, 'user_ro');
      expect(theme.accentColor, const Color(0xFFF9A825));
      expect(theme.scaffoldBackground.computeLuminance(), lessThan(0.05));
      expect(theme.textColor.computeLuminance(), greaterThan(0.7));
      expect(theme.playerMoods.keys.toSet(), SongMood.values.toSet());
    });
  });

  group('detector with custom keywords', () {
    test('custom keywords switch the theme', () {
      registerCustomTheme('user_ro', countryCode: 'RO', keywords: ['manele', 'Gheorghe Zamfir', 'românesc']);
      expect(detectThemeForPlaylist(title: 'Cele mai bune manele', songNames: []), 'user_ro');
      expect(
        detectThemeForPlaylist(title: 'Mix', songNames: ['Gheorghe Zamfir - Lonely Shepherd.m4a', 'x.m4a']),
        'user_ro',
      );
      // Cuvântul trebuie să înceapă un cuvânt.
      expect(detectThemeForPlaylist(title: 'Xmanele', songNames: []), kDefaultThemeId);
    });

    test('keywords are literal text, not regex', () {
      registerCustomTheme('user_xx', keywords: ['foo-bar (live)', 'a.b']);
      expect(detectThemeForPlaylist(title: 'best foo-bar (live) hits', songNames: []), 'user_xx');
      expect(detectThemeForPlaylist(title: 'foo-bar live', songNames: []), kDefaultThemeId);
      expect(detectThemeForPlaylist(title: 'axb', songNames: []), kDefaultThemeId);
    });

    test('custom country code overrides the built-in mapping', () {
      expect(themeForCountryCode('RS'), 'bosnia');
      registerCustomTheme('user_rs', countryCode: 'rs');
      expect(themeForCountryCode('RS'), 'user_rs');
      expect(themeForCountryCode('RO'), 'grecia');
      unregisterCustomTheme('user_rs');
      expect(themeForCountryCode('RS'), 'bosnia');
    });

    test('built-in detection still works alongside custom rules', () {
      registerCustomTheme('user_ro', countryCode: 'RO', keywords: ['manele']);
      expect(detectThemeForPlaylist(title: 'Türkçe Pop', songNames: []), 'turcia');
      expect(detectThemeForPlaylist(title: 'Sevdah noći', songNames: []), 'bosnia');
    });
  });
}
