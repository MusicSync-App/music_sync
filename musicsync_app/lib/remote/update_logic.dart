/// Logica pură a actualizărilor (testabilă fără Flutter).
library;

import 'remote_models.dart';
import 'server_config.dart';

enum UpdateKind {
  /// Versiunea instalată e la zi (sau nu știm nimic despre una nouă).
  none,

  /// Există o versiune nouă — utilizatorul poate amâna.
  optional,

  /// Versiunea instalată e sub `minSupported` — fără "Mai târziu".
  required,
}

UpdateKind decideUpdate({required int installedBuild, required AppVersionInfo? latest}) {
  if (latest == null || latest.versionCode <= installedBuild) return UpdateKind.none;
  return installedBuild < latest.minSupported ? UpdateKind.required : UpdateKind.optional;
}

/// Build number-ul din package_info ("3", "1.0.0+3" pe unele platforme).
int parseBuildNumber(String raw) {
  final s = raw.trim();
  final direct = int.tryParse(s);
  if (direct != null) return direct;
  final plus = s.lastIndexOf('+');
  if (plus >= 0) return int.tryParse(s.substring(plus + 1)) ?? 0;
  final digits = RegExp(r'(\d+)$').firstMatch(s);
  return digits == null ? 0 : int.parse(digits.group(1)!);
}

/// Verificarea automată: cel mult o dată la [interval].
bool shouldAutoCheck({DateTime? lastCheck, required DateTime now, Duration interval = kRemoteCheckInterval}) =>
    lastCheck == null || now.difference(lastCheck) >= interval || now.isBefore(lastCheck);

/// sha256 așteptat vs. calculat (hex, fără diferențe de majuscule).
/// Fără sha256 în version.json nu putem verifica -> acceptăm.
bool checksumMatches(String? expected, String actual) =>
    expected == null || expected.trim().isEmpty || expected.trim().toLowerCase() == actual.trim().toLowerCase();

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
