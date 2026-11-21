import 'package:flutter/material.dart';
import 'package:google_sign_in_all_platforms/google_sign_in_all_platforms.dart';

import '../youtube/playlist_save_logic.dart';
import '../youtube/youtube_playlist_service.dart';

/// Butonul "Salvează în playlist" pentru melodia care se aude acum (din
/// metadatele ICY ale postului sau dintr-o recunoaștere). Dezactivat când
/// nu avem un titlu de melodie.
class SaveToPlaylistButton extends StatelessWidget {
  final SongQuery? song;

  /// true = doar iconiță (pentru rânduri înguste).
  final bool compact;

  const SaveToPlaylistButton({super.key, required this.song, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final s = song;
    final onPressed = s == null ? null : () => showSaveToPlaylistSheet(context, song: s);
    if (compact) {
      return IconButton(
        icon: const Icon(Icons.playlist_add),
        tooltip: 'Salvează în playlist',
        onPressed: onPressed,
      );
    }
    return OutlinedButton.icon(
      icon: const Icon(Icons.playlist_add, size: 16),
      label: const Text('Salvează în playlist'),
      onPressed: onPressed,
    );
  }
}

Future<void> showSaveToPlaylistSheet(BuildContext context, {required SongQuery song}) async {
  final messenger = ScaffoldMessenger.of(context);
  final message = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _SaveToPlaylistSheet(song: song),
  );
  if (message != null) messenger.showSnackBar(SnackBar(content: Text(message)));
}

class _SaveToPlaylistSheet extends StatefulWidget {
  final SongQuery song;
  const _SaveToPlaylistSheet({required this.song});

  @override
  State<_SaveToPlaylistSheet> createState() => _SaveToPlaylistSheetState();
}

class _SaveToPlaylistSheetState extends State<_SaveToPlaylistSheet> {
  late final TextEditingController _queryController = TextEditingController(text: widget.song.searchText);
  late SongQuery _query = widget.song;

  bool _offline = false;

  bool _searching = false;
  String? _searchError;
  List<VideoCandidate> _candidates = [];
  String? _videoId;

  bool _checkingAccess = false;
  YouTubeAccess? _access;
  GoogleSignInCredentials? _creds;
  String? _accessError;

  bool _loadingTargets = false;
  String? _targetsError;
  List<PlaylistTarget> _targets = [];
  String? _targetId;

