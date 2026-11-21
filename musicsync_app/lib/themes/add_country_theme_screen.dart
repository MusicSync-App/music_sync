import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../radio/geo.dart' show CountryInfo, CountryLocator;
import 'app_themes.dart';
import 'user_themes.dart';

/// Paleta din care se alege culoarea principală a temei.
const List<Color> kThemeColorPalette = [
  Color(0xFFC62828), // roșu
  Color(0xFFAD1457), // vișiniu
  Color(0xFF6A1B9A), // mov
  Color(0xFF3949AB), // indigo
  Color(0xFF1A5FA8), // albastru
  Color(0xFF0288D1), // azur
  Color(0xFF00897B), // turcoaz
  Color(0xFF2E7D32), // verde
  Color(0xFF7CB342), // verde deschis
  Color(0xFFF9A825), // galben
  Color(0xFFEF6C00), // portocaliu
  Color(0xFF8D6E63), // maro
  Color(0xFFD4890A), // șofran
  Color(0xFF546E7A), // gri-albăstrui
];

/// "Alege tema" -> "Adaugă țară": țara (cu cod ISO, din countries.json),
/// culoarea, pozele și cuvintele pentru detecția automată.
/// Întoarce ID-ul temei salvate.
class AddCountryThemeScreen extends StatefulWidget {
  /// Pentru editarea unei țări adăugate deja.
  final UserThemeSpec? existing;

  const AddCountryThemeScreen({super.key, this.existing});

  @override
  State<AddCountryThemeScreen> createState() => _AddCountryThemeScreenState();
}

class _AddCountryThemeScreenState extends State<AddCountryThemeScreen> {
  CountryInfo? _country;
  late final TextEditingController _nameController = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _keywordsController =
      TextEditingController(text: widget.existing?.keywords.join(', ') ?? '');
  late Color _color = widget.existing?.accentColor ?? kThemeColorPalette[4];
  final List<String> _photos = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) _country = CountryInfo(e.code, e.countryName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _keywordsController.dispose();
    super.dispose();
  }

  Future<void> _pickCountry() async {
    final picked = await showDialog<CountryInfo>(context: context, builder: (_) => const _CountryPickerDialog());
    if (picked == null || !mounted) return;
    setState(() {
      // Numele afișat urmează țara, dacă utilizatorul nu l-a schimbat.
      if (_nameController.text.trim().isEmpty || _nameController.text == _country?.name) {
        _nameController.text = picked.name;
      }
      _country = picked;
    });
  }

  Future<void> _pickPhotos() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: true);
    final paths = result?.files.map((f) => f.path).whereType<String>().toList() ?? [];
    if (paths.isEmpty || !mounted) return;
    setState(() => _photos.addAll(paths.where((p) => !_photos.contains(p))));
  }

  Future<void> _save() async {
    final country = _country;
    if (country == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Alege mai întâi țara.')));
      return;
    }
    final name = _nameController.text.trim().isEmpty ? country.name : _nameController.text.trim();
    setState(() => _saving = true);
    try {
      final spec = UserThemeSpec(
        code: country.code,
        name: name,
        accent: _color.toARGB32(),
        keywords: parseKeywordInput(_keywordsController.text),
        countryName: country.name,
      );
      final theme = await UserThemes.instance.save(spec, photoPaths: _photos);
      if (mounted) Navigator.pop(context, theme.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nu am putut salva tema: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final country = _country;
    final alreadyExists = country != null &&
        widget.existing == null &&
        UserThemes.instance.specFor(themeIdForCountry(country.code)) != null;

    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'Adaugă țară' : 'Editează ${widget.existing!.name}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          const Text('Țara', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            icon: Text(country?.flag ?? '🌍', style: const TextStyle(fontSize: 20)),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(country == null ? 'Alege țara din listă' : '${country.name} (${country.code})'),
            ),
            onPressed: widget.existing == null ? _pickCountry : null,
          ),
          if (alreadyExists)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Țara există deja — salvarea o va actualiza.', style: TextStyle(fontSize: 12, color: Colors.orange)),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Numele afișat (ex. România)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Culoarea principală', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in kThemeColorPalette)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c.toARGB32() == _color.toARGB32() ? Colors.white : Colors.transparent,
                        width: 3,
                      ),
                      boxShadow: c.toARGB32() == _color.toARGB32()
                          ? [BoxShadow(color: c.withValues(alpha: 0.7), blurRadius: 10)]
                          : null,
                    ),
                    child: c.toARGB32() == _color.toARGB32() ? const Icon(Icons.check, color: Colors.white) : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _ThemePreview(color: _color, name: _nameController.text.isEmpty ? (country?.name ?? 'Țara ta') : _nameController.text),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(child: Text('Poze de fundal', style: TextStyle(fontWeight: FontWeight.bold))),
              TextButton.icon(
                icon: const Icon(Icons.add_photo_alternate),
                label: const Text('Alege poze'),
                onPressed: _pickPhotos,
              ),
            ],
          ),
          if (_photos.isEmpty)
            Text(
              widget.existing == null
                  ? 'Opțional — fără poze, tema folosește doar culorile.'
                  : 'Pozele existente rămân; cele alese aici se adaugă.',
              style: const TextStyle(fontSize: 12),
            )
          else
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _photos.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) => Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(File(_photos[i]), width: 96, height: 96, fit: BoxFit.cover),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(backgroundColor: Colors.black54),
                        icon: const Icon(Icons.close, size: 16, color: Colors.white),
                        onPressed: () => setState(() => _photos.removeAt(i)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 20),
          TextField(
            controller: _keywordsController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Cuvinte pentru detecția automată (opțional)',
              hintText: 'ex. manele, românesc, Maria Tănase, Zamfir',
              helperText: 'Separate prin virgulă. Dacă titlul playlistului sau melodiile le conțin, '
                  'tema trece singură pe această țară. Numele țării e inclus automat.',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: _saving
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.check),
        label: const Text('Salvează tema'),
        onPressed: _saving ? null : _save,
      ),
    );
  }
}

