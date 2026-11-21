import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'shazam_signature.dart';

/// Rezultatul brut al unei căutări Shazam.
class ShazamMatch {
  final String title;
  final String artist;
  final String album;
  final String releaseDate;
  final String shazamUrl;
  final String? coverUrl;
  const ShazamMatch({
    required this.title,
    required this.artist,
    this.album = '',
    this.releaseDate = '',
    this.shazamUrl = '',
    this.coverUrl,
  });

  @override
  String toString() => '$artist - $title${album.isEmpty ? '' : ' [$album]'}';
}

class ShazamException implements Exception {
  final String message;
  final int? statusCode;
  ShazamException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

/// Client pentru serviciul de recunoaștere folosit de aplicația Shazam
/// (același endpoint ca SongRec / shazamio). Nu necesită cont sau cheie.
class ShazamClient {
  final http.Client _http;
  final math.Random _rng;
  ShazamClient({http.Client? httpClient, math.Random? random})
      : _http = httpClient ?? http.Client(),
        _rng = random ?? math.Random.secure();

  void close() => _http.close();

  static const _userAgents = [
    'Dalvik/2.1.0 (Linux; U; Android 13; SM-A536B Build/TP1A.220624.014)',
    'Dalvik/2.1.0 (Linux; U; Android 14; Pixel 7 Build/UQ1A.240205.004)',
    'Dalvik/2.1.0 (Linux; U; Android 12; SM-G991B Build/SP1A.210812.016)',
    'Dalvik/2.1.0 (Linux; U; Android 13; M2101K6G Build/TKQ1.221013.002)',
  ];

  String _uuid() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}'
        .toUpperCase();
  }

  Uri buildUri() => Uri.parse('https://amp.shazam.com/discovery/v5/en/US/android/-/tag/${_uuid()}/${_uuid()}'
      '?sync=true&webv3=true&sampling=true&connected=&shazamapiversion=v3&sharehub=true&video=v3');

  static Map<String, dynamic> buildBody(ShazamSignature sig, {DateTime? now}) {
    final ts = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return {
      'geolocation': {'altitude': 300, 'latitude': 45, 'longitude': 2},
      'signature': {'samplems': sig.sampleMs, 'timestamp': ts, 'uri': sig.toUri()},
      'timestamp': ts,
      'timezone': 'Europe/Athens',
    };
  }

  /// Întoarce null dacă Shazam nu a găsit melodia.
  Future<ShazamMatch?> recognize(ShazamSignature sig) async {
    final response = await _http
        .post(
          buildUri(),
          headers: {
            'User-Agent': _userAgents[_rng.nextInt(_userAgents.length)],
            'Content-Language': 'en_US',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(buildBody(sig)),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 429) {
      throw ShazamException('Prea multe căutări într-un timp scurt — mai încearcă peste un minut.', statusCode: 429);
    }
    if (response.statusCode != 200) {
      throw ShazamException('Serviciul de recunoaștere a răspuns HTTP ${response.statusCode}.',
          statusCode: response.statusCode);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ShazamException('Răspuns invalid de la serviciul de recunoaștere.');
    }
    return parseResponse(decoded);
  }

  static ShazamMatch? parseResponse(Object? decoded) {
    if (decoded is! Map) return null;
    final track = decoded['track'];
    final matches = decoded['matches'];
    if (track is! Map || matches is! List || matches.isEmpty) return null;

    var album = '';
    var released = '';
    final sections = track['sections'];
    if (sections is List) {
      for (final s in sections) {
        if (s is! Map || s['type'] != 'SONG') continue;
        final meta = s['metadata'];
        if (meta is! List) continue;
        for (final m in meta) {
          if (m is! Map) continue;
          final t = '${m['title'] ?? ''}'.toLowerCase();
          final text = '${m['text'] ?? ''}';
          if (t == 'album') album = text;
          if (t == 'released') released = text;
        }
      }
    }
    final images = track['images'];
    final share = track['share'];
    return ShazamMatch(
      title: '${track['title'] ?? ''}',
      artist: '${track['subtitle'] ?? ''}',
      album: album,
      releaseDate: released,
      shazamUrl: share is Map ? '${share['href'] ?? track['url'] ?? ''}' : '${track['url'] ?? ''}',
      coverUrl: images is Map ? images['coverarthq'] as String? ?? images['coverart'] as String? : null,
    );
  }
}