  bool _saving = false;
  String? _info; // ex. "deja în playlist"

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await YouTubePlaylistService.isOnline()) {
      if (mounted) setState(() => _offline = true);
      return;
    }
    if (mounted) setState(() => _offline = false);
    await Future.wait([_search(), _checkAccess()]);
  }

  Future<void> _search() async {
    setState(() {
      _searching = true;
      _searchError = null;
      _info = null;
    });
    try {
      final results = await YouTubePlaylistService.search(_query);
      final ranked = rankCandidates(_query, results, take: 3);
      if (!mounted) return;
      setState(() {
        _candidates = ranked;
        _videoId = ranked.isEmpty ? null : ranked.first.id;
        if (ranked.isEmpty) _searchError = 'Nu am găsit nimic pe YouTube pentru „${_query.searchText}”.';
      });
    } catch (e) {
      if (mounted) setState(() => _searchError = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _searchAgain() {
    final text = _queryController.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    _query = parseNowPlaying(text) ?? SongQuery(artist: '', title: text);
    _search();
  }

  Future<void> _checkAccess({bool interactive = false, bool reauthorize = false}) async {
    setState(() {
      _checkingAccess = true;
      _accessError = null;
    });
    try {
      if (reauthorize) {
        final creds = await YouTubePlaylistService.reauthorize();
        if (creds == null) {
          if (mounted) setState(() => _accessError = 'Conectarea a fost anulată.');
          return;
        }
      }
      final (access, creds) = await YouTubePlaylistService.checkAccess(interactive: interactive);
      if (!mounted) return;
      setState(() {
        _access = access;
        _creds = creds;
      });
      if (access == YouTubeAccess.ok) await _loadTargets();
    } catch (e) {
      if (mounted) setState(() => _accessError = e.toString());
    } finally {
      if (mounted) setState(() => _checkingAccess = false);
    }
  }

  Future<void> _loadTargets() async {
    final cached = await YouTubePlaylistService.cachedTargets();
    if (!mounted) return;
    setState(() {
      if (_targets.isEmpty) _targets = cached;
      _targetId ??= cached.isEmpty ? null : cached.first.id;
      _loadingTargets = true;
      _targetsError = null;
    });
    try {
      final fresh = await YouTubePlaylistService.fetchTargets(YouTubePlaylistService.api(_creds!));
      if (!mounted) return;
      setState(() {
        _targets = fresh;
        if (_targetId == null || !fresh.any((t) => t.id == _targetId)) {
          _targetId = fresh.isEmpty ? null : fresh.first.id;
        }
      });
    } on SaveToPlaylistException catch (e) {
      _handleError(e, (m) => _targetsError = m);
    } finally {
      if (mounted) setState(() => _loadingTargets = false);
    }
  }

  /// Erorile de autorizare duc înapoi la panoul de conectare.
  void _handleError(SaveToPlaylistException e, void Function(String) setMessage) {
    if (!mounted) return;
    setState(() {
      switch (e.kind) {
        case SaveErrorKind.needsConsent:
          _access = YouTubeAccess.needsWriteConsent;
        case SaveErrorKind.expired:
          _access = YouTubeAccess.expired;
        case SaveErrorKind.noInternet:
          _offline = true;
        default:
          setMessage(e.message);
      }
    });
  }

  Future<void> _createPlaylist() async {
    final nameController = TextEditingController(text: 'Descoperiri radio');
    var privacy = 'private';
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Playlist nou pe YouTube'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                maxLength: 150,
                decoration: const InputDecoration(labelText: 'Nume', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'private', icon: Icon(Icons.lock, size: 16), label: Text('Privat')),
                  ButtonSegment(value: 'unlisted', icon: Icon(Icons.link, size: 16), label: Text('Nelistat')),
                  ButtonSegment(value: 'public', icon: Icon(Icons.public, size: 16), label: Text('Public')),
                ],
                selected: {privacy},
                onSelectionChanged: (s) => setDialogState(() => privacy = s.first),
              ),
              const SizedBox(height: 8),
              const Text(
                'Playlistul apare și în Downloader & Sync.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Anulează')),
            ElevatedButton(
              onPressed: () {
                final name = cleanPlaylistName(nameController.text);
                if (name != null) Navigator.pop(dialogContext, (name, privacy));
              },
              child: const Text('Creează'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    if (result == null || !mounted || _creds == null) return;

    setState(() => _saving = true);
    try {
      final target = await YouTubePlaylistService.createPlaylist(
        YouTubePlaylistService.api(_creds!),
        result.$1,
        privacy: result.$2,
      );
      if (!mounted) return;
      setState(() {
        _targets = orderTargets([target, ..._targets], lastUsedId: target.id);
        _targetId = target.id;
        _info = 'Playlistul „${target.title}” a fost creat.';
      });
    } on SaveToPlaylistException catch (e) {
      _handleError(e, (m) => _info = m);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    final videoId = _videoId;
    final target = _targets.where((t) => t.id == _targetId).firstOrNull;
    final creds = _creds;
    if (videoId == null || target == null || creds == null) return;
    setState(() {
      _saving = true;
      _info = null;
    });
    try {
      final api = YouTubePlaylistService.api(creds);
      if (await YouTubePlaylistService.containsVideo(api, target.id, videoId)) {
        if (mounted) setState(() => _info = 'Melodia este deja în „${target.title}”.');
        return;
      }
      await YouTubePlaylistService.addVideo(api, target.id, videoId);
      if (mounted) Navigator.pop(context, '„${_query.display}” a fost adăugată în „${target.title}”.');
    } on SaveToPlaylistException catch (e) {
      _handleError(e, (m) => _info = m);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSave = !_saving && _videoId != null && _targetId != null && _access == YouTubeAccess.ok && !_offline;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (context, controller) => Column(
          children: [
            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                children: [
                  Row(
                    children: [
                      Icon(Icons.playlist_add, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Salvează în playlist', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ),
                      IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                    ],
                  ),
                  if (_offline) _offlineCard() else ...[
                    _sectionTitle('1. Melodia pe YouTube'),
                    _songSection(theme),
                    const SizedBox(height: 12),
                    _sectionTitle('2. Playlist'),
                    _targetSection(theme),
                  ],
                  if (_info != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Card(
                        child: ListTile(leading: const Icon(Icons.info_outline), title: Text(_info!)),
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.check),
                    label: const Text('Salvează'),
                    onPressed: canSave ? _save : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Widget _offlineCard() => Card(
        color: Colors.orange.withValues(alpha: 0.15),
        child: ListTile(
          leading: const Icon(Icons.wifi_off, color: Colors.orange),
          title: const Text('Fără internet'),
          subtitle: const Text('Căutarea pe YouTube și salvarea în playlist au nevoie de conexiune.'),
          trailing: TextButton(onPressed: _start, child: const Text('Reîncearcă')),
        ),
      );

  Widget _songSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _queryController,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _searchAgain(),
          decoration: InputDecoration(
            isDense: true,
            labelText: 'Caută (artist titlu)',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: _searching ? null : _searchAgain),
          ),
        ),
        const SizedBox(height: 8),
        if (_searching)
          const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()))
        else if (_searchError != null)
          Text(_searchError!, style: const TextStyle(color: Colors.redAccent))
        else
          RadioGroup<String>(
            groupValue: _videoId,
            onChanged: (v) => setState(() => _videoId = v),
            child: Column(
              children: [
                for (final c in _candidates)
                  RadioListTile<String>(
                    value: c.id,
                    contentPadding: EdgeInsets.zero,
                    secondary: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        'https://i.ytimg.com/vi/${c.id}/default.jpg',
                        width: 64,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox(width: 64, height: 48, child: Icon(Icons.music_video)),
                      ),
                    ),
                    title: Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [c.author, if (c.duration != null) _formatDuration(c.duration!)].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _targetSection(ThemeData theme) {
    if (_checkingAccess && _access == null) {
      return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()));
    }
    if (_accessError != null && _access != YouTubeAccess.ok) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.error_outline, color: Colors.redAccent),
          title: Text(_accessError!),
          trailing: TextButton(onPressed: _checkAccess, child: const Text('Reîncearcă')),
        ),
      );
    }
    switch (_access) {
      case YouTubeAccess.notSignedIn:
        return _authCard(
          icon: Icons.account_circle,
          title: 'Nu ești conectat la YouTube',
          text: 'Conectează-te cu contul Google ca să salvezi melodii în playlisturile tale.',
          button: 'Conectează-te cu Google',
          onPressed: () => _checkAccess(interactive: true),
        );
      case YouTubeAccess.needsWriteConsent:
        return _authCard(
          icon: Icons.lock_open,
          title: 'Permisiune nouă necesară',
          text: 'Contul tău e conectat doar pentru citire. Ca să adaugi melodii în playlisturi (și să creezi '
              'playlisturi noi), permite o dată accesul „Gestionează contul YouTube” în fereastra Google. '
              'Dacă apare „Google nu a verificat această aplicație”, alege Continuă.',
          button: 'Permite accesul',
          onPressed: () => _checkAccess(reauthorize: true),
        );
      case YouTubeAccess.expired:
        return _authCard(
          icon: Icons.history,
          title: 'Sesiunea Google a expirat',
          text: 'Reconectează-te ca să continui.',
          button: 'Reconectează-te',
          onPressed: () => _checkAccess(reauthorize: true),
        );
      case YouTubeAccess.ok:
      case null:
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loadingTargets) const LinearProgressIndicator(minHeight: 2),
        if (_targetsError != null) Text(_targetsError!, style: const TextStyle(color: Colors.redAccent)),
        if (_targets.isEmpty && !_loadingTargets)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Niciun playlist în Downloader & Sync încă — creează unul nou.'),
          ),
        RadioGroup<String>(
          groupValue: _targetId,
          onChanged: (v) => setState(() {
            _targetId = v;
            _info = null;
          }),
          child: Column(
            children: [
              for (final t in _targets)
                RadioListTile<String>(
                  value: t.id,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${t.itemCount} melodii${t.owned ? '' : ' • adăugat prin link'}'),
                ),
            ],
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.add_circle_outline),
          title: const Text('Playlist nou pe YouTube'),
          subtitle: const Text('Privat implicit'),
          onTap: _saving ? null : _createPlaylist,
        ),
      ],
    );
  }

  Widget _authCard({
    required IconData icon,
    required String title,
    required String text,
    required String button,
    required VoidCallback onPressed,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [Icon(icon), const SizedBox(width: 8), Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)))]),
            const SizedBox(height: 6),
            Text(text, style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            FilledButton(onPressed: _checkingAccess ? null : onPressed, child: Text(button)),
          ],
        ),
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