class _ThemePreview extends StatelessWidget {
  final Color color;
  final String name;
  const _ThemePreview({required this.color, required this.name});

  @override
  Widget build(BuildContext context) {
    final theme = buildUserTheme(UserThemeSpec(code: 'XX', name: name, accent: color.toARGB32()));
    final energetic = theme.playerMoods[SongMood.energetic]!;
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: theme.scaffoldBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color, width: 2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(name, style: TextStyle(color: theme.textColor, fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          Container(
            width: 64,
            height: 34,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: energetic.gradientColors),
              borderRadius: BorderRadius.circular(17),
            ),
            child: Icon(Icons.play_arrow, color: energetic.textColor),
          ),
        ],
      ),
    );
  }
}

class _CountryPickerDialog extends StatefulWidget {
  const _CountryPickerDialog();

  @override
  State<_CountryPickerDialog> createState() => _CountryPickerDialogState();
}

class _CountryPickerDialogState extends State<_CountryPickerDialog> {
  List<CountryInfo>? _all;
  String _filter = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    CountryLocator.load().then((l) {
      if (mounted) setState(() => _all = l.countries);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = e.toString());
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _filter.trim().toLowerCase();
    final list = (_all ?? const <CountryInfo>[])
        .where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || c.code.toLowerCase() == q)
        .toList();

    return AlertDialog(
      title: const Text('Alege țara'),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 400,
        height: 460,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Caută (în engleză, ex. Romania)',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _error != null
                  ? Text(_error!)
                  : _all == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          itemCount: list.length,
                          itemBuilder: (context, i) {
                            final c = list[i];
                            final added = UserThemes.instance.specFor(themeIdForCountry(c.code)) != null;
                            return ListTile(
                              dense: true,
                              leading: Text(c.flag, style: const TextStyle(fontSize: 22)),
                              title: Text(c.name),
                              subtitle: added ? const Text('adăugată deja') : null,
                              trailing: Text(c.code),
                              onTap: () => Navigator.pop(context, c),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Anulează'))],
    );
  }
}
