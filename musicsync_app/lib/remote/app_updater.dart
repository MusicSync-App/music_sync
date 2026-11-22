import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'google_token_provider.dart' show RemoteServices;
import 'remote_models.dart';
import 'server_api.dart';
import 'server_config.dart';
import 'update_logic.dart';

/// Actualizările aplicației: verificare (manifestul serverului, cu rezervă
/// version.json din GitHub), dialog, descărcare APK cu progres, verificare
/// sha256 și instalare prin instalatorul sistemului (Android). Pe Windows se
/// deschide pagina release-ului în browser.
class AppUpdater {
  AppUpdater._();

  /// Pus în MaterialApp — dialogul de la pornire nu are alt BuildContext.
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  static const String _kLastCheckKey = 'app_update_last_check';
  static const MethodChannel _installer = MethodChannel('musicsync/installer');

  static bool _dialogOpen = false;

  static Future<int> installedBuild() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return parseBuildNumber(info.buildNumber);
    } catch (_) {
      return 0;
    }
  }

  static Future<bool> isOnline() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return !r.contains(ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  /// Ultima versiune: din manifestul dat / serverul, altfel direct din GitHub.
  static Future<AppVersionInfo?> latestVersion({ServerManifest? manifest}) async {
    if (manifest?.app != null) return manifest!.app;
    try {
      final m = manifest ?? await RemoteServices.api.manifest();
      if (m.app != null) return m.app;
    } on ServerException catch (e) {
      debugPrint('[AppUpdater] manifest: ${e.message} — încerc GitHub direct');
    }
    return RemoteServices.api.fallbackVersion();
  }

  /// Verificarea automată (la pornire / la 6 ore): tăcută la erori.
  static Future<void> checkInBackground({ServerManifest? manifest}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_kLastCheckKey);
      final last = lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (!shouldAutoCheck(lastCheck: last, now: DateTime.now())) return;
      if (!await isOnline()) return;

      final latest = await latestVersion(manifest: manifest);
      await prefs.setInt(_kLastCheckKey, DateTime.now().millisecondsSinceEpoch);
      final installed = await installedBuild();
      unawaited(_cleanupOldApks(installed));
      final kind = decideUpdate(installedBuild: installed, latest: latest);
      final context = navigatorKey.currentContext;
      if (kind == UpdateKind.none || context == null || !context.mounted) return;
      await _showUpdateDialog(context, latest!, kind);
    } catch (e) {
      debugPrint('[AppUpdater] verificare automată eșuată: $e');
    }
  }

  /// "Verifică actualizări" din meniu.
  static Future<void> checkManually(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      content: Text('Se verifică actualizările… (serverul poate porni în până la un minut)'),
      duration: Duration(seconds: 4),
    ));
    try {
      final latest = await latestVersion();
      final installed = await installedBuild();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastCheckKey, DateTime.now().millisecondsSinceEpoch);
      messenger.hideCurrentSnackBar();
      final kind = decideUpdate(installedBuild: installed, latest: latest);
      if (kind == UpdateKind.none) {
        messenger.showSnackBar(SnackBar(
          content: Text(latest == null
              ? 'Nu există încă nicio versiune publicată.'
              : 'Ai cea mai nouă versiune (${latest.versionName}).'),
        ));
        return;
      }
      if (context.mounted) await _showUpdateDialog(context, latest!, kind);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(errorFromException(e).message)));
    }
  }

  static Future<void> _showUpdateDialog(BuildContext context, AppVersionInfo info, UpdateKind kind) async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    try {
      final required = kind == UpdateKind.required;
      while (true) {
        if (!context.mounted) return;
        final go = await showDialog<bool>(
          context: context,
          barrierDismissible: !required,
          builder: (d) => PopScope(
            canPop: !required,
            child: AlertDialog(
              title: Text('Versiune nouă: ${info.versionName}'),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (required)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Versiunea instalată nu mai este suportată. Actualizează pentru a continua.',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orangeAccent),
                        ),
                      ),
                    if (info.notes.trim().isNotEmpty) Text(info.notes.trim()) else const Text('O nouă versiune MusicSync e disponibilă.'),
                    if (info.size != null && Platform.isAndroid)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text('Descărcare: ${formatBytes(info.size!)}', style: const TextStyle(fontSize: 12)),
                      ),
                  ],
                ),
              ),
              actions: [
                if (!required) TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Mai târziu')),
                ElevatedButton(onPressed: () => Navigator.pop(d, true), child: const Text('Actualizează')),
              ],
            ),
          ),
        );
        if (go != true || !context.mounted) return;
        final done = await _startUpdate(context, info);
        // Actualizarea obligatorie: dialogul revine până reușește.
        if (done || !required) return;
      }
    } finally {
      _dialogOpen = false;
    }
  }

  static Future<bool> _startUpdate(BuildContext context, AppVersionInfo info) async {
    if (!Platform.isAndroid) {
      final ok = await launchUrl(Uri.parse(kReleasesPageUrl), mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nu am putut deschide browserul.')));
      }
      return ok;
    }
    if (info.apkUrl.isEmpty) {
      _snack(context, 'Release-ul nu conține APK-ul.');
      return false;
    }
    if (!await _ensureInstallPermission(context) || !context.mounted) return false;

    final apk = await showDialog<File>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ApkDownloadDialog(info: info),
    );
    if (apk == null || !context.mounted) return false;
    try {
      await _installer.invokeMethod('installApk', {'path': apk.path});
      return true;
    } on PlatformException catch (e) {
      if (context.mounted) _snack(context, 'Nu am putut porni instalarea: ${e.message ?? e.code}');
      return false;
    }
  }

  /// Android 8+: permisiunea "Instalare aplicații necunoscute" pentru MusicSync.
  static Future<bool> _ensureInstallPermission(BuildContext context) async {
    var status = await Permission.requestInstallPackages.status;
    if (status.isGranted) return true;
    if (!context.mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Permite instalarea'),
        content: const Text(
          'Ca să poată instala actualizarea, Android cere permisiunea „Instalare aplicații necunoscute” '
          'pentru MusicSync.\n\nÎn ecranul care se deschide activează „Permite din această sursă”, '
          'apoi revino în aplicație.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Anulează')),
          ElevatedButton(onPressed: () => Navigator.pop(d, true), child: const Text('Deschide setările')),
        ],
      ),
    );
    if (go != true) return false;
    status = await Permission.requestInstallPackages.request();
    if (status.isGranted) return true;
    if (context.mounted) {
      _snack(context, 'Fără permisiunea de instalare actualizarea nu poate continua.');
    }
    return false;
  }

  static void _snack(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  static Future<Directory> apkDir() async {
    final cache = await getTemporaryDirectory();
    return Directory(p.join(cache.path, 'updates')); // vezi res/xml/update_file_paths.xml
  }

  static Future<void> _cleanupOldApks(int installed) async {
    if (!Platform.isAndroid) return;
    try {
      final dir = await apkDir();
      if (!await dir.exists()) return;
      await for (final f in dir.list()) {
        final m = RegExp(r'musicsync-(\d+)\.apk').firstMatch(p.basename(f.path));
        if (m == null || int.parse(m.group(1)!) <= installed) await f.delete();
      }
    } catch (_) {}
  }

  static Future<String> fileSha256(File file) async => (await sha256.bind(file.openRead()).first).toString();
}

