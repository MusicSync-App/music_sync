import 'dart:math' as math;
import 'dart:typed_data';

/// PCM 16 biți, intercalat pe canale.
class PcmAudio {
  final Int16List samples;
  final int sampleRate;
  final int channels;
  const PcmAudio(this.samples, this.sampleRate, this.channels);

  double get durationSeconds => samples.length / channels / sampleRate;

  /// Mono, 16 kHz — formatul cerut de amprenta Shazam.
  Int16List toMono16k() => resampleTo16k(downmix(samples, channels), sampleRate);
}

/// Citește un fișier WAV PCM (16 biți, sau 8/24/32 biți întregi, sau float32).
PcmAudio parseWav(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('Nu e un fișier WAV.');
  }
  int? format, channels, rate, bits;
  var i = 12;
  while (i + 8 <= bytes.length) {
    final id = tag(i);
    var size = bd.getUint32(i + 4, Endian.little);
    final body = i + 8;
    if (id == 'fmt ') {
      format = bd.getUint16(body, Endian.little);
      channels = bd.getUint16(body + 2, Endian.little);
      rate = bd.getUint32(body + 4, Endian.little);
      bits = bd.getUint16(body + 14, Endian.little);
      if (format == 0xfffe && size >= 26) format = bd.getUint16(body + 24, Endian.little);
    } else if (id == 'data') {
      if (format == null) throw const FormatException('WAV fără antet fmt.');
      // Înregistrările întrerupte pot avea dimensiunea 0 / greșită.
      if (size == 0 || body + size > bytes.length) size = bytes.length - body;
      return PcmAudio(_toInt16(bytes, body, size, format, bits!), rate!, channels!);
    }
    i = body + size + (size & 1);
  }
  throw const FormatException('WAV fără date audio.');
}

Int16List _toInt16(Uint8List bytes, int offset, int size, int format, int bits) {
  final bd = ByteData.sublistView(bytes, offset, offset + size);
  if (format == 1 && bits == 16) {
    final out = Int16List(size ~/ 2);
    for (var k = 0; k < out.length; k++) {
      out[k] = bd.getInt16(k * 2, Endian.little);
    }
    return out;
  }
  if (format == 1 && bits == 8) {
    return Int16List.fromList([for (var k = 0; k < size; k++) (bytes[offset + k] - 128) << 8]);
  }
  if (format == 1 && bits == 24) {
    final out = Int16List(size ~/ 3);
    for (var k = 0; k < out.length; k++) {
      out[k] = bd.getInt16(k * 3 + 1, Endian.little);
    }
    return out;
  }
  if (format == 1 && bits == 32) {
    final out = Int16List(size ~/ 4);
    for (var k = 0; k < out.length; k++) {
      out[k] = bd.getInt32(k * 4, Endian.little) >> 16;
    }
    return out;
  }
  if (format == 3 && bits == 32) {
    final out = Int16List(size ~/ 4);
    for (var k = 0; k < out.length; k++) {
      out[k] = (bd.getFloat32(k * 4, Endian.little) * 32767).round().clamp(-32768, 32767);
    }
    return out;
  }
  throw FormatException('Format WAV nesuportat ($format, $bits biți).');
}

Int16List downmix(Int16List interleaved, int channels) {
  if (channels <= 1) return interleaved;
  final out = Int16List(interleaved.length ~/ channels);
  for (var f = 0; f < out.length; f++) {
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      sum += interleaved[f * channels + c];
    }
    out[f] = sum ~/ channels;
  }
  return out;
}

/// Reeșantionare la 16 kHz cu filtru sinc ferestruit (fără aliasing, care ar
/// introduce vârfuri false în amprentă).
Int16List resampleTo16k(Int16List mono, int fromRate) {
  const target = 16000;
  if (fromRate == target) return mono;
  final ratio = fromRate / target;
  final outLen = (mono.length / ratio).floor();
  final out = Int16List(outLen);
  // Frecvența de tăiere relativă la rata sursei (puțin sub Nyquist-ul țintă).
  final cutoff = math.min(1.0, 1 / ratio) * 0.95;
  const zeroCrossings = 10;
  final radius = (zeroCrossings / cutoff).ceil();
  final taps = 2 * radius;
  // Tabel polifazic: nucleul precalculat pentru [phases] decalaje fracționare.
  const phases = 256;
  final table = Float64List((phases + 1) * taps);
  for (var ph = 0; ph <= phases; ph++) {
    final frac = ph / phases;
    var sum = 0.0;
    for (var t = 0; t < taps; t++) {
      final d = (t - radius + 1) - frac; // k - center
      final dist = d.abs() / radius;
      var w = 0.0;
      if (dist < 1) {
        final x = d * cutoff;
        final sinc = x == 0 ? 1.0 : math.sin(math.pi * x) / (math.pi * x);
        w = sinc * (0.5 + 0.5 * math.cos(math.pi * dist)); // fereastră Hann
      }
      table[ph * taps + t] = w;
      sum += w;
    }
    for (var t = 0; t < taps; t++) {
      table[ph * taps + t] /= sum;
    }
  }
  for (var n = 0; n < outLen; n++) {
    final center = n * ratio;
    final base = center.floor();
    final row = ((center - base) * phases).round() * taps;
    final first = base - radius + 1;
    var acc = 0.0;
    for (var t = 0; t < taps; t++) {
      final k = first + t;
      if (k < 0 || k >= mono.length) continue;
      acc += mono[k] * table[row + t];
    }
    out[n] = acc.round().clamp(-32768, 32767);
  }
  return out;
}

/// Alege cel mult [seconds] secunde din mijlocul fragmentului (începutul
/// unei capturi poate conține pauza de pornire a stream-ului).
Int16List centerSegment(Int16List mono16k, {int seconds = 12}) {
  final max = seconds * 16000;
  if (mono16k.length <= max) return mono16k;
  final start = (mono16k.length - max) ~/ 2;
  return Int16List.sublistView(mono16k, start, start + max);
}
