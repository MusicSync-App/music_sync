import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Generatorul de amprentă audio Shazam, port în Dart pur al algoritmului
/// documentat public de SongRec (Rust) și shazamio (Python).
///
/// Intrare: PCM mono, 16 kHz, 16 biți. Ieșire: amprenta binară ("signature")
/// pe care o acceptă serviciul de recunoaștere Shazam, ca URI
/// `data:audio/vnd.shazam.sig;base64,...`.
///
/// Pași: FFT de 2048 puncte (fereastră Hanning) la fiecare 128 de eșantioane,
/// "împrăștierea" maximelor în frecvență și timp, apoi alegerea vârfurilor
/// locale din 4 benzi de frecvență (250–5500 Hz).
class ShazamSignatureGenerator {
  static const int sampleRate = 16000;
  static const int _fftSize = 2048;
  static const int _bins = _fftSize ~/ 2 + 1; // 1025
  static const int _ring = 256;

  static final Float64List _hanning = Float64List.fromList(
    List.generate(_fftSize, (i) => 0.5 - 0.5 * math.cos(2 * math.pi * (i + 1) / (_fftSize + 1))),
  );

  final Int16List _samplesRing = Int16List(_fftSize);
  int _samplesIndex = 0;

  final List<Float32List> _fftOutputs = List.generate(_ring, (_) => Float32List(_bins));
  int _fftPos = 0;

  final List<Float32List> _spreadOutputs = List.generate(_ring, (_) => Float32List(_bins));
  int _spreadPos = 0;
  int _spreadWritten = 0;

  final _Fft _fft = _Fft(_fftSize);
  final Float64List _re = Float64List(_fftSize);
  final Float64List _im = Float64List(_fftSize);

  /// Vârfurile găsite, pe benzi (0: 250–520 Hz, 1: 520–1450, 2: 1450–3500, 3: 3500–5500).
  final Map<int, List<ShazamPeak>> peaksByBand = {};
  int _numberSamples = 0;

  /// Generează amprenta pentru tot fragmentul (de preferat 8–12 secunde).
  static ShazamSignature fromPcm(Int16List samples) {
    final gen = ShazamSignatureGenerator();
    gen.feed(samples);
    return gen.build();
  }

  void feed(Int16List samples) {
    final chunks = samples.length ~/ 128;
    for (var c = 0; c < chunks; c++) {
      _doFft(samples, c * 128);
      _doPeakSpreading();
      if (_spreadWritten >= 46) _doPeakRecognition();
    }
    _numberSamples += samples.length;
  }

  ShazamSignature build() => ShazamSignature(
        numberSamples: _numberSamples,
        peaksByBand: {for (final e in peaksByBand.entries) e.key: List.unmodifiable(e.value)},
      );

  void _doFft(Int16List samples, int offset) {
    _samplesRing.setRange(_samplesIndex, _samplesIndex + 128, samples, offset);
    _samplesIndex = (_samplesIndex + 128) % _fftSize;

    for (var i = 0; i < _fftSize; i++) {
      _re[i] = _samplesRing[(i + _samplesIndex) % _fftSize] * _hanning[i];
      _im[i] = 0;
    }
    _fft.transform(_re, _im);

    final out = _fftOutputs[_fftPos];
    for (var i = 0; i < _bins; i++) {
      final v = (_re[i] * _re[i] + _im[i] * _im[i]) / (1 << 17);
      out[i] = v < 1e-10 ? 1e-10 : v;
    }
    _fftPos = (_fftPos + 1) % _ring;
  }

  void _doPeakSpreading() {
    final origin = _fftOutputs[(_fftPos - 1) % _ring];
    final spread = _spreadOutputs[_spreadPos];
    spread.setAll(0, origin);

    // Împrăștiere în frecvență.
    for (var p = 0; p <= _bins - 3; p++) {
      var m = spread[p];
      if (spread[p + 1] > m) m = spread[p + 1];
      if (spread[p + 2] > m) m = spread[p + 2];
      spread[p] = m;
    }

    // Împrăștiere în timp (spre FFT-urile anterioare).
    for (final former in const [1, 3, 6]) {
      final f = _spreadOutputs[(_spreadPos - former) % _ring];
      for (var p = 0; p < _bins; p++) {
        if (spread[p] > f[p]) f[p] = spread[p];
      }
    }
    _spreadPos = (_spreadPos + 1) % _ring;
    _spreadWritten++;
  }

