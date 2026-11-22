import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import 'remote_models.dart';
import 'server_config.dart';

/// Eroare de la server / rețea, cu mesaj în română pentru utilizator.
class ServerException implements Exception {
  /// Codul din `{"error": ...}` sau unul local: no_internet, timeout,
  /// not_signed_in, unauthorized, forbidden, rate_limited, server, bad_response.
  final String code;
  final String message;
  final int? statusCode;
  const ServerException(this.code, this.message, {this.statusCode});

  bool get isAuth => code == 'not_signed_in' || code == 'unauthorized';

  @override
  String toString() => message;
}

/// Sursa tokenului Google (implementarea reală e în google_token_provider.dart).
abstract class AuthTokenProvider {
  /// Tokenul curent. Fără [interactive] nu se deschide nicio fereastră de
  /// conectare; null = utilizatorul nu e conectat.
  Future<String?> accessToken({bool interactive = false});

  /// Serverul a respins tokenul (401) — obține unul nou (sau null).
  Future<String?> refreshAccessToken({bool interactive = false});
}

/// Mesajul românesc pentru un răspuns HTTP de eroare.
ServerException errorFromResponse(int status, String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map && j['message'] is String && (j['message'] as String).trim().isNotEmpty) {
      return ServerException(j['error']?.toString() ?? 'http_$status', (j['message'] as String).trim(), statusCode: status);
    }
  } catch (_) {}
  final (code, msg) = switch (status) {
    401 => ('unauthorized', 'Sesiunea Google a expirat. Conectează-te din nou.'),
    403 => ('forbidden', 'Nu ai drepturi pentru această acțiune.'),
    404 => ('not_found', 'Nu a fost găsit pe server.'),
    413 => ('too_large', 'Pozele sunt prea mari.'),
    429 => ('rate_limited', 'Ai atins limita de trimiteri pentru azi. Încearcă mâine.'),
    >= 500 => ('server', 'Serverul are o problemă momentan. Încearcă mai târziu.'),
    _ => ('http_$status', 'Cererea a eșuat (cod $status).'),
  };
  return ServerException(code, msg, statusCode: status);
}

ServerException errorFromException(Object e) {
  if (e is ServerException) return e;
  if (e is TimeoutException) {
    return const ServerException(
      'timeout',
      'Serverul nu a răspuns la timp (poate tocmai pornește). Încearcă din nou peste un minut.',
    );
  }
  if (e is SocketException || e is http.ClientException || e is HandshakeException) {
    return const ServerException('no_internet', 'Serverul nu poate fi contactat. Verifică internetul.');
  }
  if (e is FormatException) return const ServerException('bad_response', 'Răspuns neașteptat de la server.');
  return ServerException('unknown', 'Eroare: $e');
}

/// O poză de trimis (deja micșorată la JPEG).
class UploadPhoto {
  final Uint8List bytes;
  final String filename;
  const UploadPhoto(this.bytes, this.filename);
}

/// Clientul tipizat pentru toate endpoint-urile serverului.
class ServerApi {
  final http.Client _client;
  final AuthTokenProvider? tokens;
  final String baseUrl;
  final Duration timeout;
  final Duration uploadTimeout;

  ServerApi({
    http.Client? client,
    this.tokens,
    String? baseUrl,
    this.timeout = kServerTimeout,
    this.uploadTimeout = kUploadTimeout,
  })  : _client = client ?? http.Client(),
        baseUrl = (baseUrl ?? kServerBaseUrl).replaceFirst(RegExp(r'/+$'), '');

