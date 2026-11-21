import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'compressed_audio.dart';
import 'disk_cache.dart';
import 'pcm_audio.dart';
import 'shazam_client.dart';
import 'shazam_signature.dart';

const String _kHistoryKey = 'song_recognition_history';
const int _kMaxHistory = 200;

/// Câte secunde de audio intră în amprentă (ca aplicația Shazam / SongRec).
const int kRecognitionSeconds = 12;

/// Recunoașterea calculează local amprenta audio Shazam (port Dart al
/// algoritmului public din SongRec / shazamio) și o trimite serviciului
/// Shazam — gratuit, fără cont sau token.
class RecognizedSong {
  final String title;
  final String artist;
  final String album;
  final String releaseDate;
  final String songLink;
  final DateTime recognizedAt;

  /// Postul de radio pe care rula, dacă e cazul.
  final String? stationName;

  /// 'shazam' — recunoscută după sunet; 'icy' — luată din titlul transmis
  /// de post (când Shazam nu a găsit-o / nu a putut fi contactat).
  final String source;

  const RecognizedSong({
    required this.title,
    required this.artist,
    this.album = '',
    this.releaseDate = '',
    this.songLink = '',
    required this.recognizedAt,
    this.stationName,
    this.source = 'shazam',
  });

  String get youtubeSearchUrl =>
      'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent('$artist $title')}';

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'album': album,
        'releaseDate': releaseDate,
        'songLink': songLink,
        'recognizedAt': recognizedAt.toIso8601String(),
        if (stationName != null) 'stationName': stationName,
        'source': source,
      };

  factory RecognizedSong.fromJson(Map<String, dynamic> j) => RecognizedSong(
        title: j['title'] as String? ?? '',
        artist: j['artist'] as String? ?? '',
        album: j['album'] as String? ?? '',
        releaseDate: j['releaseDate'] as String? ?? '',
        songLink: j['songLink'] as String? ?? '',
        recognizedAt: DateTime.tryParse(j['recognizedAt'] as String? ?? '') ?? DateTime.now(),
        stationName: j['stationName'] as String?,
        source: j['source'] as String? ?? 'shazam',
      );
}

/// Interpretează titlul ICY ("Artist - Titlu") transmis de post. Întoarce
/// null pentru reclame, jingle-uri, numele postului etc.
({String artist, String title})? parseIcyTitle(String? raw, {String? stationName}) {
  final t = raw?.trim() ?? '';
  if (t.isEmpty) return null;
  final lower = t.toLowerCase();
  const junk = ['ad_start', 'ad_end', 'advert', 'commercial', 'jingle', 'unknown', 'live', 'on air', 'diafimis'];
  if (junk.any((j) => lower == j || lower.startsWith('$j ') || lower.startsWith('$j-'))) return null;
  if (stationName != null && lower.contains(stationName.trim().toLowerCase())) return null;
  final sep = t.indexOf(' - ');
  if (sep <= 0) return null;
  final artist = t.substring(0, sep).trim();
  final title = t.substring(sep + 3).trim();
  if (artist.isEmpty || title.isEmpty) return null;
  return (artist: artist, title: title);
}

/// Poziția secvenței "\r\n\r\n" care încheie antetele unui răspuns HTTP/ICY
/// sau -1 dacă antetele nu au sosit încă complet.
int parseRawHeaderEnd(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10) return i;
  }
  return -1;
}

class RecognitionException implements Exception {
  final String message;
  RecognitionException(this.message);
  @override
  String toString() => message;
}

/// Calculează cât din stream trebuie citit: când recunoaște formatul (MP3 /
/// AAC) ia ~[kRecognitionSeconds]+2 s după debitul real, altfel [fallback].
class CaptureTarget {
  final int fallback;
  int? _target;
  CaptureTarget(this.fallback);

  int bytesFor(Uint8List body) {
    if (_target != null) return _target!;
    if (body.length < 16384) return fallback;
    final info = sniffCompressedAudio(body);
    _target = info == null
        ? fallback
        : (info.offset + info.bytesPerSecond * (kRecognitionSeconds + 2)).clamp(48000, 900000);
    return _target!;
  }
}

class SongRecognizer {
  final AudioRecorder _recorder = AudioRecorder();
  final ShazamClient _shazam = ShazamClient();

  static const MethodChannel _decoderChannel = MethodChannel('musicsync/audio_decoder');