  static double _magnitude(double v) {
    final l = _f32(math.log(v));
    return _f32(_f32((l < 1 / 64 ? 1 / 64 : l) * _f32(1477.3)) + 6144.0);
  }

  void _doPeakRecognition() {
    final fft46 = _fftOutputs[(_fftPos - 46) % _ring];
    final spread49 = _spreadOutputs[(_spreadPos - 49) % _ring];

    for (var bin = 10; bin < 1015; bin++) {
      final v = fft46[bin];
      if (v < 1 / 64 || v < spread49[bin - 1]) continue;

      var maxNeighbor = 0.0;
      for (final off in const [-10, -7, -4, -3, 1, 2, 5, 8]) {
        final n = spread49[bin + off];
        if (n > maxNeighbor) maxNeighbor = n;
      }
      if (v <= maxNeighbor) continue;

      var maxOther = maxNeighbor;
      for (final off in const [-53, -45, 165, 172, 179, 186, 193, 200, 214, 221, 228, 235, 242, 249]) {
        final n = _spreadOutputs[(_spreadPos + off) % _ring][bin - 1];
        if (n > maxOther) maxOther = n;
      }
      if (v <= maxOther) continue;

      final fftNumber = _spreadWritten - 46;
      final mag = _f32(_magnitude(v));
      final before = _f32(_magnitude(fft46[bin - 1]));
      final after = _f32(_magnitude(fft46[bin + 1]));
      final variation1 = _f32(mag * 2 - before - after);
      if (variation1 <= 0) continue;
      final variation2 = _f32((after - before) * 32 / variation1);
      final correctedBin = (bin * 64 + variation2.truncate()) & 0xffff;
      final hz = correctedBin * (16000 / 2 / 1024 / 64);

      final int band;
      final hzInt = hz.truncate();
      if (hzInt >= 250 && hzInt <= 519) {
        band = 0;
      } else if (hzInt >= 520 && hzInt <= 1449) {
        band = 1;
      } else if (hzInt >= 1450 && hzInt <= 3499) {
        band = 2;
      } else if (hzInt >= 3500 && hzInt <= 5500) {
        band = 3;
      } else {
        continue;
      }
      (peaksByBand[band] ??= []).add(ShazamPeak(fftPassNumber: fftNumber, magnitude: mag.truncate() & 0xffff, correctedBin: correctedBin));
    }
  }

  // Referința lucrează în float32; rotunjim la fel ca să ieșim identic.
  static final Float32List _f32buf = Float32List(1);
  static double _f32(double v) {
    _f32buf[0] = v;
    return _f32buf[0];
  }
}

class ShazamPeak {
  final int fftPassNumber;
  final int magnitude;
  final int correctedBin;
  const ShazamPeak({required this.fftPassNumber, required this.magnitude, required this.correctedBin});

  @override
  bool operator ==(Object other) =>
      other is ShazamPeak &&
      other.fftPassNumber == fftPassNumber &&
      other.magnitude == magnitude &&
      other.correctedBin == correctedBin;

  @override
  int get hashCode => Object.hash(fftPassNumber, magnitude, correctedBin);

  @override
  String toString() => 'Peak($fftPassNumber, $magnitude, $correctedBin)';
}

class ShazamSignature {
  final int numberSamples;
  final Map<int, List<ShazamPeak>> peaksByBand;
  const ShazamSignature({required this.numberSamples, required this.peaksByBand});

  int get sampleMs => (numberSamples / ShazamSignatureGenerator.sampleRate * 1000).truncate();
  int get peakCount => peaksByBand.values.fold(0, (a, l) => a + l.length);