  Uri _uri(String path, [Map<String, String>? query]) {
    final full = path.startsWith('http') ? path : '$baseUrl${path.startsWith('/') ? '' : '/'}$path';
    final u = Uri.parse(full);
    return query == null ? u : u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  // ── Transport ─────────────────────────────────────────────────────────────

  Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) doRequest, {
    required bool auth,
    bool interactive = false,
    Duration? timeoutOverride,
  }) async {
    final t = timeoutOverride ?? timeout;
    try {
      final headers = <String, String>{'Accept': 'application/json'};
      if (!auth) {
        final res = await doRequest(headers).timeout(t);
        if (res.statusCode >= 400) throw errorFromResponse(res.statusCode, res.body);
        return res;
      }
      final provider = tokens;
      if (provider == null) throw const ServerException('not_signed_in', 'Trebuie să fii conectat cu Google.');
      var token = await provider.accessToken(interactive: interactive);
      if (token == null) {
        throw const ServerException(
          'not_signed_in',
          'Trebuie să fii conectat cu contul Google (Downloader & Sync → Conectează-te).',
        );
      }
      var res = await doRequest({...headers, 'Authorization': 'Bearer $token'}).timeout(t);
      if (res.statusCode == 401) {
        // Token expirat: unul nou și o singură reîncercare.
        token = await provider.refreshAccessToken(interactive: interactive);
        if (token == null) throw errorFromResponse(401, res.body);
        res = await doRequest({...headers, 'Authorization': 'Bearer $token'}).timeout(t);
      }
      if (res.statusCode >= 400) throw errorFromResponse(res.statusCode, res.body);
      return res;
    } catch (e) {
      throw errorFromException(e);
    }
  }

  dynamic _json(http.Response res) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw const ServerException('bad_response', 'Răspuns neașteptat de la server.');
    }
  }

  Future<dynamic> _getJson(String path, {bool auth = false, bool interactive = false, Map<String, String>? query}) async {
    final res = await _send((h) => _client.get(_uri(path, query), headers: h), auth: auth, interactive: interactive);
    return _json(res);
  }

  Future<dynamic> _postJson(String path, Object? body, {bool interactive = true}) async {
    final res = await _send(
      (h) => _client.post(
        _uri(path),
        headers: {...h, 'Content-Type': 'application/json'},
        body: jsonEncode(body ?? const {}),
      ),
      auth: true,
      interactive: interactive,
    );
    return res.body.isEmpty ? const {} : _json(res);
  }

  Future<dynamic> _delete(String path) async {
    final res = await _send((h) => _client.delete(_uri(path), headers: h), auth: true, interactive: true);
    return res.body.isEmpty ? const {} : _json(res);
  }

  // ── Public ────────────────────────────────────────────────────────────────

  Future<bool> health() async {
    final j = await _getJson('/health');
    return j is Map && j['ok'] == true;
  }

  Future<ServerManifest> manifest() async => ServerManifest.fromJson(await _getJson('/api/manifest'));

  /// version.json direct din ultimul release GitHub (când serverul nu merge).
  Future<AppVersionInfo?> fallbackVersion({String url = kFallbackVersionJsonUrl}) async {
    final res = await _send((h) => _client.get(Uri.parse(url), headers: h), auth: false, timeoutOverride: kDownloadTimeout);
    return AppVersionInfo.tryParse(_json(res));
  }

  /// Fișiere publice (index.json, poze) de pe raw.githubusercontent.com.
  Future<Uint8List> downloadBytes(String url) async {
    final res = await _send((h) => _client.get(Uri.parse(url)), auth: false, timeoutOverride: kDownloadTimeout);
    return res.bodyBytes;
  }

  Future<SharedIndex> sharedIndex(String indexUrl) async {
    final bytes = await downloadBytes(indexUrl);
    try {
      return SharedIndex.fromJson(jsonDecode(utf8.decode(bytes)));
    } catch (_) {
      throw const ServerException('bad_response', 'Lista temelor comune e invalidă.');
    }
  }

  // ── Autentificat ──────────────────────────────────────────────────────────

  Future<MeInfo> me({bool interactive = false}) async =>
      MeInfo.fromJson(await _getJson('/api/me', auth: true, interactive: interactive));

  /// POST /api/submissions (multipart: `meta` + `photos`). Întoarce ID-ul.
  Future<String> submit(Map<String, dynamic> meta, List<UploadPhoto> photos) async {
    final res = await _send(
      (h) async {
        final req = http.MultipartRequest('POST', _uri('/api/submissions'))
          ..headers.addAll(h)
          ..fields['meta'] = jsonEncode(meta);
        for (final p in photos) {
          req.files.add(http.MultipartFile.fromBytes('photos', p.bytes,
              filename: p.filename, contentType: MediaType('image', 'jpeg')));
        }
        return http.Response.fromStream(await _client.send(req));
      },
      auth: true,
      interactive: true,
      timeoutOverride: uploadTimeout,
    );
    final j = _json(res);
    return j is Map ? (j['id']?.toString() ?? '') : '';
  }

  Future<List<Submission>> mySubmissions({bool interactive = true}) async =>
      Submission.listFromJson(await _getJson('/api/submissions/mine', auth: true, interactive: interactive));

  // ── Admin ─────────────────────────────────────────────────────────────────

  Future<List<Submission>> adminSubmissions({String status = 'pending'}) async => Submission.listFromJson(
      await _getJson('/api/admin/submissions', auth: true, interactive: true, query: {'status': status}));

  /// Poza unei trimiteri (cerere autorizată). [urlOrPath] e din `photoUrls`.
  Future<Uint8List> adminPhoto(String urlOrPath) async {
    final res = await _send((h) => _client.get(_uri(urlOrPath), headers: {...h, 'Accept': 'image/*'}),
        auth: true, interactive: true);
    return res.bodyBytes;
  }

  Future<Uint8List> adminPhotoByIndex(String submissionId, int n) =>
      adminPhoto('/api/admin/submissions/${Uri.encodeComponent(submissionId)}/photos/$n');

  /// Întoarce noua revizie a repo-ului cu teme (sau null).
  Future<String?> approve(String submissionId, {String? name, int? colorValue, List<String>? keywords}) async {
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (colorValue != null) 'colorValue': colorValue,
      if (keywords != null) 'keywords': keywords,
    };
    final j = await _postJson('/api/admin/submissions/${Uri.encodeComponent(submissionId)}/approve', body);
    return j is Map ? j['revision']?.toString() : null;
  }

  Future<void> reject(String submissionId, String reason) async {
    await _postJson('/api/admin/submissions/${Uri.encodeComponent(submissionId)}/reject', {'reason': reason});
  }

  Future<String?> deleteTheme(String themeId) async {
    final j = await _delete('/api/admin/themes/${Uri.encodeComponent(themeId)}');
    return j is Map ? j['revision']?.toString() : null;
  }

  Future<String?> deletePhoto(String themeId, String photoSha) async {
    final j = await _delete('/api/admin/themes/${Uri.encodeComponent(themeId)}/photos/${Uri.encodeComponent(photoSha)}');
    return j is Map ? j['revision']?.toString() : null;
  }

  void close() => _client.close();
}
