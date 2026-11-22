import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:musicsync_app/remote/server_api.dart';
import 'package:musicsync_app/remote/server_config.dart';

class FakeTokens implements AuthTokenProvider {
  String? token;
  String? refreshed;
  int refreshCalls = 0;
  bool? lastInteractive;
  FakeTokens(this.token, {this.refreshed});

  @override
  Future<String?> accessToken({bool interactive = false}) async {
    lastInteractive = interactive;
    return token;
  }

  @override
  Future<String?> refreshAccessToken({bool interactive = false}) async {
    refreshCalls++;
    token = refreshed;
    return refreshed;
  }
}

http.Response jsonRes(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  const base = 'https://srv.test';

  test('config: every GitHub URL derives from kAppRepo', () {
    expect(kFallbackVersionJsonUrl, 'https://github.com/$kAppRepo/releases/latest/download/version.json');
    expect(kReleasesPageUrl, startsWith('https://github.com/$kAppRepo/'));
  });

  test('manifest (no auth header)', () async {
    late http.Request seen;
    final api = ServerApi(
      baseUrl: '$base/',
      client: MockClient((req) async {
        seen = req;
        return jsonRes({
          'app': {'versionCode': 5, 'versionName': '1.2.0', 'apkUrl': 'a', 'minSupported': 2},
          'content': {'revision': 's', 'indexUrl': 'https://raw/x/s/index.json', 'baseUrl': 'https://raw/x/s/'},
        });
      }),
    );
    final m = await api.manifest();
    expect(seen.url.toString(), '$base/api/manifest');
    expect(seen.headers.containsKey('Authorization'), isFalse);
    expect(m.app!.versionCode, 5);
    expect(m.content!.revision, 's');
  });

  test('manifest with null content = no shared themes (not an error)', () async {
    final api = ServerApi(baseUrl: base, client: MockClient((_) async => jsonRes({'app': null, 'content': null})));
    final m = await api.manifest();
    expect(m.app, isNull);
    expect(m.content, isNull);
  });

  test('me sends the bearer token', () async {
    final api = ServerApi(
      baseUrl: base,
      tokens: FakeTokens('tok1'),
      client: MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer tok1');
        return jsonRes({'email': 'a@b.c', 'isAdmin': true});
      }),
    );
    final me = await api.me();
    expect(me.isAdmin, isTrue);
    expect(me.email, 'a@b.c');
  });

  test('401 -> refresh token -> retry once', () async {
    final tokens = FakeTokens('old', refreshed: 'new');
    final seen = <String?>[];
    final api = ServerApi(
      baseUrl: base,
      tokens: tokens,
      client: MockClient((req) async {
        seen.add(req.headers['Authorization']);
        return req.headers['Authorization'] == 'Bearer new'
            ? jsonRes([{'id': '1', 'kind': 'country', 'status': 'approved'}])
            : jsonRes({'error': 'unauthorized', 'message': 'Token invalid.'}, 401);
      }),
    );
    final list = await api.mySubmissions();
    expect(seen, ['Bearer old', 'Bearer new']);
    expect(tokens.refreshCalls, 1);
    expect(list.single.statusLabel, 'Aprobat');
  });

  test('401 twice -> ServerException with Romanian message', () async {
    final api = ServerApi(
      baseUrl: base,
      tokens: FakeTokens('old', refreshed: 'still-bad'),
      client: MockClient((_) async => http.Response('', 401)),
    );
    await expectLater(
      api.me(),
      throwsA(isA<ServerException>().having((e) => e.code, 'code', 'unauthorized').having((e) => e.isAuth, 'isAuth', isTrue)),
    );
  });

  test('not signed in -> no request, explains', () async {
    var called = false;
    final api = ServerApi(
      baseUrl: base,
      tokens: FakeTokens(null),
      client: MockClient((_) async {
        called = true;
        return jsonRes({});
      }),
    );
    await expectLater(api.me(), throwsA(isA<ServerException>().having((e) => e.code, 'code', 'not_signed_in')));
    expect(called, isFalse);
  });

  test('server JSON error message is shown as-is; fallbacks per status', () async {
    final api = ServerApi(
      baseUrl: base,
      tokens: FakeTokens('t'),
      client: MockClient((req) async => req.url.path.endsWith('mine')
          ? jsonRes({'error': 'rate_limited', 'message': 'Ai trimis deja 5 teme azi.'}, 429)
          : http.Response('<html>', 502)),
    );
    await expectLater(
      api.mySubmissions(),
      throwsA(isA<ServerException>()
          .having((e) => e.message, 'message', 'Ai trimis deja 5 teme azi.')
          .having((e) => e.statusCode, 'status', 429)),
    );
    await expectLater(api.me(), throwsA(isA<ServerException>().having((e) => e.code, 'code', 'server')));
    expect(errorFromResponse(413, '').message, contains('prea mari'));
    expect(errorFromResponse(400, '{"error":"theme_not_found","message":"Tema nu există."}').code, 'theme_not_found');
  });

  test('network errors / timeouts map to Romanian messages', () async {
    final offline = ServerApi(baseUrl: base, client: MockClient((_) async => throw const SocketException('down')));
    await expectLater(offline.manifest(), throwsA(isA<ServerException>().having((e) => e.code, 'code', 'no_internet')));

    final slow = ServerApi(
      baseUrl: base,
      timeout: const Duration(milliseconds: 20),
      client: MockClient((_) => Completer<http.Response>().future),
    );
    await expectLater(
      slow.manifest(),
      throwsA(isA<ServerException>().having((e) => e.code, 'code', 'timeout').having((e) => e.message, 'msg', contains('minut'))),
    );
  });

  test('submit: multipart with meta JSON + photos', () async {
    late String body;
    late http.BaseRequest seen;
    final api = ServerApi(
      baseUrl: base,
      tokens: FakeTokens('t'),
      client: MockClient((req) async {
        seen = req;
        body = latin1.decode(req.bodyBytes);
        return jsonRes({'id': 'sub1', 'status': 'pending'}, 201);
      }),
    );
    final meta = {'kind': 'country', 'countryCode': 'RO', 'name': 'Romania', 'colorValue': 4294198070, 'keywords': ['manele']};
    final id = await api.submit(meta, [
      UploadPhoto(Uint8List.fromList([0xFF, 0xD8, 1]), '0.jpg'),
      UploadPhoto(Uint8List.fromList([0xFF, 0xD8, 2]), '1.jpg'),
    ]);
    expect(id, 'sub1');
    expect(seen.method, 'POST');
    expect(seen.url.path, '/api/submissions');
    expect(seen.headers['Authorization'], 'Bearer t');
    expect(seen.headers['content-type'], startsWith('multipart/form-data'));
    expect(body, contains('name="meta"'));
    expect(body, contains(jsonEncode(meta)));
    expect('name="photos"'.allMatches(body).length, 2);
    expect(body, contains('filename="1.jpg"'));
    expect(body, contains('image/jpeg'));
  });

  test('admin: list, photo, approve (edits only), reject, delete', () async {
    final calls = <String>[];
    final bodies = <String>[];
    final api = ServerApi(
      baseUrl: base,
      tokens: FakeTokens('adm'),
      client: MockClient((req) async {
        calls.add('${req.method} ${req.url.path}${req.url.hasQuery ? '?${req.url.query}' : ''}');
        bodies.add(req.body);
        if (req.url.path == '/api/admin/submissions') {
          return jsonRes([
            {'id': 'a b', 'kind': 'country', 'photoUrls': ['/api/admin/submissions/a%20b/photos/0'], 'submitterEmail': 'x@y.z'},
          ]);
        }
        if (req.method == 'GET' && req.url.path.contains('/photos/')) return http.Response.bytes([1, 2, 3], 200, headers: {'content-type': 'image/jpeg'});
        if (req.url.path.endsWith('/approve')) return jsonRes({'ok': true, 'revision': 'r2'});
        if (req.method == 'DELETE') return jsonRes({'ok': true, 'revision': 'r3'});
        return jsonRes({'ok': true});
      }),
    );
    final pending = await api.adminSubmissions();
    expect(pending.single.submitterEmail, 'x@y.z');
    expect(await api.adminPhoto(pending.single.photoUrls.single), [1, 2, 3]);
    expect(await api.approve('a b', name: 'România'), 'r2');
    await api.reject('a b', 'Poze neclare');
    expect(await api.deleteTheme('central asia'), 'r3');
    expect(await api.deletePhoto('c_ro', 'ff00'), 'r3');
    expect(calls, [
      'GET /api/admin/submissions?status=pending',
      'GET /api/admin/submissions/a%20b/photos/0',
      'POST /api/admin/submissions/a%20b/approve',
      'POST /api/admin/submissions/a%20b/reject',
      'DELETE /api/admin/themes/central%20asia',
      'DELETE /api/admin/themes/c_ro/photos/ff00',
    ]);
    expect(jsonDecode(bodies[2]), {'name': 'România'});
    expect(jsonDecode(bodies[3]), {'reason': 'Poze neclare'});
  });

  test('fallback version.json from GitHub (absolute URL, no auth)', () async {
    final api = ServerApi(
      baseUrl: base,
      client: MockClient((req) async {
        expect(req.url.toString(), 'https://gh.test/version.json');
        return jsonRes({'versionCode': 3, 'versionName': '1.0.2', 'apkUrl': 'x', 'minSupported': 1});
      }),
    );
    expect((await api.fallbackVersion(url: 'https://gh.test/version.json'))!.versionCode, 3);
  });

  test('shared index download; 404 surfaces as statusCode 404', () async {
    final api = ServerApi(
      baseUrl: base,
      client: MockClient((req) async => req.url.path.endsWith('missing.json')
          ? http.Response('404: Not Found', 404)
          : jsonRes({'version': 1, 'themes': [{'id': 'c_ro', 'builtin': false, 'name': 'România'}]})),
    );
    expect((await api.sharedIndex('https://raw/x/index.json')).themes.single.id, 'c_ro');
    await expectLater(
      api.sharedIndex('https://raw/x/missing.json'),
      throwsA(isA<ServerException>().having((e) => e.statusCode, 'status', 404)),
    );
  });
}