  void dispose() {
    _recorder.dispose();
    _shazam.close();
  }

  // ── Istoric ───────────────────────────────────────────────────────────────

  static Future<List<RecognizedSong>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_kHistoryKey) ?? [];
    final result = <RecognizedSong>[];
    for (final s in raw) {
      try {
        result.add(RecognizedSong.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    return result;
  }

  static Future<void> addToHistory(RecognizedSong song) async {
    final history = await loadHistory();
    history.insert(0, song);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kHistoryKey,
      history.take(_kMaxHistory).map((s) => jsonEncode(s.toJson())).toList(),
    );
  }

  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHistoryKey);
  }

  // ── Captură audio ─────────────────────────────────────────────────────────

  Future<File> _tempFile(String ext) async {
    final dir = await getTemporaryDirectory();
    return File(p.join(dir.path, 'recognize_${DateTime.now().millisecondsSinceEpoch}.$ext'));
  }

  /// Înregistrează de la microfon, direct PCM (WAV 16 kHz mono).
  Future<File> recordMicrophone(Duration duration) async {
    if (!await _recorder.hasPermission()) {
      throw RecognitionException('Permisiunea pentru microfon a fost refuzată.');
    }
    final file = await _tempFile('wav');
    await _recorder.start(
      // audioInterruption.none: don't take audio focus, otherwise Android pauses the radio
      // (or any music app) and the microphone only hears silence.
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        audioInterruption: AudioInterruptionMode.none,
      ),
      path: file.path,
    );
    await Future.delayed(duration);
    final path = await _recorder.stop();
    if (path == null) throw RecognitionException('Înregistrarea a eșuat.');
    return File(path);
  }

  /// Ia direct ~14 secunde din stream-ul radio (mai exact decât microfonul,
  /// fără zgomot de fundal). Nu merge pentru stream-uri HLS (.m3u8).
  Future<File> captureStream(String streamUrl, {int maxBytes = 260000}) async {
    final data = await captureStreamBytes(streamUrl, maxBytes: maxBytes);
    if (data.length < 40000) {
      throw RecognitionException('Prea puține date din stream pentru recunoaștere.');
    }
    final info = sniffCompressedAudio(data);
    final type = info?.format ?? (streamUrl.toLowerCase().contains('aac') ? 'aac' : 'mp3');
    // Fragmentul începe la mijlocul unui cadru — decodorul vrea un cadru întreg.
    final aligned = info == null ? data : Uint8List.sublistView(data, info.offset);
    final file = await _tempFile(type);
    await file.writeAsBytes(aligned, flush: true);
    return file;
  }

  // ── Recunoaștere ──────────────────────────────────────────────────────────

  /// Recunoaște melodia din fișierul audio (WAV de la microfon sau MP3/AAC
  /// din stream). Întoarce null dacă nu s-a găsit nicio potrivire. Dacă
  /// Shazam nu o găsește dar postul transmite titlul ([icyTitle]), îl
  /// folosește pe acela. Fișierul temporar e șters la final.
  Future<RecognizedSong?> recognize(File audio, {String? stationName, String? icyTitle}) async {
    final icy = parseIcyTitle(icyTitle, stationName: stationName);
    RecognizedSong? fromIcy() => icy == null
        ? null
        : RecognizedSong(
            title: icy.title,
            artist: icy.artist,
            recognizedAt: DateTime.now(),
            stationName: stationName,
            source: 'icy',
          );

    try {
      final Int16List pcm;
      try {
        pcm = await decodeToMono16k(audio);
      } on RecognitionException {
        final fallback = fromIcy();
        if (fallback != null) return fallback;
        rethrow;
      }
      if (pcm.length < 16000 * 3) {
        throw RecognitionException('Fragment audio prea scurt pentru recunoaștere.');
      }
      final signature = await computeSignature(pcm);

      final ShazamMatch? match;
      try {
        match = await _shazam.recognize(signature);
      } on ShazamException {
        final fallback = fromIcy();
        if (fallback != null) return fallback;
        rethrow;
      } on TimeoutException {
        final fallback = fromIcy();
        if (fallback != null) return fallback;
        throw RecognitionException('Serviciul de recunoaștere nu a răspuns la timp.');
      } on SocketException {
        final fallback = fromIcy();
        if (fallback != null) return fallback;
        throw RecognitionException('Serviciul de recunoaștere nu poate fi contactat.');
      } on http.ClientException {
        final fallback = fromIcy();
        if (fallback != null) return fallback;
        throw RecognitionException('Serviciul de recunoaștere nu poate fi contactat.');
      }
      if (match == null) return fromIcy();

      return RecognizedSong(
        title: match.title,
        artist: match.artist,
        album: match.album,
        releaseDate: match.releaseDate,
        songLink: match.shazamUrl,
        recognizedAt: DateTime.now(),
        stationName: stationName,
      );
    } finally {
      try {
        await audio.delete();
      } catch (_) {}
    }
  }

  /// Decodează fișierul în PCM mono 16 kHz. WAV se citește direct; MP3/AAC
  /// se decodează cu MediaCodec pe Android, respectiv ffmpeg pe desktop.
  static Future<Int16List> decodeToMono16k(File audio, {int maxSeconds = 30}) async {
    if (p.extension(audio.path).toLowerCase() == '.wav') {
      final bytes = await audio.readAsBytes();
      return Isolate.run(() {
        try {
          return parseWav(bytes).toMono16k();
        } on FormatException catch (e) {
          throw RecognitionException('Înregistrare invalidă: ${e.message}');
        }
      });
    }

    if (Platform.isAndroid) {
      final Map<Object?, Object?>? res;
      try {
        res = await _decoderChannel.invokeMapMethod<Object?, Object?>(
          'decode',
          {'path': audio.path, 'maxSeconds': maxSeconds},
        );
      } on PlatformException catch (e) {
        throw RecognitionException('Formatul stream-ului nu poate fi decodat (${e.message}). Încearcă prin microfon.');
      }
      final raw = res?['pcm'];
      if (raw is! Uint8List || raw.isEmpty) {
        throw RecognitionException('Stream-ul nu a putut fi decodat. Încearcă prin microfon.');
      }
      final rate = res!['sampleRate'] as int;
      final channels = res['channels'] as int;
      return Isolate.run(() {
        // Copie aliniată la 2 octeți (vederea primită poate avea alt offset).
        final samples = Uint8List.fromList(raw.sublist(0, raw.length & ~1)).buffer.asInt16List();
        return PcmAudio(samples, rate, channels).toMono16k();
      });
    }

    return decodeWithFfmpeg(audio.path, maxSeconds: maxSeconds);
  }

  /// Desktop: decodare prin ffmpeg (dacă e instalat).
  static Future<Int16List> decodeWithFfmpeg(String path, {int maxSeconds = 30}) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        'ffmpeg',
        ['-v', 'error', '-i', path, '-t', '$maxSeconds', '-f', 's16le', '-ac', '1', '-ar', '16000', '-'],
        stdoutEncoding: null,
      );
    } on ProcessException {
      throw RecognitionException(
          'Pentru recunoaștere din stream pe acest sistem e nevoie de ffmpeg. Folosește microfonul.');
    }
    final out = result.stdout as List<int>;
    if (result.exitCode != 0 && out.isEmpty) {
      throw RecognitionException('Stream-ul nu a putut fi decodat (${result.stderr}).');
    }
    final bytes = Uint8List.fromList(out);
    return Int16List.view(bytes.buffer, 0, bytes.length ~/ 2);
  }
}

