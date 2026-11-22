import 'dart:async';

import 'package:flutter/foundation.dart';

import '../main.dart' show GoogleAuthManager;
import 'app_updater.dart';
import 'google_token_provider.dart' show RemoteServices;
import 'remote_models.dart';
import 'server_api.dart';
import 'server_config.dart';
import 'shared_themes.dart';

/// Verificările de fundal: la ~5 s după pornire și apoi la 6 ore (și la
/// revenirea în aplicație, dacă au trecut 6 ore), doar cu internet.
/// Un singur apel la manifest servește și actualizările și temele comune.
/// Nu blochează niciodată interfața; erorile sunt doar logate.
class RemoteBootstrap {
  RemoteBootstrap._();

  static Timer? _timer;
  static DateTime? _lastRun;
  static bool _running = false;

  static void start() {
    if (_timer != null) return;
    Future.delayed(const Duration(seconds: 5), runCycle);
    _timer = Timer.periodic(kRemoteCheckInterval, (_) => runCycle());
  }

  /// La revenirea în aplicație (din fundal).
  static void onResumed() {
    final last = _lastRun;
    if (last != null && DateTime.now().difference(last) >= kRemoteCheckInterval) runCycle();
  }

  static Future<void> runCycle() async {
    if (_running) return;
    _running = true;
    try {
      if (!await AppUpdater.isOnline()) return;
      _lastRun = DateTime.now();

      ServerManifest? manifest;
      try {
        manifest = await RemoteServices.api.manifest();
      } on ServerException catch (e) {
        debugPrint('[RemoteBootstrap] manifest indisponibil: ${e.message}');
      }

      if (manifest?.content != null) {
        try {
          await SharedThemes.instance.sync(manifest: manifest);
        } catch (e) {
          debugPrint('[RemoteBootstrap] sync teme comune: $e');
        }
      }

      // Fără manifest -> AppUpdater încearcă version.json direct din GitHub.
      await AppUpdater.checkInBackground(manifest: manifest);

      // Steagul de admin — doar dacă e deja conectat în această sesiune
      // (fără ferestre de conectare la pornire).
      if (GoogleAuthManager.lastCredentials != null) await RemoteServices.refreshAdminFlag();
    } finally {
      _running = false;
    }
  }
}
