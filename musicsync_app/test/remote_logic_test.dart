import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:musicsync_app/remote/remote_models.dart';
import 'package:musicsync_app/remote/shared_themes_logic.dart';
import 'package:musicsync_app/remote/submission_payload.dart';
import 'package:musicsync_app/remote/update_logic.dart';
import 'package:musicsync_app/themes/app_themes.dart';
import 'package:musicsync_app/themes/country_detector.dart';

String sha(String c) => List.filled(64, c).join();

void main() {
  group('manifest parsing', () {
    test('full manifest', () {
      final m = ServerManifest.fromJson({
        'app': {
          'versionCode': 2,
          'versionName': '1.1.0',
          'apkUrl': 'https://example/app-release.apk',
          'sha256': 'ABCDEF',
          'size': 92699796,
          'notes': 'Noutăți',
          'minSupported': 1,
          'publishedAt': '2026-11-20T10:00:00Z',
        },
        'content': {
          'revision': 'abc123',
          'indexUrl': 'https://raw.githubusercontent.com/o/c/abc123/index.json',
          'baseUrl': 'https://raw.githubusercontent.com/o/c/abc123/',
        },
      });
      expect(m.app!.versionCode, 2);
      expect(m.app!.versionName, '1.1.0');
      expect(m.app!.sha256, 'abcdef');
      expect(m.app!.size, 92699796);
      expect(m.app!.minSupported, 1);
      expect(m.app!.publishedAt, DateTime.utc(2026, 11, 20, 10));
      expect(m.content!.revision, 'abc123');
      expect(m.content!.baseUrl, endsWith('/abc123/'));
    });

    test('app null, content null, garbage', () {
      final m = ServerManifest.fromJson({'app': null, 'content': null});
      expect(m.app, isNull);
      expect(m.content, isNull);
      expect(ServerManifest.fromJson('x').app, isNull);
      expect(AppVersionInfo.tryParse({'versionName': '1'}), isNull);
    });

    test('baseUrl derived from indexUrl; withRevision swaps the sha', () {
      final c = ContentInfo.tryParse({'revision': 'r1', 'indexUrl': 'https://raw/o/c/r1/index.json'})!;
      expect(c.baseUrl, 'https://raw/o/c/r1/');
      final c2 = c.withRevision('r2');
      expect(c2.indexUrl, 'https://raw/o/c/r2/index.json');
      expect(c2.baseUrl, 'https://raw/o/c/r2/');
      expect(c2.revision, 'r2');
    });

    test('submissions list parsing is tolerant (extra fields, status labels)', () {
      final list = Submission.listFromJson([
        {'id': '1', 'kind': 'country', 'name': 'România', 'countryCode': 'RO', 'status': 'pending', 'createdAt': '2026-11-01T00:00:00Z'},
        {'id': '2', 'kind': 'photos', 'themeId': 'grecia', 'status': 'rejected', 'reason': 'Poze neclare', 'decidedBy': 'x', 'photos': [1, 2]},
        {'id': '3', 'kind': 'country', 'status': 'approved', 'approvedThemeId': 'c_ro', 'contentRevision': 'abc'},
      ]);
      expect(list.map((s) => s.statusLabel), ['În așteptare', 'Respins: Poze neclare', 'Aprobat']);
      expect(list[1].themeId, 'grecia');
      final admin = Submission.fromJson({
        'id': 'x',
        'kind': 'country',
        'colorValue': 4294198070,
        'keywords': ['manele'],
        'submitterEmail': 'a@b.c',
        'photoUrls': ['/api/admin/submissions/x/photos/0'],
      });
      expect(admin.colorValue, 4294198070);
      expect(admin.photoUrls.single, '/api/admin/submissions/x/photos/0');
    });
  });

  group('update decision', () {
    AppVersionInfo v(int code, {int min = 0}) =>
        AppVersionInfo(versionCode: code, versionName: '$code', apkUrl: 'u', minSupported: min);

    test('newer / same / older / missing', () {
      expect(decideUpdate(installedBuild: 1, latest: v(2)), UpdateKind.optional);
      expect(decideUpdate(installedBuild: 2, latest: v(2)), UpdateKind.none);
      expect(decideUpdate(installedBuild: 3, latest: v(2)), UpdateKind.none);
      expect(decideUpdate(installedBuild: 1, latest: null), UpdateKind.none);
    });

    test('minSupported makes the update required', () {
      expect(decideUpdate(installedBuild: 1, latest: v(3, min: 2)), UpdateKind.required);
      expect(decideUpdate(installedBuild: 2, latest: v(3, min: 2)), UpdateKind.optional);
      expect(decideUpdate(installedBuild: 1, latest: v(3, min: 1)), UpdateKind.optional);
    });

    test('build number parsing', () {
      expect(parseBuildNumber('3'), 3);
      expect(parseBuildNumber('1.0.0+7'), 7);
      expect(parseBuildNumber(''), 0);
    });

    test('auto check at most every 6 h', () {
      final now = DateTime(2026, 11, 22, 12);
      expect(shouldAutoCheck(lastCheck: null, now: now), isTrue);
      expect(shouldAutoCheck(lastCheck: now.subtract(const Duration(hours: 5)), now: now), isFalse);
      expect(shouldAutoCheck(lastCheck: now.subtract(const Duration(hours: 6)), now: now), isTrue);
      expect(shouldAutoCheck(lastCheck: now.add(const Duration(hours: 1)), now: now), isTrue); // ceas dat înapoi
    });

    test('checksum compare', () {
      expect(checksumMatches('ABC', 'abc'), isTrue);
      expect(checksumMatches('abc', 'abd'), isFalse);
      expect(checksumMatches(null, 'abd'), isTrue);
    });
  });

  group('shared themes sync', () {
    final index = SharedIndex.fromJson({
      'version': 1,
      'themes': [
        {
          'id': 'c_ro',
          'builtin': false,
          'countryCode': 'ro',
          'name': 'România',
          'colorValue': 4294198070,
          'keywords': ['manele'],
          'photos': [
            {'path': 'photos/${sha('a')}.jpg', 'sha256': sha('a'), 'w': 1600, 'h': 1067},
            {'path': 'photos/${sha('b')}.jpg', 'sha256': sha('b')},
          ],
        },
        {
          'id': 'grecia',
          'builtin': true,
          'countryCode': 'GR',
          'name': 'Grecia',
          'colorValue': null,
          'photos': [
            {'path': 'photos/${sha('b')}.jpg', 'sha256': sha('b')}, // aceeași poză în două teme
            {'path': 'photos/${sha('c')}.jpg', 'sha256': sha('c')},
            {'path': 'photos/bad.jpg', 'sha256': 'not-a-sha'}, // ignorată
          ],
        },
      ],
    });

    test('index parsing', () {
      expect(index.themes.length, 2);
      expect(index.themes.first.countryCode, 'RO');
      expect(index.themes.last.photos.length, 2);
      final back = SharedIndex.fromJson(index.toJson());
      expect(back.themes.first.photos.first.w, 1600);
    });

    test('plan: download missing (deduped), delete unreferenced', () {
      final plan = planPhotoSync(index, ['${sha('a')}.jpg', '${sha('z')}.jpg', 'x.part']);
      expect(plan.toDownload.map((p) => p.sha256), [sha('b'), sha('c')]);
      expect(plan.toDelete, unorderedEquals(['${sha('z')}.jpg', 'x.part']));
      expect(planPhotoSync(index, ['${sha('a')}.jpg', '${sha('b')}.jpg', '${sha('c')}.jpg']).isEmpty, isTrue);
      expect(planPhotoSync(SharedIndex.empty, ['${sha('a')}.jpg']).toDelete, ['${sha('a')}.jpg']);
    });

    test('photo URL comes from the pinned baseUrl', () {
      final c = ContentInfo.tryParse({'revision': 'r1', 'indexUrl': 'https://raw/o/c/r1/index.json'})!;
      expect(photoUrl(c, index.themes.first.photos.first), 'https://raw/o/c/r1/photos/${sha('a')}.jpg');
    });

    test('built-in ids match the app theme keys', () {
      expect(kBuiltinThemeIds.toSet(), appThemes.keys.where((k) => !k.startsWith('user_') && !k.startsWith('c_')).toSet());
      expect(kBuiltinThemeIds, contains('central asia'));
    });

    test('resolve: builtin entries merge, aliases accepted, collisions skipped', () {
      final idx = SharedIndex.fromJson({
        'themes': [
          {'id': 'grecia', 'builtin': true, 'name': 'Grecia'},
          {'id': 'turkey', 'builtin': true, 'name': 'Turcia'},
          {'id': 'atlantis', 'builtin': true, 'name': '?'},
          {'id': 'c_ro', 'builtin': false, 'name': 'România'},
          {'id': 'iran', 'builtin': false, 'name': 'nu suprascrie'},
          {'id': 'user_ro', 'builtin': false, 'name': 'nu suprascrie'},
        ],
      });
      final r = resolveSharedThemes(idx, kBuiltinThemeIds);
      expect(r.map((e) => (e.appThemeId, e.mergesIntoBuiltin)).toList(), [
        ('grecia', true),
        ('turcia', true),
        ('c_ro', false),
      ]);
    });
  });

  group('detector priority: user > shared > built-in', () {
    setUp(() {
      clearCustomThemes();
      clearSharedThemes();
    });
    tearDown(() {
      clearCustomThemes();
      clearSharedThemes();
    });

    test('country code', () {
      expect(themeForCountryCode('RS'), 'bosnia');
      registerSharedTheme('c_rs', countryCode: 'RS');
      expect(themeForCountryCode('RS'), 'c_rs');
      registerCustomTheme('user_rs', countryCode: 'RS');
      expect(themeForCountryCode('RS'), 'user_rs');
    });

    test('keywords: shared adds detection, user theme of same country wins', () {
      registerSharedTheme('c_ro', countryCode: 'RO', keywords: ['manele']);
      expect(detectThemeForPlaylist(title: 'Manele 2026', songNames: []), 'c_ro');
      registerCustomTheme('user_ro', countryCode: 'RO', keywords: ['manele']);
      expect(detectThemeForPlaylist(title: 'Manele 2026', songNames: []), 'user_ro');
    });

    test('builtin shared entry adds keywords to the built-in theme', () {
      expect(detectThemeForPlaylist(title: 'Entechno', songNames: []), kDefaultThemeId);
      registerSharedTheme('turcia', countryCode: 'TR', keywords: ['fasıl']);
      expect(detectThemeForPlaylist(title: 'Fasıl gecesi', songNames: []), 'turcia');
    });
  });

  group('submission payload', () {
    test('country meta', () {
      final m = countrySubmissionMeta(countryCode: 'ro', name: ' România ', colorValue: 4294198070, keywords: ['manele', ' ', 'x']);
      expect(m, {
        'kind': 'country',
        'countryCode': 'RO',
        'name': 'România',
        'colorValue': 4294198070,
        'keywords': ['manele'],
      });
      expect(validateSubmission(m, 0), isNull);
      expect(validateSubmission(m, 11), isNotNull);
      expect(validateSubmission({...m, 'countryCode': ''}, 0), isNotNull);
    });

    test('photos meta uses the built-in key verbatim', () {
      final m = photosSubmissionMeta(themeId: 'central asia', name: 'Central Asia', countryCode: null);
      expect(m, {'kind': 'photos', 'themeId': 'central asia', 'name': 'Central Asia'});
      expect(validateSubmission(m, 0), isNotNull); // cel puțin o poză
      expect(validateSubmission(m, 1), isNull);
      expect(kBuiltinThemeCountry['grecia'], 'GR');
    });

    test('compression: long side ≤ 1600, JPEG output', () {
      final src = img.Image(width: 3200, height: 1800);
      final png = Uint8List.fromList(img.encodePng(src));
      final out = compressForUpload(png)!;
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 1600);
      expect(decoded.height, 900);
      final small = compressForUpload(Uint8List.fromList(img.encodePng(img.Image(width: 400, height: 800))))!;
      expect(img.decodeJpg(small)!.height, 800);
      expect(compressForUpload(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });
}
