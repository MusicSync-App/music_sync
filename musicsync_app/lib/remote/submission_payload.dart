/// Construirea trimiterilor ("Publică pentru toți") — logică pură.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

const int kMaxSubmissionPhotos = 10;
const int kUploadMaxSide = 1600;
const int kUploadJpegQuality = 85;

/// meta pentru kind=country (o țară adăugată de utilizator).
Map<String, dynamic> countrySubmissionMeta({
  required String countryCode,
  required String name,
  required int colorValue,
  List<String> keywords = const [],
}) =>
    {
      'kind': 'country',
      'countryCode': countryCode.toUpperCase(),
      'name': name.trim(),
      'colorValue': colorValue,
      'keywords': [for (final k in keywords) if (k.trim().length >= 2) k.trim()],
    };

/// meta pentru kind=photos (poze proprii adăugate la o temă existentă).
Map<String, dynamic> photosSubmissionMeta({required String themeId, String? name, String? countryCode}) => {
      'kind': 'photos',
      'themeId': themeId,
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (countryCode != null && countryCode.isNotEmpty) 'countryCode': countryCode.toUpperCase(),
    };

/// Mesajul de eroare (română) sau null dacă trimiterea e validă.
String? validateSubmission(Map<String, dynamic> meta, int photoCount) {
  if (photoCount > kMaxSubmissionPhotos) return 'Poți trimite cel mult $kMaxSubmissionPhotos poze odată.';
  switch (meta['kind']) {
    case 'country':
      final cc = meta['countryCode'];
      if (cc is! String || !RegExp(r'^[A-Z]{2}$').hasMatch(cc)) return 'Codul țării lipsește.';
      if ((meta['name'] as String?)?.trim().isEmpty ?? true) return 'Numele temei lipsește.';
      if (meta['colorValue'] is! int) return 'Culoarea temei lipsește.';
      return null;
    case 'photos':
      if ((meta['themeId'] as String?)?.isEmpty ?? true) return 'Tema lipsește.';
      if (photoCount < 1) return 'Alege cel puțin o poză.';
      return null;
    default:
      return 'Tip de trimitere necunoscut.';
  }
}

/// Micșorează la latura maximă [maxSide] și re-encodează JPEG (fără EXIF,
/// orientarea aplicată). null dacă imaginea nu poate fi citită.
Uint8List? compressForUpload(Uint8List input, {int maxSide = kUploadMaxSide, int quality = kUploadJpegQuality}) {
  final decoded = img.decodeImage(input);
  if (decoded == null) return null;
  var image = img.bakeOrientation(decoded);
  final longSide = image.width > image.height ? image.width : image.height;
  if (longSide > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
  }
  image.exif.clear();
  return img.encodeJpg(image, quality: quality);
}
