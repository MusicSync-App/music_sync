import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import '../themes/app_themes.dart';
import '../themes/theme_photos.dart';
import '../themes/user_themes.dart';
import 'google_token_provider.dart' show RemoteServices;
import 'remote_models.dart';
import 'server_api.dart';
import 'shared_themes.dart';
import 'shared_themes_logic.dart';
import 'submission_payload.dart';

/// Pregătește pozele pentru trimitere (micșorare într-un isolate).
Future<List<UploadPhoto>> prepareUploadPhotos(List<File> files) async {
  final out = <UploadPhoto>[];
  for (var i = 0; i < files.length; i++) {
    final bytes = await files[i].readAsBytes();
    final jpg = await Isolate.run(() => compressForUpload(bytes));
    if (jpg != null) out.add(UploadPhoto(jpg, '$i.jpg'));
  }
  return out;
}

/// Utilizatorul trebuie să fie conectat cu Google. Întoarce true dacă e.
Future<bool> _ensureSignedIn(BuildContext context) async {
  final tokens = RemoteServices.api.tokens;
  if (tokens != null && await tokens.accessToken() != null) return true;
  if (!context.mounted) return false;
  final go = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Conectare necesară'),
      content: const Text(
        'Pentru a publica pentru toți trebuie să fii conectat cu contul Google — așa moderatorul '
        'știe cine a trimis tema și poți vedea starea trimiterilor tale.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Anulează')),
        ElevatedButton(onPressed: () => Navigator.pop(d, true), child: const Text('Conectează-te')),
      ],
    ),
  );
  if (go != true) return false;
  return (await tokens?.accessToken(interactive: true)) != null;
}

Future<bool> _confirm(BuildContext context, {required String what, required int photoCount}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Publică pentru toți'),
      content: Text(
        'Se trimite $what${photoCount > 0 ? ' și $photoCount ${photoCount == 1 ? 'poză' : 'poze'} (micșorate la max. 1600 px)' : ''}.\n\n'
        'Trimiterea ajunge întâi la moderare. După aprobare devine disponibilă pentru toți utilizatorii '
        'MusicSync (marcată 🌍). Adresa ta de e-mail Google o vede doar moderatorul.\n\n'
        'Starea o vezi în „Alege tema” → „Trimiterile mele”.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Anulează')),
        ElevatedButton(onPressed: () => Navigator.pop(d, true), child: const Text('Trimite')),
      ],
    ),
  );
  return ok == true;
}

Future<void> _submit(BuildContext context, Map<String, dynamic> meta, List<File> photos) async {
  final error = validateSubmission(meta, photos.length);
  if (error != null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);
  var progressOpen = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Se trimite… (serverul poate porni în până la un minut)')),
          ],
        ),
      ),
    ),
  ).whenComplete(() => progressOpen = false);
  try {
    final upload = await prepareUploadPhotos(photos);
    await RemoteServices.api.submit(meta, upload);
    if (progressOpen) nav.pop();
    messenger.showSnackBar(const SnackBar(content: Text('Trimis la moderare. Mulțumim!')));
  } catch (e) {
    if (progressOpen) nav.pop();
    messenger.showSnackBar(SnackBar(content: Text(errorFromException(e).message)));
  }
}

/// ⋮ al unei țări adăugate -> "Publică pentru toți" (kind=country).
Future<void> publishUserCountry(BuildContext context, UserThemeSpec spec) async {
  if (!await _ensureSignedIn(context) || !context.mounted) return;
  final theme = appThemes[spec.id];
  final photos = theme == null ? <File>[] : ThemePhotos.instance.userPhotosFor(theme);
  final selected = photos.take(kMaxSubmissionPhotos).toList();
  if (!await _confirm(context, what: 'tema „${spec.name}” (culoare, cuvinte-cheie)', photoCount: selected.length) ||
      !context.mounted) {
    return;
  }
  await _submit(
    context,
    countrySubmissionMeta(countryCode: spec.code, name: spec.name, colorValue: spec.accent, keywords: spec.keywords),
    selected,
  );
}