class _ApkDownloadDialog extends StatefulWidget {
  final AppVersionInfo info;
  const _ApkDownloadDialog({required this.info});

  @override
  State<_ApkDownloadDialog> createState() => _ApkDownloadDialogState();
}

class _ApkDownloadDialogState extends State<_ApkDownloadDialog> {
  final CancelToken _cancel = CancelToken();
  int _received = 0;
  int _total = 0;
  String _phase = 'Se descarcă…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _total = widget.info.size ?? 0;
    _run();
  }

  @override
  void dispose() {
    if (!_cancel.isCancelled) _cancel.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _error = null;
      _received = 0;
      _phase = 'Se descarcă…';
    });
    try {
      final dir = await AppUpdater.apkDir();
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'musicsync-${widget.info.versionCode}.apk'));

      // Descărcat deja (ex. instalare anulată)? Refolosim dacă sha256 e corect.
      if (await file.exists() &&
          widget.info.sha256 != null &&
          checksumMatches(widget.info.sha256, await AppUpdater.fileSha256(file))) {
        if (mounted) Navigator.pop(context, file);
        return;
      }

      final tmp = File('${file.path}.part');
      await Dio().download(
        widget.info.apkUrl,
        tmp.path,
        cancelToken: _cancel,
        deleteOnError: true,
        options: Options(receiveTimeout: kDownloadTimeout, followRedirects: true),
        onReceiveProgress: (r, t) {
          if (!mounted) return;
          setState(() {
            _received = r;
            if (t > 0) _total = t;
          });
        },
      );
      if (!mounted) return;
      setState(() => _phase = 'Se verifică fișierul…');
      final actual = await AppUpdater.fileSha256(tmp);
      if (!checksumMatches(widget.info.sha256, actual)) {
        await tmp.delete();
        throw const ServerException('checksum', 'Fișierul descărcat e corupt (sha256 diferit). Încearcă din nou.');
      }
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
      if (mounted) Navigator.pop(context, file);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      if (mounted) setState(() => _error = 'Descărcarea a eșuat: ${e.message ?? e.type.name}');
    } catch (e) {
      if (mounted) setState(() => _error = errorFromException(e).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    return AlertDialog(
      title: Text('MusicSync ${widget.info.versionName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.redAccent))
          else ...[
            Text(_phase),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(
              _total > 0 ? '${formatBytes(_received)} / ${formatBytes(_total)}' : formatBytes(_received),
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _cancel.cancel();
            Navigator.pop(context);
          },
          child: const Text('Anulează'),
        ),
        if (_error != null) ElevatedButton(onPressed: _run, child: const Text('Reîncearcă')),
      ],
    );
  }
}
