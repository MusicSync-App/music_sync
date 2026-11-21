import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:musicsync_app/radio/compressed_audio.dart';
import 'package:musicsync_app/radio/pcm_audio.dart';
import 'package:musicsync_app/radio/shazam_client.dart';
import 'package:musicsync_app/radio/shazam_signature.dart';
import 'package:musicsync_app/radio/song_recognizer.dart';

/// Fixturile din test/fixtures/shazam:
///  - synthetic_16k.wav: 7 s de "muzică" sintetică (generată determinist);
///  - synthetic_16k.shazamio_core.sig: amprenta aceluiași WAV calculată de
///    shazamio_core 2.0.0 (implementarea Rust a SongRec), referința noastră;
///  - tone.mp3 / tone.aac: 2 s din același semnal, codate cu ffmpeg.
const _fixtures = 'test/fixtures/shazam';

void main() {
  group('Shazam signature', () {
    test('matches the shazamio_core (SongRec) reference for the same PCM', () {
      final pcm = parseWav(File('$_fixtures/synthetic_16k.wav').readAsBytesSync());
      expect(pcm.sampleRate, 16000);
      final mine = ShazamSignatureGenerator.fromPcm(pcm.toMono16k());
      final ref = ShazamSignature.decode(File('$_fixtures/synthetic_16k.shazamio_core.sig').readAsBytesSync());

      expect(mine.numberSamples, ref.numberSamples);
      expect(ref.peakCount, greaterThan(100));
      // Aceleași vârfuri (același FFT, bandă, frecvență); magnitudinea și
      // bin-ul corectat pot diferi cu ±1-2 unități din cauza rotunjirilor
      // float32 (rustfft) vs float64.
      var matched = 0;
      for (final band in ref.peaksByBand.keys) {
        final r = ref.peaksByBand[band]!;
        final m = mine.peaksByBand[band] ?? const [];
        expect(m.length, closeTo(r.length, 2), reason: 'band $band');
        for (final peak in r) {
          final ok = m.any((p) =>
              p.fftPassNumber == peak.fftPassNumber &&
              (p.magnitude - peak.magnitude).abs() <= 2 &&
              (p.correctedBin - peak.correctedBin).abs() <= 2);
          if (ok) matched++;
        }
      }
      expect(matched / ref.peakCount, greaterThan(0.95));
    });

    test('binary encoding round-trips and has a valid header', () {
      final pcm = parseWav(File('$_fixtures/synthetic_16k.wav').readAsBytesSync());
      final sig = ShazamSignatureGenerator.fromPcm(pcm.toMono16k());
      final bytes = sig.encode();
      final bd = ByteData.sublistView(bytes);
      expect(bd.getUint32(0, Endian.little), 0xcafe2580);
      expect(bd.getUint32(4, Endian.little), crc32(bytes.sublist(8)));
      expect(bd.getUint32(8, Endian.little), bytes.length - 48);
      expect(bd.getUint32(28, Endian.little), 3 << 27);
      expect(bytes.length % 4, 0);

      final back = ShazamSignature.decode(bytes);
      expect(back.numberSamples, sig.numberSamples);
      for (final band in sig.peaksByBand.keys) {
        expect(back.peaksByBand[band], sig.peaksByBand[band]);
      }
      expect(sig.toUri(), startsWith('data:audio/vnd.shazam.sig;base64,'));
      expect(sig.sampleMs, 7000);
    });

    test('crc32 matches the IEEE check value', () {
      expect(crc32('123456789'.codeUnits), 0xcbf43926);
    });

    test('request body has the shape the endpoint expects', () {
      final sig = ShazamSignatureGenerator.fromPcm(Int16List(16000 * 3));
      final body = ShazamClient.buildBody(sig, now: DateTime.fromMillisecondsSinceEpoch(1000));
      expect(body['timestamp'], 1000);
      expect((body['signature'] as Map)['samplems'], 3000);
      expect(ShazamClient().buildUri().host, 'amp.shazam.com');
    });

    test('parses a Shazam match response', () {
      final match = ShazamClient.parseResponse({
        'matches': [
          {'id': '1'}
        ],
        'track': {
          'title': 'Wind of Change',
          'subtitle': 'Scorpions',
          'url': 'https://www.shazam.com/track/45286918/wind-of-change',
          'sections': [
            {
              'type': 'SONG',
              'metadata': [
                {'title': 'Album', 'text': 'Crazy World'},
                {'title': 'Released', 'text': '1990'},
              ]
            }
          ],
        },
      });
      expect(match!.title, 'Wind of Change');
      expect(match.artist, 'Scorpions');
      expect(match.album, 'Crazy World');
      expect(match.releaseDate, '1990');
      expect(ShazamClient.parseResponse({'matches': [], 'retryms': 3000}), isNull);
    });
  });

  group('PCM helpers', () {
    test('resampling 44.1 kHz stereo keeps the pitch', () {
      const rate = 44100;
      final stereo = Int16List(rate * 2 * 2);
      for (var i = 0; i < rate * 2; i++) {
        final v = (math.sin(2 * math.pi * 1000 * i / rate) * 12000).round();
        stereo[2 * i] = v;
        stereo[2 * i + 1] = v;
      }
      final mono = PcmAudio(stereo, rate, 2).toMono16k();
      expect(mono.length, closeTo(32000, 2));
      var crossings = 0;
      for (var i = 1; i < mono.length; i++) {
        if ((mono[i - 1] < 0) != (mono[i] < 0)) crossings++;
      }
      expect(crossings, closeTo(4000, 10)); // 1 kHz * 2 s * 2
    });

    test('centerSegment takes the middle', () {
      final pcm = Int16List.fromList(List.generate(16000 * 20, (i) => i ~/ 16000));
      final seg = centerSegment(pcm, seconds: 12);
      expect(seg.length, 16000 * 12);
      expect(seg.first, 4);
    });
  });

  group('compressed stream sniffing', () {
    Uint8List withGarbage(String path) {
      final data = File(path).readAsBytesSync();
      // Un fragment prins din mijlocul stream-ului începe în mijlocul unui cadru.
      return Uint8List.fromList([...List.filled(37, 0x55), 0xff, 0xfb, ...data.sublist(5000)]);
    }

    test('finds MP3 frames and bitrate', () {
      final info = sniffCompressedAudio(withGarbage('$_fixtures/tone.mp3'))!;
      expect(info.format, 'mp3');
      expect(info.offset, greaterThan(38));
      expect(info.bytesPerSecond, closeTo(16000, 400)); // 128 kbps
    });

    test('finds ADTS AAC frames', () {
      final info = sniffCompressedAudio(withGarbage('$_fixtures/tone.aac'))!;
      expect(info.format, 'aac');
      expect(info.bytesPerSecond, inInclusiveRange(4000, 20000));
    });

    test('rejects random bytes', () {
      final rnd = math.Random(1);
      expect(sniffCompressedAudio(Uint8List.fromList(List.generate(20000, (_) => rnd.nextInt(256)))), isNull);
    });
  });

  group('ICY titles', () {
    test('parses "Artist - Title"', () {
      final t = parseIcyTitle('Scorpions - Wind Of Change')!;
      expect(t.artist, 'Scorpions');
      expect(t.title, 'Wind Of Change');
    });
    test('ignores ads and station names', () {
      expect(parseIcyTitle('AD_START'), isNull);
      expect(parseIcyTitle(''), isNull);
      expect(parseIcyTitle('RED 96.3 - Rock Radio', stationName: 'RED 96.3'), isNull);
      expect(parseIcyTitle('Just a slogan'), isNull);
    });
    test('RecognizedSong keeps its source in history JSON', () {
      final s = RecognizedSong(title: 'a', artist: 'b', recognizedAt: DateTime(2026), source: 'icy');
      expect(RecognizedSong.fromJson(s.toJson()).source, 'icy');
      expect(RecognizedSong.fromJson({'title': 'x'}).source, 'shazam');
    });
  });
}