/// Amprenta Shazam pentru (mijlocul) fragmentului, calculată în afara firului UI.
Future<ShazamSignature> computeSignature(Int16List mono16k) =>
    Isolate.run(() => ShazamSignatureGenerator.fromPcm(centerSegment(mono16k, seconds: kRecognitionSeconds)));

/// Citește începutul stream-ului: întâi prin clientul HTTP, apoi (pentru
/// servere SHOUTcast vechi care răspund "ICY 200 OK") direct prin socket.
Future<Uint8List> captureStreamBytes(String streamUrl, {int maxBytes = 260000}) async {
  try {
    return await _captureHttp(streamUrl, CaptureTarget(maxBytes));
  } on RecognitionException {
    rethrow;
  } catch (_) {
    // Clientul HTTP respinge "ICY 200 OK" ("Invalid response line") — citim direct.
    return captureRawStream(Uri.parse(streamUrl), maxBytes);
  }
}

Future<Uint8List> _captureHttp(String streamUrl, CaptureTarget target) async {
  final client = http.Client();
  final bytes = BytesBuilder(copy: false);
  try {
    final request = http.Request('GET', Uri.parse(streamUrl))..headers['User-Agent'] = kHttpUserAgent;
    final response = await client.send(request).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw RecognitionException('Stream-ul a răspuns cu HTTP ${response.statusCode}.');
    }
    final done = Completer<void>();
    late StreamSubscription<List<int>> sub;
    var wanted = target.fallback;
    var sniffed = false;
    sub = response.stream.listen(
      (chunk) {
        bytes.add(chunk);
        if (!sniffed && bytes.length >= 16384) {
          wanted = target.bytesFor(bytes.toBytes());
          sniffed = true;
        }
        if (bytes.length >= wanted && !done.isCompleted) done.complete();
      },
      onDone: () => done.isCompleted ? null : done.complete(),
      onError: (Object e) => done.isCompleted ? null : done.completeError(e),
      cancelOnError: true,
    );
    await done.future.timeout(const Duration(seconds: 25), onTimeout: () {});
    await sub.cancel();
  } finally {
    client.close();
  }
  return bytes.takeBytes();
}

