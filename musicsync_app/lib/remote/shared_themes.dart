import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../radio/geo.dart' show flagEmoji;
import '../themes/app_themes.dart';
import '../themes/country_detector.dart';
import '../themes/theme_photos.dart';
import '../themes/user_themes.dart' show buildColorTheme;
import 'google_token_provider.dart' show RemoteServices;
import 'remote_models.dart';
import 'server_api.dart';
import 'shared_themes_logic.dart';

const int kDefaultSharedThemeColor = 0xFF1A5FA8;

/// Temele comune (aprobate de moderator, din repo-ul public de conținut).
///
/// Sincronizare: manifest -> dacă `content.revision` s-a schimbat se descarcă
/// index.json, pozele lipsă (după sha256) și se șterg cele care nu mai sunt
/// folosite. Totul e salvat local în `shared_themes/`, deci funcționează
/// complet offline după aceea.
class SharedThemes extends ChangeNotifier {
  SharedThemes._();
  static final SharedThemes instance = SharedThemes._();

  Directory? _root;
  SharedIndex _index = SharedIndex.empty;
  ContentInfo? _content;
  List<ResolvedSharedTheme> _resolved = const [];
  final Set<String> _registeredThemeIds = {};
  Future<bool>? _syncing;

  ContentInfo? get content => _content;
  SharedIndex get index => _index;

  /// Temele comune noi (nu cele care doar adaugă poze la o temă inclusă).
  List<ResolvedSharedTheme> get communityThemes => [for (final r in _resolved) if (!r.mergesIntoBuiltin) r];
  List<ResolvedSharedTheme> get all => _resolved;

  bool isCommunityTheme(String themeId) => _registeredThemeIds.contains(themeId);
  SharedThemeEntry? entryFor(String appThemeId) =>
      _resolved.where((r) => r.appThemeId == appThemeId).firstOrNull?.entry;

  Directory get _photosDir => Directory(p.join(_root!.path, 'photos'));
  File get _indexFile => File(p.join(_root!.path, 'index.json'));
  File get _stateFile => File(p.join(_root!.path, 'state.json'));

  /// La pornire: citește indexul salvat (fără rețea).
  Future<void> init() async {
    try {
      final support = await getApplicationSupportDirectory();
      _root = Directory(p.join(support.path, 'shared_themes'));
      await _photosDir.create(recursive: true);
      if (await _indexFile.exists()) {
        _index = SharedIndex.fromJson(jsonDecode(await _indexFile.readAsString()));
      }
      if (await _stateFile.exists()) {
        final state = jsonDecode(await _stateFile.readAsString());
        if (state is Map) _content = ContentInfo.tryParse(state['content']);
      }
    } catch (e) {
      debugPrint('[SharedThemes] index local stricat: $e');
      _index = SharedIndex.empty;
    }
    _apply();
  }

  String emojiFor(SharedThemeEntry e) => (e.countryCode?.length == 2) ? flagEmoji(e.countryCode!) : '🌍';

  /// Înregistrează temele în aplicație (appThemes, poze, detector).
  void _apply() {
    for (final id in _registeredThemeIds) {
      appThemes.remove(id);
    }
    _registeredThemeIds.clear();
    clearSharedThemes();

    _resolved = resolveSharedThemes(_index, kBuiltinThemeIds.where(appThemes.containsKey));
    final photos = <String, List<File>>{};
    for (final r in _resolved) {
      final e = r.entry;
      if (!r.mergesIntoBuiltin) {
        appThemes[r.appThemeId] = buildColorTheme(
          id: r.appThemeId,
          name: e.name,
          accent: Color(e.colorValue ?? kDefaultSharedThemeColor),
          photoFolder: 'shared_${r.appThemeId}', // pozele proprii adăugate peste tema comună
        );
        _registeredThemeIds.add(r.appThemeId);
      }
      registerSharedTheme(r.appThemeId, countryCode: e.countryCode, keywords: [...e.keywords, if (!r.mergesIntoBuiltin) e.name]);
      if (_root != null) {
        (photos[r.appThemeId] ??= []).addAll([for (final ph in e.photos) File(p.join(_photosDir.path, ph.localFileName))]);
      }
    }
    ThemePhotos.instance.setSharedPhotos(photos);
    notifyListeners();
  }

  /// Sincronizare. [content] (ex. după approve, cu noua revizie) evită încă un
  /// apel la manifest. Întoarce true dacă s-a schimbat ceva.
  Future<bool> sync({ServerManifest? manifest, ContentInfo? content, bool force = false}) {
    return _syncing ??= _doSync(manifest: manifest, content: content, force: force).whenComplete(() => _syncing = null);
  }

  Future<bool> _doSync({ServerManifest? manifest, ContentInfo? content, bool force = false}) async {
    if (_root == null) await init();
    final api = RemoteServices.api;
    final info = content ?? (manifest ?? await api.manifest()).content;
    if (info == null) return false;

    final localNames = await _localPhotoNames();
    final upToDate = info.revision == _content?.revision && planPhotoSync(_index, localNames).toDownload.isEmpty;
    if (upToDate && !force) return false;

    SharedIndex newIndex;
    try {
      newIndex = await api.sharedIndex(info.indexUrl);
    } on ServerException catch (e) {
      // Repo-ul de conținut fără index.json (înainte de prima aprobare) = nicio temă comună.
      if (e.statusCode != 404) rethrow;
      newIndex = SharedIndex.empty;
    }
    final plan = planPhotoSync(newIndex, localNames);
    var allOk = true;
    for (final photo in plan.toDownload) {
      try {
        final bytes = await api.downloadBytes(photoUrl(info, photo));
        if (sha256.convert(bytes).toString() != photo.sha256) {
          debugPrint('[SharedThemes] sha256 greșit pentru ${photo.path}');
          allOk = false;
          continue;
        }
        final file = File(p.join(_photosDir.path, photo.localFileName));
        final tmp = File('${file.path}.part');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
      } catch (e) {
        debugPrint('[SharedThemes] poză nedescărcată ${photo.path}: $e');
        allOk = false;
      }
    }
    for (final name in plan.toDelete) {
      try {
        await File(p.join(_photosDir.path, name)).delete();
      } catch (_) {}
    }

    _index = newIndex;
    await _indexFile.writeAsString(jsonEncode(newIndex.toJson()), flush: true);
    // Revizia se marchează doar când toate pozele sunt aici — altfel reîncercăm data viitoare.
    if (allOk) {
      _content = info;
      await _stateFile.writeAsString(jsonEncode({'content': info.toJson()}), flush: true);
    }
    _apply();
    return true;
  }

  Future<List<String>> _localPhotoNames() async {
    final dir = _photosDir;
    if (!await dir.exists()) return [];
    return [await for (final f in dir.list()) if (f is File) p.basename(f.path)];
  }

  /// După o acțiune de admin care a întors noua revizie.
  Future<void> syncAfterAdminChange(String? newRevision) async {
    try {
      final c = _content;
      if (newRevision != null && c != null && c.baseUrl.contains(c.revision)) {
        await sync(content: c.withRevision(newRevision), force: true);
      } else {
        await sync(force: true);
      }
    } on ServerException catch (e) {
      debugPrint('[SharedThemes] sync după admin: ${e.message}');
    }
  }
}
