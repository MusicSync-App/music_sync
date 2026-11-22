import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../themes/add_country_theme_screen.dart' show kThemeColorPalette;
import '../themes/app_themes.dart';
import '../themes/theme_photos.dart';
import '../themes/user_themes.dart' show parseKeywordInput;
import 'google_token_provider.dart' show RemoteServices;
import 'remote_models.dart';
import 'server_api.dart';
import 'shared_themes.dart';

/// "Moderare" (doar pentru admini): trimiterile în așteptare și temele comune.
class ModerationScreen extends StatelessWidget {
  const ModerationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Moderare'),
          bottom: const TabBar(tabs: [Tab(text: 'În așteptare'), Tab(text: 'Teme comune')]),
        ),
        body: const TabBarView(children: [_PendingTab(), _SharedThemesTab()]),
      ),
    );
  }
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class _PendingTab extends StatefulWidget {
  const _PendingTab();

  @override
  State<_PendingTab> createState() => _PendingTabState();
}

class _PendingTabState extends State<_PendingTab> {
  late Future<List<Submission>> _future = RemoteServices.api.adminSubmissions();

  void _reload() => setState(() => _future = RemoteServices.api.adminSubmissions());

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        _reload();
        await _future.catchError((_) => <Submission>[]);
      },
      child: FutureBuilder<List<Submission>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return ListView(padding: const EdgeInsets.all(24), children: [
              Text(errorFromException(snap.error!).message, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Center(child: OutlinedButton(onPressed: _reload, child: const Text('Reîncearcă'))),
            ]);
          }
          final list = snap.data!;
          if (list.isEmpty) {
            return ListView(children: const [
              Padding(padding: EdgeInsets.all(32), child: Text('Nicio trimitere în așteptare.', textAlign: TextAlign.center)),
            ]);
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 32),
            itemCount: list.length,
            itemBuilder: (context, i) => _SubmissionCard(key: ValueKey(list[i].id), submission: list[i], onDone: _reload),
          );
        },
      ),
    );
  }
}

class _SubmissionCard extends StatefulWidget {
  final Submission submission;
  final VoidCallback onDone;
  const _SubmissionCard({super.key, required this.submission, required this.onDone});

  @override
  State<_SubmissionCard> createState() => _SubmissionCardState();
}

class _SubmissionCardState extends State<_SubmissionCard> {
  late final TextEditingController _name = TextEditingController(text: widget.submission.name ?? '');
  late final TextEditingController _keywords = TextEditingController(text: widget.submission.keywords.join(', '));
  late int? _color = widget.submission.colorValue;
  bool _busy = false;

  Submission get s => widget.submission;
  bool get _isCountry => s.kind == 'country';

  @override
  void dispose() {
    _name.dispose();
    _keywords.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    setState(() => _busy = true);
    try {
      String? name;
      int? color;
      List<String>? keywords;
      if (_isCountry) {
        final n = _name.text.trim();
        if (n.isNotEmpty && n != s.name) name = n;
        if (_color != null && _color != s.colorValue) color = _color;
        final k = parseKeywordInput(_keywords.text);
        if (k.join('\u0000') != s.keywords.join('\u0000')) keywords = k;
      }
      final revision = await RemoteServices.api.approve(s.id, name: name, colorValue: color, keywords: keywords);
      if (!mounted) return;
      _snack(context, 'Aprobat. Se actualizează temele comune…');
      widget.onDone();
      await SharedThemes.instance.syncAfterAdminChange(revision);
    } catch (e) {
      if (mounted) _snack(context, errorFromException(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Respinge trimiterea'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Motivul (îl vede utilizatorul)', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Anulează')),
          ElevatedButton(onPressed: () => Navigator.pop(d, controller.text.trim()), child: const Text('Respinge')),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await RemoteServices.api.reject(s.id, reason.isEmpty ? 'Fără motiv specificat.' : reason);
      if (!mounted) return;
      _snack(context, 'Respins.');
      widget.onDone();
    } catch (e) {
      if (mounted) _snack(context, errorFromException(e).message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = s.createdAt?.toLocal();
    final target = s.kind == 'photos' ? (appThemes[s.themeId]?.name ?? s.themeId ?? '?') : null;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isCountry ? 'Țară nouă: ${s.name ?? '?'} (${s.countryCode ?? '?'})' : 'Poze pentru „$target” (${s.themeId})',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            Text(
              [s.submitterEmail ?? 'necunoscut', if (date != null) '${date.day}.${date.month}.${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}']
                  .join(' · '),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            if (s.photoUrls.isNotEmpty)
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: s.photoUrls.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (context, i) => _AuthorizedPhoto(url: s.photoUrls[i]),
                ),
              )
            else
              const Text('Fără poze.', style: TextStyle(fontSize: 12)),
            if (_isCountry) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nume', isDense: true, border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keywords,
                decoration: const InputDecoration(
                  labelText: 'Cuvinte-cheie (separate prin virgulă)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in {if (s.colorValue != null) s.colorValue!, ...kThemeColorPalette.map((c) => c.toARGB32())})
                    GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Color(c),
                          shape: BoxShape.circle,
                          border: Border.all(color: c == _color ? Colors.white : Colors.transparent, width: 3),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_busy) const Padding(padding: EdgeInsets.only(right: 12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                TextButton.icon(
                  icon: const Icon(Icons.close, color: Colors.redAccent),
                  label: const Text('Respinge'),
                  onPressed: _busy ? null : _reject,
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Aprobă'),
                  onPressed: _busy ? null : _approve,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Poza unei trimiteri — cerere cu tokenul adminului.
class _AuthorizedPhoto extends StatefulWidget {
  final String url;
  const _AuthorizedPhoto({required this.url});

  @override
  State<_AuthorizedPhoto> createState() => _AuthorizedPhotoState();
}

class _AuthorizedPhotoState extends State<_AuthorizedPhoto> {
  static final Map<String, Uint8List> _cache = {};
  late final Future<Uint8List> _future = _cache.containsKey(widget.url)
      ? Future.value(_cache[widget.url]!)
      : RemoteServices.api.adminPhoto(widget.url).then((b) => _cache[widget.url] = b);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FutureBuilder<Uint8List>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasData) {
              return GestureDetector(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => Dialog(child: InteractiveViewer(child: Image.memory(snap.data!))),
                ),
                child: Image.memory(snap.data!, fit: BoxFit.cover),
              );
            }
            if (snap.hasError) return const ColoredBox(color: Colors.black26, child: Icon(Icons.broken_image));
            return const ColoredBox(color: Colors.black12, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
          },
        ),
      ),
    );
  }
}

class _SharedThemesTab extends StatelessWidget {
  const _SharedThemesTab();

  Future<bool> _confirm(BuildContext context, String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Anulează')),
            ElevatedButton(onPressed: () => Navigator.pop(d, true), child: const Text('Șterge')),
          ],
        ),
      ) ==
      true;