/// Citește stream-ul printr-un socket, acceptând atât "HTTP/1.x 200" cât și
/// "ICY 200 OK"; urmează redirecționările.
Future<Uint8List> captureRawStream(Uri uri, int maxBytes, {int redirects = 3}) async {
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  const connectTimeout = Duration(seconds: 15);
  final Socket socket = uri.scheme == 'https'
      ? await SecureSocket.connect(uri.host, port, timeout: connectTimeout)
      : await Socket.connect(uri.host, port, timeout: connectTimeout);
  final path = uri.path.isEmpty ? '/' : uri.path;
  socket.write('GET ${uri.hasQuery ? '$path?${uri.query}' : path} HTTP/1.0\r\n'
      'Host: ${uri.host}\r\n'
      'User-Agent: $kHttpUserAgent\r\n'
      'Accept: */*\r\n'
      'Connection: close\r\n\r\n');

  final buffer = BytesBuilder(copy: false);
  final done = Completer<void>();
  final target = CaptureTarget(maxBytes);
  var wanted = maxBytes;
  var sniffed = false;
  int? bodyStart;
  Uri? redirectTo;
  void fail(Object e) => done.isCompleted ? null : done.completeError(e);

  final sub = socket.listen(
    (chunk) {
      buffer.add(chunk);
      if (bodyStart == null) {
        final all = buffer.toBytes();
        final end = parseRawHeaderEnd(all);
        if (end < 0) {
          if (all.length > 16384) fail(RecognitionException('Răspuns neașteptat de la stream.'));
          return;
        }
        final head = latin1.decode(all.sublist(0, end));
        final lines = head.split('\r\n');
        final code = int.tryParse(lines.first.split(' ').elementAtOrNull(1) ?? '');
        if (code != null && code >= 300 && code < 400) {
          final locationLine = lines.firstWhere((l) => l.toLowerCase().startsWith('location:'), orElse: () => '');
          final location = locationLine.isEmpty ? '' : locationLine.substring('location:'.length).trim();
          if (location.isNotEmpty) redirectTo = uri.resolve(location);
          if (!done.isCompleted) done.complete();
          return;
        }
        if (code != 200) {
          fail(RecognitionException('Stream-ul a răspuns: ${lines.first}'));
          return;
        }
        bodyStart = end + 4;
      }
      final bodyLength = buffer.length - bodyStart!;
      if (!sniffed && bodyLength >= 16384) {
        wanted = target.bytesFor(Uint8List.sublistView(buffer.toBytes(), bodyStart!));
        sniffed = true;
      }
      if (bodyLength >= wanted && !done.isCompleted) done.complete();
    },
    onDone: () => done.isCompleted ? null : done.complete(),
    onError: fail,
    cancelOnError: true,
  );
  try {
    await done.future.timeout(const Duration(seconds: 25), onTimeout: () {});
  } finally {
    await sub.cancel();
    socket.destroy();
  }

  final redirect = redirectTo;
  if (redirect != null) {
    if (redirects <= 0) throw RecognitionException('Prea multe redirecționări ale stream-ului.');
    return captureRawStream(redirect, maxBytes, redirects: redirects - 1);
  }
  final start = bodyStart;
  if (start == null) throw RecognitionException('Stream-ul nu a trimis date.');
  final all = buffer.takeBytes();
  return start >= all.length ? Uint8List(0) : Uint8List.sublistView(all, start);
}
