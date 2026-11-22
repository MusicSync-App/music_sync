import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show GoogleAuthManager;
import '../youtube/youtube_playlist_service.dart';
import 'server_api.dart';

/// Tokenul Google al aplicației (același cont ca Downloader & Sync).
class GoogleTokenProvider implements AuthTokenProvider {
  @override
  Future<String?> accessToken({bool interactive = false}) async {
    try {
      final creds = await YouTubePlaylistService.credentials(interactive: interactive);
      return creds?.accessToken;
    } catch (e) {
      debugPrint('[GoogleTokenProvider] $e');
      return null;
    }
  }

  @override
  Future<String?> refreshAccessToken({bool interactive = false}) async {
    final old = GoogleAuthManager.lastCredentials?.accessToken;
    GoogleAuthManager.lastCredentials = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final wasSignedIn = prefs.getString('user_logged_email') != null;
      if (wasSignedIn || interactive) {
        // Întâi reconectarea tăcută (token nou din sesiunea salvată).
        final creds = await GoogleAuthManager.instance.signIn();
        if (creds != null && creds.accessToken != old) {
          GoogleAuthManager.lastCredentials = creds;
          return creds.accessToken;
        }
      }
      if (!interactive) return null;
      final creds = await YouTubePlaylistService.reauthorize();
      return creds?.accessToken;
    } catch (e) {
      debugPrint('[GoogleTokenProvider] refresh: $e');
      return null;
    }
  }
}

/// Instanța comună a clientului + steagul de admin (memorat local).
class RemoteServices {
  RemoteServices._();

  static ServerApi? _api;
  static ServerApi get api => _api ??= ServerApi(tokens: GoogleTokenProvider());

  /// Pentru teste / alt server.
  static set api(ServerApi value) => _api = value;

  static const String _kIsAdminKey = 'server_is_admin';

  /// "Moderare" apare doar când /api/me a spus isAdmin.
  static final ValueNotifier<bool> isAdmin = ValueNotifier(false);

  static Future<void> loadCachedAdminFlag() async {
    final prefs = await SharedPreferences.getInstance();
    isAdmin.value = prefs.getBool(_kIsAdminKey) ?? false;
  }

  /// Fără ferestre de conectare: doar dacă utilizatorul e deja conectat.
  static Future<void> refreshAdminFlag({bool interactive = false}) async {
    try {
      final me = await api.me(interactive: interactive);
      isAdmin.value = me.isAdmin;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kIsAdminKey, me.isAdmin);
    } on ServerException catch (e) {
      if (e.code == 'not_signed_in' || e.code == 'unauthorized') {
        isAdmin.value = false;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kIsAdminKey, false);
      }
      debugPrint('[RemoteServices] /api/me: ${e.message}');
    }
  }
}
