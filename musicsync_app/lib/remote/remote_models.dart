/// Modelele JSON ale serverului MusicSync (vezi contractul server ⇄ app).
/// Pur Dart — fără Flutter — ca să poată fi testate direct.
library;

int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
String? _str(Object? v) => v?.toString();
List<String> _strings(Object? v) => [for (final e in (v is List ? v : const [])) if (e != null) e.toString()];

/// version.json (asset al release-ului; și `app` din /api/manifest).
class AppVersionInfo {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String? sha256;
  final int? size;
  final String notes;
  final int minSupported;
  final DateTime? publishedAt;

  const AppVersionInfo({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    this.sha256,
    this.size,
    this.notes = '',
    this.minSupported = 0,
    this.publishedAt,
  });

  /// null dacă JSON-ul nu e un version.json valid.
  static AppVersionInfo? tryParse(Object? json) {
    if (json is! Map) return null;
    final code = _int(json['versionCode']);
    if (code == null) return null;
    return AppVersionInfo(
      versionCode: code,
      versionName: _str(json['versionName']) ?? '$code',
      apkUrl: _str(json['apkUrl']) ?? '',
      sha256: _str(json['sha256'])?.toLowerCase(),
      size: _int(json['size']),
      notes: _str(json['notes']) ?? '',
      minSupported: _int(json['minSupported']) ?? 0,
      publishedAt: DateTime.tryParse(_str(json['publishedAt']) ?? ''),
    );
  }
}

/// `content` din /api/manifest: revizia repo-ului cu temele comune.
class ContentInfo {
  final String revision;
  final String indexUrl;
  final String baseUrl;

  const ContentInfo({required this.revision, required this.indexUrl, required this.baseUrl});

  static ContentInfo? tryParse(Object? json) {
    if (json is! Map) return null;
    final rev = _str(json['revision']);
    final index = _str(json['indexUrl']);
    if (rev == null || rev.isEmpty || index == null || index.isEmpty) return null;
    var base = _str(json['baseUrl']) ?? index.substring(0, index.lastIndexOf('/') + 1);
    if (!base.endsWith('/')) base = '$base/';
    return ContentInfo(revision: rev, indexUrl: index, baseUrl: base);
  }

  /// Aceeași locație, altă revizie (după approve/delete serverul întoarce
  /// noul sha — nu așteptăm cache-ul de 5 min al manifestului).
  ContentInfo withRevision(String newRevision) {
    if (newRevision == revision || !baseUrl.contains(revision)) return this;
    return ContentInfo(
      revision: newRevision,
      indexUrl: indexUrl.replaceFirst(revision, newRevision),
      baseUrl: baseUrl.replaceFirst(revision, newRevision),
    );
  }

  Map<String, dynamic> toJson() => {'revision': revision, 'indexUrl': indexUrl, 'baseUrl': baseUrl};
}

class ServerManifest {
  final AppVersionInfo? app;
  final ContentInfo? content;
  const ServerManifest({this.app, this.content});

  factory ServerManifest.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return ServerManifest(app: AppVersionInfo.tryParse(m['app']), content: ContentInfo.tryParse(m['content']));
  }
}

class MeInfo {
  final String email;
  final bool isAdmin;
  const MeInfo({required this.email, required this.isAdmin});

  factory MeInfo.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return MeInfo(email: _str(m['email']) ?? '', isAdmin: m['isAdmin'] == true);
  }
}

enum SubmissionStatus { pending, approved, rejected, unknown }

SubmissionStatus parseSubmissionStatus(String? s) => switch (s) {
      'pending' => SubmissionStatus.pending,
      'approved' => SubmissionStatus.approved,
      'rejected' => SubmissionStatus.rejected,
      _ => SubmissionStatus.unknown,
    };

/// O trimitere (din /api/submissions/mine sau /api/admin/submissions).
class Submission {
  final String id;
  final String kind; // "country" | "photos"
  final String? name;
  final String? countryCode;
  final String? themeId;
  final int? colorValue;
  final List<String> keywords;
  final SubmissionStatus status;
  final String? reason;
  final DateTime? createdAt;

  /// Doar în lista de moderare.
  final String? submitterEmail;
  final List<String> photoUrls;

  const Submission({
    required this.id,
    required this.kind,
    this.name,
    this.countryCode,
    this.themeId,
    this.colorValue,
    this.keywords = const [],
    this.status = SubmissionStatus.pending,
    this.reason,
    this.createdAt,
    this.submitterEmail,
    this.photoUrls = const [],
  });