  /// Formatul binar acceptat de Shazam (antet de 48 de octeți + benzi).
  Uint8List encode() {
    final body = BytesBuilder();
    final bands = peaksByBand.keys.toList()..sort();
    for (final band in bands) {
      final peaks = BytesBuilder();
      var pass = 0;
      for (final peak in peaksByBand[band]!) {
        if (peak.fftPassNumber - pass >= 255) {
          peaks.addByte(0xff);
          peaks.add(_u32(peak.fftPassNumber));
          pass = peak.fftPassNumber;
        }
        peaks.addByte(peak.fftPassNumber - pass);
        peaks.add(_u16(peak.magnitude));
        peaks.add(_u16(peak.correctedBin));
        pass = peak.fftPassNumber;
      }
      final bytes = peaks.toBytes();
      body.add(_u32(0x60030040 + band));
      body.add(_u32(bytes.length));
      body.add(bytes);
      body.add(Uint8List((4 - bytes.length % 4) % 4));
    }
    final bandsBytes = body.toBytes();
    final sizeMinusHeader = bandsBytes.length + 8;

    final out = ByteData(48 + sizeMinusHeader);
    out.setUint32(0, 0xcafe2580, Endian.little);
    // 4: crc32, completat mai jos
    out.setUint32(8, sizeMinusHeader, Endian.little);
    out.setUint32(12, 0x94119c00, Endian.little);
    out.setUint32(28, 3 << 27, Endian.little); // 16000 Hz
    out.setUint32(40, (numberSamples + 16000 * 0.24).truncate(), Endian.little);
    out.setUint32(44, (15 << 19) + 0x40000, Endian.little);
    out.setUint32(48, 0x40000000, Endian.little);
    out.setUint32(52, sizeMinusHeader, Endian.little);
    final result = out.buffer.asUint8List();
    result.setAll(56, bandsBytes);
    out.setUint32(4, crc32(Uint8List.sublistView(result, 8)), Endian.little);
    return result;
  }

  String toUri() => 'data:audio/vnd.shazam.sig;base64,${base64.encode(encode())}';

  /// Citește o amprentă binară (pentru teste / comparație cu referința).
  static ShazamSignature decode(Uint8List data) {
    final bd = ByteData.sublistView(data);
    if (bd.getUint32(0, Endian.little) != 0xcafe2580) throw const FormatException('magic');
    final numberSamples = (bd.getUint32(40, Endian.little) - 16000 * 0.24).round();
    final peaks = <int, List<ShazamPeak>>{};
    var i = 56;
    while (i + 8 <= data.length) {
      final band = bd.getUint32(i, Endian.little) - 0x60030040;
      final size = bd.getUint32(i + 4, Endian.little);
      i += 8;
      final end = i + size;
      var pass = 0;
      final list = peaks[band] = [];
      while (i < end) {
        var delta = data[i++];
        if (delta == 0xff) {
          pass = bd.getUint32(i, Endian.little);
          i += 4;
          delta = data[i++];
        }
        pass += delta;
        list.add(ShazamPeak(
          fftPassNumber: pass,
          magnitude: bd.getUint16(i, Endian.little),
          correctedBin: bd.getUint16(i + 2, Endian.little),
        ));
        i += 4;
      }
      i += (4 - size % 4) % 4;
    }
    return ShazamSignature(numberSamples: numberSamples, peaksByBand: peaks);
  }

  static Uint8List _u32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
  static Uint8List _u16(int v) => (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int crc32(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}

/// FFT complexă radix-2, in-place.
class _Fft {
  final int n;
  final Float64List _cos;
  final Float64List _sin;
  final Int32List _rev;

  _Fft(this.n)
      : _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Int32List(n) {
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(-2 * math.pi * i / n);
      _sin[i] = math.sin(-2 * math.pi * i / n);
    }
    final bits = (math.log(n) / math.ln2).round();
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if ((i >> b) & 1 == 1) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step];
          final wi = _sin[k * step];
          final a = start + k;
          final b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }
}