  Future<void> _run(BuildContext context, Future<String?> Function() action) async {
    try {
      final revision = await action();
      if (context.mounted) _snack(context, 'Șters. Se actualizează temele comune…');
      await SharedThemes.instance.syncAfterAdminChange(revision);
    } catch (e) {
      if (context.mounted) _snack(context, errorFromException(e).message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SharedThemes.instance,
      builder: (context, _) {
        final themes = SharedThemes.instance.index.themes;
        return RefreshIndicator(
          onRefresh: () => SharedThemes.instance.sync(force: true).catchError((Object e) {
            if (context.mounted) _snack(context, errorFromException(e).message);
            return false;
          }),
          child: themes.isEmpty
              ? ListView(children: const [
                  Padding(padding: EdgeInsets.all(32), child: Text('Nicio temă comună încă. Trage în jos pentru sincronizare.', textAlign: TextAlign.center)),
                ])
              : ListView.builder(
                  itemCount: themes.length,
                  itemBuilder: (context, i) {
                    final t = themes[i];
                    final theme = appThemes[SharedThemes.instance.all.where((r) => r.entry.id == t.id).firstOrNull?.appThemeId];
                    final files = theme == null ? const [] : ThemePhotos.instance.sharedPhotosFor(theme);
                    return ExpansionTile(
                      leading: Text(SharedThemes.instance.emojiFor(t), style: const TextStyle(fontSize: 22)),
                      title: Text('${t.name} ${t.builtin ? '(poze pentru tema inclusă)' : ''}'),
                      subtitle: Text('${t.id} · ${t.photos.length} poze · ${t.keywords.join(', ')}', maxLines: 2),
                      children: [
                        if (t.photos.isNotEmpty)
                          SizedBox(
                            height: 110,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              children: [
                                for (final ph in t.photos)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: SizedBox(
                                      width: 110,
                                      child: Stack(fit: StackFit.expand, children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: files.where((f) => f.path.endsWith(ph.localFileName)).map<Widget>((f) => Image.file(f, fit: BoxFit.cover, cacheWidth: 300)).firstOrNull ??
                                              const ColoredBox(color: Colors.black26, child: Icon(Icons.image_not_supported)),
                                        ),
                                        Positioned(
                                          right: 0,
                                          top: 0,
                                          child: IconButton(
                                            style: IconButton.styleFrom(backgroundColor: Colors.black54),
                                            icon: const Icon(Icons.delete, color: Colors.white, size: 18),
                                            tooltip: 'Șterge poza',
                                            onPressed: () async {
                                              if (await _confirm(context, 'Ștergi poza?', 'Poza dispare pentru toți utilizatorii.') && context.mounted) {
                                                await _run(context, () => RemoteServices.api.deletePhoto(t.id, ph.sha256));
                                              }
                                            },
                                          ),
                                        ),
                                      ]),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
                            label: Text(t.builtin ? 'Șterge toate pozele comune ale temei' : 'Șterge tema comună'),
                            onPressed: () async {
                              if (await _confirm(context, 'Ștergi „${t.name}”?', 'Tema (și pozele ei) dispare pentru toți utilizatorii.') &&
                                  context.mounted) {
                                await _run(context, () => RemoteServices.api.deleteTheme(t.id));
                              }
                            },
                          ),
                        ),
                      ],
                    );
                  },
                ),
        );
      },
    );
  }
}
