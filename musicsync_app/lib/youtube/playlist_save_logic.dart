/// Logica pură pentru "Salvează în playlist" (fără Flutter / rețea), ca să
/// poată fi testată direct: interpretarea titlului transmis de radio,
/// alegerea celui mai bun rezultat YouTube, ordinea playlisturilor țintă
/// și verificarea permisiunii de scriere.
library;

import 'dart:convert';

const String kYoutubeReadonlyScope = 'https://www.googleapis.com/auth/youtube.readonly';
const String kYoutubeScope = 'https://www.googleapis.com/auth/youtube';
const String kYoutubeForceSslScope = 'https://www.googleapis.com/auth/youtube.force-ssl';

/// Oricare dintre acestea permite playlists.insert / playlistItems.insert.
bool hasYoutubeWriteScope(Iterable<String> grantedScopes) =>
    grantedScopes.any((s) => s == kYoutubeScope || s == kYoutubeForceSslScope);

/// Lista de scope-uri din răspunsul tokeninfo ("a b c").
Set<String> parseScopeString(String? scope) =>
    (scope ?? '').split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toSet();

// ── Melodia ──────────────────────────────────────────────────────────────────

class SongQuery {
  final String artist;
  final String title;
  const SongQuery({required this.artist, required this.title});

  String get searchText => [artist, title].where((s) => s.trim().isNotEmpty).join(' ').trim();

  String get display => artist.isEmpty ? title : '$artist — $title';

  @override
  bool operator ==(Object other) => other is SongQuery && other.artist == artist && other.title == title;

  @override
  int get hashCode => Object.hash(artist, title);

  @override
  String toString() => 'SongQuery($artist, $title)';
}

final RegExp _icyPrefix = RegExp(r'^\s*streamtitle\s*=\s*', caseSensitive: false);
final RegExp _edgeQuotes = RegExp('^[\'"]+|[\'";]+\$');

