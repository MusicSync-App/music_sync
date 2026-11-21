import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart';
import 'package:googleapis/youtube/v3.dart' as yt;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as ye;

import '../main.dart' show GoogleAuthManager;
import 'playlist_save_logic.dart';

enum YouTubeAccess {
  ok,

  /// Niciun cont Google conectat în aplicație.
  notSignedIn,

  /// Conectat doar cu `youtube.readonly` (înainte de această funcție).
  needsWriteConsent,

  /// Token expirat / revocat.
  expired,
}

enum SaveErrorKind { noInternet, needsConsent, expired, notAllowed, quota, other }

class SaveToPlaylistException implements Exception {
  final SaveErrorKind kind;
  final String message;
  SaveToPlaylistException(this.kind, this.message);

  @override
  String toString() => message;
}

/// Căutarea pe YouTube (fără API, fără cotă) și scrierea în playlisturi
/// (YouTube Data API: playlistItems.insert / playlists.insert).
class YouTubePlaylistService {
  YouTubePlaylistService._();

  static Future<bool> isOnline() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return !r.contains(ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  // ── Autentificare ─────────────────────────────────────────────────────────

  /// Credențialele curente. Fără [interactive] nu deschidem nicio fereastră
  /// de conectare pentru cine nu s-a conectat niciodată.
  static Future<GoogleSignInCredentials?> credentials({bool interactive = false}) async {
    final cached = GoogleAuthManager.lastCredentials;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final wasSignedIn = prefs.getString('user_logged_email') != null;
    if (!wasSignedIn && !interactive) return null;
    final creds = await GoogleAuthManager.instance.signIn();
    if (creds != null) await _adopt(creds);
    return creds;
  }

  static Future<void> _adopt(GoogleSignInCredentials creds) async {
    GoogleAuthManager.lastCredentials = creds;
    // Ca Downloader & Sync să se reconecteze singur data viitoare.
    try {
      final res = await http.get(
        Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
        headers: {'Authorization': 'Bearer ${creds.accessToken}'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final prefs = await SharedPreferences.getInstance();
        final email = data['email'] as String?;
        final name = data['name'] as String?;
        if (email != null && email.isNotEmpty) await prefs.setString('user_logged_email', email);
        if (name != null && name.isNotEmpty) await prefs.setString('user_logged_name', name);
      }
    } catch (_) {}
  }

  /// Scope-urile acordate efectiv tokenului (null = token invalid/expirat).
  static Future<Set<String>?> grantedScopes(String accessToken) async {
    final res = await http
        .get(Uri.https('oauth2.googleapis.com', '/tokeninfo', {'access_token': accessToken}))
        .timeout(const Duration(seconds: 12));
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return parseScopeString(data['scope'] as String?);
    }
    if (res.statusCode == 400 || res.statusCode == 401) return null;
    throw SaveToPlaylistException(SaveErrorKind.other, 'Google nu răspunde (${res.statusCode}).');
  }

  static Future<(YouTubeAccess, GoogleSignInCredentials?)> checkAccess({bool interactive = false}) async {
    final creds = await credentials(interactive: interactive);
    if (creds == null) return (YouTubeAccess.notSignedIn, null);
    final Set<String>? scopes;
    try {
      scopes = await grantedScopes(creds.accessToken);
    } on SocketException {
      throw SaveToPlaylistException(SaveErrorKind.noInternet, 'Fără internet.');
    } on TimeoutException {
      throw SaveToPlaylistException(SaveErrorKind.noInternet, 'Conexiunea la Google a expirat.');
    }
    if (scopes == null) {
      GoogleAuthManager.lastCredentials = null;
      return (YouTubeAccess.expired, creds);
    }
    if (!hasYoutubeWriteScope(scopes)) return (YouTubeAccess.needsWriteConsent, creds);
    return (YouTubeAccess.ok, creds);
  }

  /// Reconectare cu toate scope-urile (inclusiv scrierea în playlisturi):
  /// pe Android apare alegerea contului + ecranul de consimțământ, pe
  /// Windows se deschide browserul.
  static Future<GoogleSignInCredentials?> reauthorize() async {
    final gs = GoogleAuthManager.instance;
    GoogleAuthManager.lastCredentials = null;
    try {
      await gs.signOut();
    } catch (_) {}
    final creds = Platform.isAndroid || Platform.isIOS ? await gs.signIn() : await gs.signInOnline();
    if (creds != null) await _adopt(creds);
    return creds;
  }

  static yt.YouTubeApi api(GoogleSignInCredentials creds) => GoogleAuthManager.youtubeApiFor(creds);

  // ── Căutare melodie ───────────────────────────────────────────────────────

  static Future<List<VideoCandidate>> search(SongQuery query) async {
    final client = ye.YoutubeExplode();
    try {
      final results = await client.search.search(query.searchText).timeout(const Duration(seconds: 20));
      return [
        for (final v in results.take(20))
          VideoCandidate(
            id: v.id.value,
            title: v.title,
            author: v.author,
            duration: v.duration,
            isLive: v.isLive,
          ),
      ];
    } on SocketException {
      throw SaveToPlaylistException(SaveErrorKind.noInternet, 'Fără internet — nu pot căuta pe YouTube.');
    } on TimeoutException {
      throw SaveToPlaylistException(SaveErrorKind.noInternet, 'YouTube nu a răspuns la timp.');
    } finally {
      client.close();
    }
  }

  // ── Playlisturi ───────────────────────────────────────────────────────────

  static Future<String?> lastTargetId() async =>
      (await SharedPreferences.getInstance()).getString(kLastSaveTargetKey);

  /// Lista salvată de Downloader & Sync (instant, fără rețea).
  static Future<List<PlaylistTarget>> cachedTargets() async {
    final prefs = await SharedPreferences.getInstance();
    return orderTargets(
      decodeTargets(prefs.getString(kDownloaderPlaylistsCacheKey)),
      lastUsedId: prefs.getString(kLastSaveTargetKey),
    );
  }

  /// Aceeași listă ca în Downloader & Sync: playlisturile contului + cele
  /// adăugate prin link.
  static Future<List<PlaylistTarget>> fetchTargets(yt.YouTubeApi api) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final mine = <PlaylistTarget>[];
      String? pageToken;
      for (var page = 0; page < 4; page++) {
        final res = await api.playlists.list(
          ['snippet', 'contentDetails'],
          mine: true,
          maxResults: 50,
          pageToken: pageToken,
        );
        for (final p in res.items ?? const <yt.Playlist>[]) {
          if (p.id == null) continue;
          mine.add(PlaylistTarget(
            id: p.id!,
            title: p.snippet?.title ?? p.id!,
            itemCount: p.contentDetails?.itemCount ?? 0,
          ));
        }
        pageToken = res.nextPageToken;
        if (pageToken == null) break;
      }

      final mineIds = mine.map((t) => t.id).toSet();
      final customIds = (prefs.getStringList(kCustomPlaylistsKey) ?? const <String>[])
          .where((id) => !mineIds.contains(id))
          .toList();
      final custom = <PlaylistTarget>[];
      for (var i = 0; i < customIds.length; i += 50) {
        final chunk = customIds.sublist(i, (i + 50).clamp(0, customIds.length));
        final res = await api.playlists.list(['snippet', 'contentDetails'], id: chunk, maxResults: 50);
        for (final p in res.items ?? const <yt.Playlist>[]) {
          if (p.id == null) continue;
          custom.add(PlaylistTarget(
            id: p.id!,
            title: p.snippet?.title ?? p.id!,
            itemCount: p.contentDetails?.itemCount ?? 0,
            owned: false,
          ));
        }
      }

      // Ca în Downloader & Sync: cele adăugate prin link primele.
      final all = [...custom, ...mine];
      await prefs.setString(kDownloaderPlaylistsCacheKey, encodeTargets(all));
      return orderTargets(all, lastUsedId: prefs.getString(kLastSaveTargetKey));
    } catch (e) {
      throw _mapError(e);
    }
  }

  static Future<bool> containsVideo(yt.YouTubeApi api, String playlistId, String videoId) async {
    try {
      final res = await api.playlistItems.list(['id'], playlistId: playlistId, videoId: videoId, maxResults: 1);
      return (res.items ?? const []).isNotEmpty;
    } catch (e) {
      throw _mapError(e);
    }
  }

  static Future<void> addVideo(yt.YouTubeApi api, String playlistId, String videoId) async {
    try {
      await api.playlistItems.insert(
        yt.PlaylistItem(
          snippet: yt.PlaylistItemSnippet(
            playlistId: playlistId,
            resourceId: yt.ResourceId(kind: 'youtube#video', videoId: videoId),
          ),
        ),
        ['snippet'],
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kLastSaveTargetKey, playlistId);
    } catch (e) {
      throw _mapError(e);
    }
  }

  /// Creează playlistul (privat implicit) și îl adaugă în Downloader & Sync.
  static Future<PlaylistTarget> createPlaylist(yt.YouTubeApi api, String name, {String privacy = 'private'}) async {
    try {
      final created = await api.playlists.insert(
        yt.Playlist(
          snippet: yt.PlaylistSnippet(title: name, description: 'Creat din MusicSync (Radio & Shazam)'),
          status: yt.PlaylistStatus(privacyStatus: privacy),
        ),
        ['snippet', 'status'],
      );
      final id = created.id;
      if (id == null) throw SaveToPlaylistException(SaveErrorKind.other, 'YouTube nu a întors ID-ul playlistului.');
      final target = PlaylistTarget(id: id, title: created.snippet?.title ?? name);

      final prefs = await SharedPreferences.getInstance();
      final custom = prefs.getStringList(kCustomPlaylistsKey) ?? <String>[];
      if (!custom.contains(id)) await prefs.setStringList(kCustomPlaylistsKey, [...custom, id]);
      final cached = decodeTargets(prefs.getString(kDownloaderPlaylistsCacheKey));
      await prefs.setString(kDownloaderPlaylistsCacheKey, encodeTargets([target, ...cached]));
      GoogleAuthManager.playlistsChanged.value++;
      return target;
    } catch (e) {
      throw _mapError(e);
    }
  }

  static SaveToPlaylistException _mapError(Object e) {
    if (e is SaveToPlaylistException) return e;
    if (e is SocketException || e is http.ClientException || e is TimeoutException) {
      return SaveToPlaylistException(SaveErrorKind.noInternet, 'Fără internet — încearcă din nou când ești online.');
    }
    if (e is yt.DetailedApiRequestError) {
      final reasons = [for (final err in e.errors) err.reason ?? '', e.message ?? ''].join(' ');
      if (e.status == 401) {
        return SaveToPlaylistException(SaveErrorKind.expired, 'Sesiunea Google a expirat — reconectează-te.');
      }
      if (reasons.contains('quotaExceeded') || reasons.contains('rateLimitExceeded')) {
        return SaveToPlaylistException(SaveErrorKind.quota, 'Cota zilnică YouTube API a fost depășită — încearcă mâine.');
      }
      if (reasons.contains('insufficientPermissions') ||
          reasons.contains('ACCESS_TOKEN_SCOPE_INSUFFICIENT') ||
          reasons.contains('insufficient authentication scopes')) {
        return SaveToPlaylistException(
          SaveErrorKind.needsConsent,
          'MusicSync nu are încă voie să modifice playlisturile tale YouTube.',
        );
      }
      if (reasons.contains('playlistContainsMaximumNumberOfVideos')) {
        return SaveToPlaylistException(SaveErrorKind.other, 'Playlistul a atins limita de 5000 de melodii.');
      }
      if (e.status == 403) {
        return SaveToPlaylistException(
          SaveErrorKind.notAllowed,
          'Nu ai voie să adaugi în acest playlist (nu e al contului tău sau nu ești colaborator).',
        );
      }
      if (e.status == 404) {
        return SaveToPlaylistException(SaveErrorKind.other, 'Playlistul sau videoclipul nu mai există pe YouTube.');
      }
      return SaveToPlaylistException(SaveErrorKind.other, 'Eroare YouTube (${e.status}): ${e.message}');
    }
    return SaveToPlaylistException(SaveErrorKind.other, e.toString());
  }
}