/// Ecranul pozelor unei teme incluse / comune -> "Publică pozele mele" (kind=photos).
Future<void> publishThemePhotos(BuildContext context, CountryTheme theme) async {
  final mine = ThemePhotos.instance.userPhotosFor(theme);
  if (mine.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Adaugă întâi poze proprii la această temă.')));
    return;
  }
  final selected = await showDialog<List<File>>(context: context, builder: (_) => _PhotoSelectDialog(photos: mine));
  if (selected == null || selected.isEmpty || !context.mounted) return;
  if (!await _ensureSignedIn(context) || !context.mounted) return;
  if (!await _confirm(context, what: 'pozele pentru tema „${theme.name}”', photoCount: selected.length) ||
      !context.mounted) {
    return;
  }
  final shared = SharedThemes.instance.entryFor(theme.id);
  await _submit(
    context,
    photosSubmissionMeta(
      themeId: theme.id,
      name: theme.name,
      countryCode: shared?.countryCode ?? kBuiltinThemeCountry[theme.id],
    ),
    selected,
  );
}

/// Poate fi publicată tema (poze)? Temele utilizatorului se publică ca țară.
bool canPublishPhotosFor(CountryTheme theme) => !isUserThemeId(theme.id);

class _PhotoSelectDialog extends StatefulWidget {
  final List<File> photos;
  const _PhotoSelectDialog({required this.photos});

  @override
  State<_PhotoSelectDialog> createState() => _PhotoSelectDialogState();
}

class _PhotoSelectDialogState extends State<_PhotoSelectDialog> {
  late final Set<File> _selected = widget.photos.take(kMaxSubmissionPhotos).toSet();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Alege pozele (max. $kMaxSubmissionPhotos)'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: GridView.count(
          crossAxisCount: 3,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: [
            for (final f in widget.photos)
              GestureDetector(
                onTap: () => setState(() {
                  if (_selected.contains(f)) {
                    _selected.remove(f);
                  } else if (_selected.length < kMaxSubmissionPhotos) {
                    _selected.add(f);
                  }
                }),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(f, fit: BoxFit.cover, cacheWidth: 300)),
                    Positioned(
                      right: 4,
                      top: 4,
                      child: Icon(
                        _selected.contains(f) ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: Colors.white,
                        shadows: const [Shadow(color: Colors.black, blurRadius: 6)],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Anulează')),
        ElevatedButton(
          onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, [for (final f in widget.photos) if (_selected.contains(f)) f]),
          child: Text('Continuă (${_selected.length})'),
        ),
      ],
    );
  }
}

/// "Trimiterile mele" — starea trimiterilor (/api/submissions/mine).
class MySubmissionsScreen extends StatefulWidget {
  const MySubmissionsScreen({super.key});

  @override
  State<MySubmissionsScreen> createState() => _MySubmissionsScreenState();
}

class _MySubmissionsScreenState extends State<MySubmissionsScreen> {
  late Future<List<Submission>> _future = RemoteServices.api.mySubmissions();

  void _reload() => setState(() => _future = RemoteServices.api.mySubmissions());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trimiterile mele'),
        actions: [IconButton(icon: const Icon(Icons.refresh), tooltip: 'Reîncarcă', onPressed: _reload)],
      ),
      body: FutureBuilder<List<Submission>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Se încarcă… (serverul poate porni în până la un minut)'),
              ]),
            );
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(errorFromException(snap.error!).message, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _reload, child: const Text('Reîncearcă')),
                ]),
              ),
            );
          }
          final list = snap.data!;
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nicio trimitere încă.\nPublică o țară adăugată din meniul ⋮ al ei, sau pozele tale din ecranul de poze al unei teme.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = list[i];
              final color = switch (s.status) {
                SubmissionStatus.approved => Colors.green,
                SubmissionStatus.rejected => Colors.redAccent,
                _ => Colors.orange,
              };
              final title = s.kind == 'photos'
                  ? 'Poze pentru ${s.name ?? appThemes[s.themeId]?.name ?? s.themeId ?? '?'}'
                  : 'Țară: ${s.name ?? s.countryCode ?? '?'}';
              final date = s.createdAt?.toLocal();
              return ListTile(
                leading: Icon(
                  switch (s.status) {
                    SubmissionStatus.approved => Icons.check_circle,
                    SubmissionStatus.rejected => Icons.cancel,
                    _ => Icons.hourglass_top,
                  },
                  color: color,
                ),
                title: Text(title),
                subtitle: Text([
                  s.statusLabel,
                  if (date != null) '${date.day}.${date.month}.${date.year}',
                ].join(' · ')),
              );
            },
          );
        },
      ),
    );
  }
}
