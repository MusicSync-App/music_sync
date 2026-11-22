/// Logica pură a sincronizării temelor comune (testabilă fără Flutter).
library;

import 'remote_models.dart';

/// ID-urile temelor incluse în aplicație = cheile din `appThemes`
/// (lib/themes/app_themes.dart): 'grecia', 'armenia', 'iran', 'turcia',
/// 'azerbaidjan', 'kurdistan', 'bosnia', 'central asia'.
/// Acestea sunt ID-urile pe care serverul trebuie să le folosească pentru
/// intrările `builtin: true` din index.json (și `themeId` la kind=photos).
const List<String> kBuiltinThemeIds = [
  'grecia',
  'armenia',
  'iran',
  'turcia',
  'azerbaidjan',
  'kurdistan',
  'bosnia',
  'central asia',
];

/// Toleranță: numele folderelor de poze / variante englezești duc la aceeași temă.
const Map<String, String> kBuiltinThemeAliases = {
  'greece': 'grecia',
  'turkey': 'turcia',
  'azerbaijan': 'azerbaidjan',
  'central_asia': 'central asia',
  'central-asia': 'central asia',
  'centralasia': 'central asia',
};

/// Codul de țară principal al fiecărei teme incluse (pentru trimiteri).
const Map<String, String> kBuiltinThemeCountry = {
  'grecia': 'GR',
  'armenia': 'AM',
  'iran': 'IR',
  'turcia': 'TR',
  'azerbaidjan': 'AZ',
  'bosnia': 'BA',
};

/// ID-ul temei incluse pentru o intrare `builtin`, sau null dacă nu există.
String? resolveBuiltinThemeId(String id, Iterable<String> builtinIds) {
  final ids = builtinIds.toSet();
  if (ids.contains(id)) return id;
  final lower = id.trim().toLowerCase();
  if (ids.contains(lower)) return lower;
  final alias = kBuiltinThemeAliases[lower];
  return (alias != null && ids.contains(alias)) ? alias : null;
}

/// Cum ajunge o intrare din index.json în aplicație.
class ResolvedSharedTheme {
  final SharedThemeEntry entry;

  /// ID-ul temei din aplicație (cheia temei incluse sau ID-ul comun).
  final String appThemeId;

  /// true = doar adaugă poze/cuvinte la tema inclusă [appThemeId].
  final bool mergesIntoBuiltin;

  const ResolvedSharedTheme(this.entry, this.appThemeId, this.mergesIntoBuiltin);
}

/// Intrările valide: `builtin` -> tema inclusă cu acel ID (ignorată dacă nu
/// există); celelalte -> temă nouă, cu excepția ID-urilor care s-ar suprapune
/// peste o temă inclusă sau peste spațiul temelor utilizatorului (`user_`).
List<ResolvedSharedTheme> resolveSharedThemes(SharedIndex index, Iterable<String> builtinIds) {
  final builtins = builtinIds.toSet();
  final out = <ResolvedSharedTheme>[];
  final seen = <String>{};
  for (final e in index.themes) {
    if (e.builtin) {
      final id = resolveBuiltinThemeId(e.id, builtins);
      if (id != null && seen.add('b:$id')) out.add(ResolvedSharedTheme(e, id, true));
    } else {
      if (builtins.contains(e.id) || e.id.startsWith('user_')) continue;
      if (seen.add(e.id)) out.add(ResolvedSharedTheme(e, e.id, false));
    }
  }
  return out;
}

class PhotoSyncPlan {
  /// Pozele care lipsesc local (unice după sha256).
  final List<SharedPhoto> toDownload;

  /// Fișierele locale care nu mai sunt în index (nume de fișier).
  final List<String> toDelete;

  const PhotoSyncPlan(this.toDownload, this.toDelete);

  bool get isEmpty => toDownload.isEmpty && toDelete.isEmpty;
}

/// Ce trebuie descărcat / șters, dat fiind conținutul folderului local
/// (`shared_themes/photos/`, fișiere `<sha256>.jpg`).
PhotoSyncPlan planPhotoSync(SharedIndex index, Iterable<String> localFileNames) {
  final local = localFileNames.toSet();
  final wanted = <String, SharedPhoto>{};
  for (final t in index.themes) {
    for (final p in t.photos) {
      wanted.putIfAbsent(p.localFileName, () => p);
    }
  }
  return PhotoSyncPlan(
    [for (final e in wanted.entries) if (!local.contains(e.key)) e.value],
    [for (final f in local) if (!wanted.containsKey(f)) f]..sort(),
  );
}

/// URL-ul unei poze: baseUrl (fixat pe sha-ul commit-ului) + path.
String photoUrl(ContentInfo content, SharedPhoto photo) {
  final path = photo.path.startsWith('/') ? photo.path.substring(1) : photo.path;
  return '${content.baseUrl}$path';
}
