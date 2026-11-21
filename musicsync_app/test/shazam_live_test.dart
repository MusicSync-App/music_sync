// Test live (rețea + ffmpeg): ia ~14 s din posturi radio reale, exact ca
// aplicația (captureStreamBytes), calculează amprenta în Dart și o trimite la
// Shazam; verifică rezultatul față de titlul ICY transmis de post.
//
// Rulare:  MUSICSYNC_LIVE_TEST=1 flutter test test/shazam_live_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicsync_app/radio/compressed_audio.dart';
import 'package:musicsync_app/radio/shazam_client.dart';
import 'package:musicsync_app/radio/song_recognizer.dart';

const _stations = {
  'RED 96.3 (AAC+)': 'https://netradio.live24.gr/red9630',
  'Vanilla Smooth (MP3)': 'https://smooth.vanillaradio.com:8032/live',
  'Kiss FM 100.6 (MP3)': 'http://live.radiokiss.gr/kissfm1006hq.mp3',
  'Vanilla Deep (MP3)': 'https://stream.vanillaradio.com:8003/live',
};

/// Titlul ICY curent (cere metadate cu "Icy-MetaData: 1").
Future<String?> _icyTitle(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('Icy-MetaData', '1');
    final res = await req.close().timeout(const Duration(seconds: 10));
    final metaint = int.tryParse(res.headers.value('icy-metaint') ?? '');
    if (metaint == null) return null;
    final buf = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 15))) {
      buf.addAll(chunk);
      if (buf.length > metaint) {
        final len = buf[metaint] * 16;
        if (buf.length >= metaint + 1 + len) {
          final meta = utf8.decode(buf.sublist(metaint + 1, metaint + 1 + len), allowMalformed: true);
          final m = RegExp(r"StreamTitle='(.*?)';").firstMatch(meta);
          return m?.group(1);
        }
      }
    }
  } catch (_) {
  } finally {
    client.close(force: true);
  }
  return null;
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

void main() {
  final enabled = Platform.environment['MUSICSYNC_LIVE_TEST'] == '1';

  test('recognizes songs playing on live radio streams', () async {
    final client = ShazamClient();
    var verified = 0;
    for (final entry in _stations.entries) {
      final icy = await _icyTitle(entry.value);
      final sw = Stopwatch()..start();
      final Uint8List bytes;
      try {
        bytes = await captureStreamBytes(entry.value);
      } catch (e) {
        // ignore: avoid_print
        print('${entry.key}: capture failed: $e');
        continue;
      }
      final captureMs = sw.elapsedMilliseconds;
      final info = sniffCompressedAudio(bytes);
      final file = File('${Directory.systemTemp.path}/musicsync_live_${DateTime.now().microsecondsSinceEpoch}.${info?.format ?? 'mp3'}');
      await file.writeAsBytes(info == null ? bytes : bytes.sublist(info.offset));
      final pcm = await SongRecognizer.decodeWithFfmpeg(file.path);
      await file.delete();
      final sig = await computeSignature(pcm);
      final t0 = sw.elapsedMilliseconds;
      final match = await client.recognize(sig);
      final shazamMs = sw.elapsedMilliseconds - t0;
      // ignore: avoid_print
      print('${entry.key}: ICY="$icy" | captured ${bytes.length} B (${info?.format}, '
          '${info?.bytesPerSecond} B/s) in $captureMs ms, ${pcm.length / 16000} s PCM, '
          '${sig.peakCount} peaks | Shazam ($shazamMs ms): ${match ?? 'no match'}');

      final parsed = parseIcyTitle(icy);
      if (match != null && parsed != null) {
        final a = _norm('${match.artist} ${match.title}');
        if (a.contains(_norm(parsed.title)) || _norm(parsed.title).contains(_norm(match.title))) verified++;
      }
    }
    client.close();
    expect(verified, greaterThan(0), reason: 'no station result matched its ICY title');
  }, skip: enabled ? false : 'set MUSICSYNC_LIVE_TEST=1 (needs network + ffmpeg)', timeout: const Timeout(Duration(minutes: 4)));
}