  factory Submission.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return Submission(
      id: _str(m['id']) ?? '',
      kind: _str(m['kind']) ?? 'country',
      name: _str(m['name']),
      countryCode: _str(m['countryCode']),
      themeId: _str(m['themeId']),
      colorValue: _int(m['colorValue']),
      keywords: _strings(m['keywords']),
      status: parseSubmissionStatus(_str(m['status'])),
      reason: _str(m['reason']),
      createdAt: DateTime.tryParse(_str(m['createdAt']) ?? ''),
      submitterEmail: _str(m['submitterEmail']),
      photoUrls: _strings(m['photoUrls']),
    );
  }

  static List<Submission> listFromJson(Object? json) {
    // Tolerăm și {"submissions": [...]} / {"items": [...]}.
    final list = json is List ? json : (json is Map ? (json['submissions'] ?? json['items']) : null);
    return [for (final e in (list is List ? list : const [])) Submission.fromJson(e)];
  }

  /// "În așteptare" / "Aprobat" / "Respins: motiv".
  String get statusLabel => switch (status) {
        SubmissionStatus.pending => 'În așteptare',
        SubmissionStatus.approved => 'Aprobat',
        SubmissionStatus.rejected => (reason == null || reason!.trim().isEmpty) ? 'Respins' : 'Respins: ${reason!.trim()}',
        SubmissionStatus.unknown => 'Necunoscut',
      };
}

// ── index.json (repo-ul cu temele comune) ───────────────────────────────────

class SharedPhoto {
  final String path;
  final String sha256;
  final int? w;
  final int? h;
  const SharedPhoto({required this.path, required this.sha256, this.w, this.h});

  /// Numele fișierului local: `<sha256>.jpg`.
  String get localFileName => '$sha256.jpg';

  static SharedPhoto? tryParse(Object? json) {
    if (json is! Map) return null;
    final sha = _str(json['sha256'])?.toLowerCase();
    if (sha == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
    return SharedPhoto(path: _str(json['path']) ?? 'photos/$sha.jpg', sha256: sha, w: _int(json['w']), h: _int(json['h']));
  }

  Map<String, dynamic> toJson() => {'path': path, 'sha256': sha256, 'w': w, 'h': h};
}

class SharedThemeEntry {
  final String id;
  final bool builtin;
  final String? countryCode;
  final String name;
  final int? colorValue;
  final List<String> keywords;
  final List<SharedPhoto> photos;
  final String? updatedAt;

  const SharedThemeEntry({
    required this.id,
    required this.builtin,
    this.countryCode,
    required this.name,
    this.colorValue,
    this.keywords = const [],
    this.photos = const [],
    this.updatedAt,
  });

  static SharedThemeEntry? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = _str(json['id']);
    if (id == null || id.isEmpty) return null;
    final cc = _str(json['countryCode'])?.toUpperCase();
    return SharedThemeEntry(
      id: id,
      builtin: json['builtin'] == true,
      countryCode: (cc == null || cc.isEmpty) ? null : cc,
      name: _str(json['name']) ?? id,
      colorValue: _int(json['colorValue']),
      keywords: _strings(json['keywords']),
      photos: [
        for (final p in (json['photos'] is List ? json['photos'] as List : const []))
          if (SharedPhoto.tryParse(p) case final photo?) photo,
      ],
      updatedAt: _str(json['updatedAt']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'builtin': builtin,
        'countryCode': countryCode,
        'name': name,
        'colorValue': colorValue,
        'keywords': keywords,
        'photos': photos.map((p) => p.toJson()).toList(),
        'updatedAt': updatedAt,
      };
}

class SharedIndex {
  final int version;
  final String? updatedAt;
  final List<SharedThemeEntry> themes;
  const SharedIndex({this.version = 1, this.updatedAt, this.themes = const []});

  static const empty = SharedIndex();

  factory SharedIndex.fromJson(Object? json) {
    final m = json is Map ? json : const {};
    return SharedIndex(
      version: _int(m['version']) ?? 1,
      updatedAt: _str(m['updatedAt']),
      themes: [
        for (final t in (m['themes'] is List ? m['themes'] as List : const []))
          if (SharedThemeEntry.tryParse(t) case final entry?) entry,
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'updatedAt': updatedAt,
        'themes': themes.map((t) => t.toJson()).toList(),
      };
}