/// Titlul transmis de post (ICY, ex. "Tarkan - Şımarık") -> artist + titlu.
/// Întoarce null dacă nu pare a fi o melodie (gol, doar numele postului,
/// reclame/jingle-uri).
SongQuery? parseNowPlaying(String? raw, {String? stationName}) {
  if (raw == null) return null;
  final text = raw.replaceFirst(_icyPrefix, '').trim().replaceAll(_edgeQuotes, '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  if (stationName != null && _norm(text) == _norm(stationName)) return null;
  if (RegExp(r'^(advert|reclam|jingle|publicitate|commercial)', caseSensitive: false).hasMatch(text) ||
      RegExp(r'^(news|știri|stiri)$', caseSensitive: false).hasMatch(text)) {
    return null;
  }

  for (final sep in const [' - ', ' – ', ' — ', ' ~ ', ' | ', ' / ']) {
    final i = text.indexOf(sep);
    if (i > 0 && i + sep.length < text.length) {
      final artist = text.substring(0, i).trim();
      final title = text.substring(i + sep.length).trim();
      if (artist.isNotEmpty && title.isNotEmpty) return SongQuery(artist: artist, title: title);
    }
  }
  // Fără separator: căutăm textul întreg.
  if (_norm(text).length < 3) return null;
  return SongQuery(artist: '', title: text);
}

// ── Rezultate YouTube ────────────────────────────────────────────────────────

class VideoCandidate {
  final String id;
  final String title;
  final String author;
  final Duration? duration;
  final bool isLive;

  const VideoCandidate({
    required this.id,
    required this.title,
    required this.author,
    this.duration,
    this.isLive = false,
  });
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

Set<String> _tokens(String s) => _norm(s).split(' ').where((t) => t.length > 1 || RegExp(r'\d').hasMatch(t)).toSet();

const List<String> _penaltyWords = [
  'live', 'cover', 'karaoke', 'remix', 'reaction', 'instrumental', 'nightcore', 'sped up', 'slowed',
  '8d', 'tutorial', 'lesson', '1 hour', 'hour loop', 'mashup', 'parody', 'shorts',
];

/// Cât de bine se potrivește un rezultat cu melodia căutată (mai mare = mai bun).
int scoreCandidate(SongQuery query, VideoCandidate c) {
  final videoText = _norm('${c.title} ${c.author}');
  final videoTokens = _tokens('${c.title} ${c.author}');
  var score = 0;

  final titleTokens = _tokens(query.title);
  if (titleTokens.isNotEmpty) {
    final hit = titleTokens.where(videoTokens.contains).length;
    score += (40 * hit / titleTokens.length).round();
    if (hit == 0) score -= 30;
  }
  final artistTokens = _tokens(query.artist);
  if (artistTokens.isNotEmpty) {
    final hit = artistTokens.where(videoTokens.contains).length;
    score += (25 * hit / artistTokens.length).round();
  }

  final author = c.author.toLowerCase();
  if (author.endsWith(' - topic')) score += 15; // canalele "Artist - Topic" = piesa de pe album
  if (author.contains('vevo')) score += 10;
  final title = c.title.toLowerCase();
  if (title.contains('official')) score += 6;
  if (title.contains('audio')) score += 3;
  if (title.contains('lyric')) score += 2;

  final queryText = _norm(query.searchText);
  for (final w in _penaltyWords) {
    if (RegExp('(^| )${RegExp.escape(w)}( |\$)').hasMatch(videoText) &&
        !RegExp('(^| )${RegExp.escape(w)}( |\$)').hasMatch(queryText)) {
      score -= 12;
    }
  }

  if (c.isLive) score -= 50;
  final d = c.duration;
  if (d != null) {
    if (d.inSeconds >= 90 && d.inSeconds <= 9 * 60) {
      score += 8;
    } else if (d.inMinutes >= 15) {
      score -= 25; // mixuri / albume întregi
    } else if (d.inSeconds < 60) {
      score -= 15; // shorts / fragmente
    }
  }
  return score;
}

/// Cele mai bune [take] rezultate, în ordinea potrivirii (stabil la egalitate).
List<VideoCandidate> rankCandidates(SongQuery query, List<VideoCandidate> results, {int take = 3}) {
  final seen = <String>{};
  final indexed = <(int, int, VideoCandidate)>[];
  for (var i = 0; i < results.length; i++) {
    final c = results[i];
    if (!seen.add(c.id)) continue;
    indexed.add((scoreCandidate(query, c), i, c));
  }
  indexed.sort((a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2));
  return indexed.take(take).map((e) => e.$3).toList();
}

// ── Playlisturi țintă ────────────────────────────────────────────────────────

/// Lista din Downloader & Sync, salvată la fiecare încărcare (pentru alegerea
/// rapidă a playlistului țintă din Radio, chiar înainte de răspunsul API).
const String kDownloaderPlaylistsCacheKey = 'downloader_playlists_cache';

/// ID-urile playlisturilor adăugate manual în Downloader & Sync.
const String kCustomPlaylistsKey = 'custom_playlists';

/// Ultimul playlist în care s-a salvat o melodie (apare primul).
const String kLastSaveTargetKey = 'save_to_playlist_last_target';

class PlaylistTarget {
  final String id;
  final String title;
  final int itemCount;

  /// Playlistul e al contului conectat (în celelalte, adăugate prin link,
  /// poți scrie doar dacă ești colaborator).
  final bool owned;

  const PlaylistTarget({required this.id, required this.title, this.itemCount = 0, this.owned = true});

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'count': itemCount, 'owned': owned};

  factory PlaylistTarget.fromJson(Map<String, dynamic> j) => PlaylistTarget(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        itemCount: (j['count'] as num?)?.toInt() ?? 0,
        owned: j['owned'] as bool? ?? true,
      );
}

String encodeTargets(List<PlaylistTarget> targets) => jsonEncode(targets.map((t) => t.toJson()).toList());

List<PlaylistTarget> decodeTargets(String? raw) {
  if (raw == null || raw.isEmpty) return [];
  try {
    return (jsonDecode(raw) as List).map((e) => PlaylistTarget.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  } catch (_) {
    return [];
  }
}

/// Lista playlisturilor din "Downloader & Sync" pentru alegere: fără
/// duplicate, ultimul folosit primul, apoi cele proprii (ordinea din
/// Downloader), apoi cele colaborative.
List<PlaylistTarget> orderTargets(List<PlaylistTarget> all, {String? lastUsedId}) {
  final byId = <String, PlaylistTarget>{};
  for (final t in all) {
    if (t.id.isEmpty) continue;
    final existing = byId[t.id];
    // Dacă apare de două ori, păstrăm varianta "proprie" (mai precisă).
    if (existing == null || (!existing.owned && t.owned)) byId[t.id] = t;
  }
  final list = byId.values.toList();
  final order = {for (var i = 0; i < list.length; i++) list[i].id: i};
  list.sort((a, b) {
    if (a.id == lastUsedId) return -1;
    if (b.id == lastUsedId) return 1;
    if (a.owned != b.owned) return a.owned ? -1 : 1;
    return order[a.id]!.compareTo(order[b.id]!);
  });
  return list;
}

/// Numele unui playlist nou: curățat, cel mult 150 de caractere (limita
/// YouTube). Null dacă e gol.
String? cleanPlaylistName(String input) {
  final name = input.replaceAll(RegExp(r'[<>]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (name.isEmpty) return null;
  return name.length > 150 ? name.substring(0, 150).trim() : name;
}
