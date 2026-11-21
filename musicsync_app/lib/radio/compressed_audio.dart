import 'dart:typed_data';

/// Informații despre primul cadru valid dintr-un fragment MP3 / AAC (ADTS)
/// prins din mijlocul unui stream radio.
class CompressedAudioInfo {
  /// 'mp3' sau 'aac'.
  final String format;

  /// Poziția primului cadru valid (octeții de dinainte sunt resturi de cadru).
  final int offset;

  /// Debitul estimat, în octeți pe secundă.
  final int bytesPerSecond;

  const CompressedAudioInfo(this.format, this.offset, this.bytesPerSecond);
}

const _mp3BitratesV1 = [
  [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448], // layer I
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384], // layer II
  [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320], // layer III
];
const _mp3BitratesV2 = [
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256], // layer I
  [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160], // layer II & III
];
const _mp3Rates = [
  [11025, 12000, 8000], // MPEG 2.5
  <int>[], // rezervat
  [22050, 24000, 16000], // MPEG 2
  [44100, 48000, 32000], // MPEG 1
];
const _adtsRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

/// (lungime cadru, eșantioane pe cadru, rată) sau null dacă nu e antet MP3 valid.
(int, int, int)? _mp3Frame(Uint8List b, int i) {
  if (i + 4 > b.length || b[i] != 0xff || (b[i + 1] & 0xe0) != 0xe0) return null;
  final version = (b[i + 1] >> 3) & 3;
  final layer = (b[i + 1] >> 1) & 3; // 3: I, 2: II, 1: III
  final brIndex = b[i + 2] >> 4;
  final srIndex = (b[i + 2] >> 2) & 3;
  if (version == 1 || layer == 0 || brIndex == 0 || brIndex == 15 || srIndex == 3) return null;
  final padding = (b[i + 2] >> 1) & 1;
  final rate = _mp3Rates[version][srIndex];
  final layerIdx = 3 - layer; // 0: I, 1: II, 2: III
  final kbps = version == 3 ? _mp3BitratesV1[layerIdx][brIndex] : _mp3BitratesV2[layerIdx == 0 ? 0 : 1][brIndex];
  final bps = kbps * 1000;
  if (layerIdx == 0) return ((12 * bps ~/ rate + padding) * 4, 384, rate);
  final samples = (layerIdx == 2 && version != 3) ? 576 : 1152;
  return (samples ~/ 8 * bps ~/ rate + padding, samples, rate);
}

(int, int, int)? _adtsFrame(Uint8List b, int i) {
  if (i + 7 > b.length || b[i] != 0xff || (b[i + 1] & 0xf6) != 0xf0) return null;
  final srIndex = (b[i + 2] >> 2) & 0xf;
  if (srIndex >= _adtsRates.length) return null;
  final len = ((b[i + 3] & 3) << 11) | (b[i + 4] << 3) | (b[i + 5] >> 5);
  if (len < 7) return null;
  return (len, 1024, _adtsRates[srIndex]);
}

/// Găsește primul cadru MP3/ADTS urmat de încă două cadre valide.
CompressedAudioInfo? sniffCompressedAudio(Uint8List bytes, {int searchLimit = 65536}) {
  final limit = bytes.length < searchLimit ? bytes.length : searchLimit;
  for (var i = 0; i < limit; i++) {
    if (bytes[i] != 0xff) continue;
    for (final (format, parse) in [('aac', _adtsFrame), ('mp3', _mp3Frame)]) {
      final first = parse(bytes, i);
      if (first == null) continue;
      var pos = i + first.$1;
      var ok = true;
      var totalLen = first.$1;
      var frames = 1;
      for (var k = 0; k < 3; k++) {
        if (pos >= bytes.length) break; // fragmentul s-a terminat — acceptăm
        final next = parse(bytes, pos);
        if (next == null || next.$3 != first.$3) {
          ok = false;
          break;
        }
        totalLen += next.$1;
        frames++;
        pos += next.$1;
      }
      if (!ok || frames < 2) continue;
      final bytesPerSecond = (totalLen / frames * first.$3 / first.$2).round();
      return CompressedAudioInfo(format, i, bytesPerSecond);
    }
  }
  return null;
}
