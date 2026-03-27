import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../validator.dart';
import '../models.dart';
import '../l10n.dart';
import 'validation_report.dart';

class ValidatorTab extends StatefulWidget {
  const ValidatorTab({super.key});
  @override
  State<ValidatorTab> createState() => _ValidatorTabState();
}

class _ValidatorTabState extends State<ValidatorTab> {
  final _targetCtrl = TextEditingController();
  bool _loading = false;
  final List<({String target, ValidationResult result})> _history = [];
  int _activeIdx = -1;

  @override
  void initState() {
    super.initState();
    languageNotifier.addListener(_onLang);
  }
  void _onLang() => setState(() {});

  @override
  void dispose() {
    languageNotifier.removeListener(_onLang);
    _targetCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m3u8', 'mpd'],
      dialogTitle: context.l10n.pickManifestTitle,
    );
    if (result?.files.single.path != null)
      setState(() => _targetCtrl.text = result!.files.single.path!);
  }

  Future<void> _validate() async {
    final l = context.l10n;
    final target = _targetCtrl.text.trim();
    if (target.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.valEnterTarget)));
      return;
    }
    setState(() => _loading = true);
    try {
      final result = await validateAuto(target);
      setState(() {
        _history.insert(0, (target: target, result: result));
        _activeIdx = 0;
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.valError(e.toString()))));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final l = context.l10n;

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 320, child: Container(
        decoration: const BoxDecoration(border: Border(right: BorderSide(color: Color(0xFF2e3848)))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.all(24), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionLabel(l.valTarget),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(
                  controller: _targetCtrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  decoration: InputDecoration(hintText: l.valTargetHint),
                  onSubmitted: (_) => _validate(),
                )),
                const SizedBox(width: 6),
                SizedBox(height: 44, child: OutlinedButton(
                  onPressed: _pickFile,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFb8bfcf),
                    side: const BorderSide(color: Color(0xFF4d5870)),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  child: const Icon(Icons.folder_outlined, size: 16))),
              ]),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: _loading ? null : _validate,
                child: _loading
                    ? const SizedBox(height: 16, width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0a0c0f)))
                    : Text(l.valValidate),
              )),
            ],
          )),
          if (_history.isNotEmpty) ...[
            Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: _SectionLabel(l.valHistory)),
            Expanded(child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _history.length,
              itemBuilder: (_, i) {
                final entry = _history[i];
                final name = entry.target.split(RegExp(r'[/\\]')).last;
                final color = switch (entry.result.summary) {
                  ValidationSummary.pass => const Color(0xFF00d4aa),
                  ValidationSummary.warn => const Color(0xFFf5c542),
                  ValidationSummary.fail => const Color(0xFFff4f6a),
                };
                return ListTile(
                  dense: true,
                  selected: i == _activeIdx,
                  selectedTileColor: accent.withOpacity(0.08),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  title: Text(name, style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis),
                  trailing: Icon(Icons.circle, color: color, size: 8),
                  onTap: () => setState(() { _activeIdx = i; _targetCtrl.text = entry.target; }),
                );
              },
            )),
          ],
        ]),
      )),
      Expanded(child: _activeIdx >= 0
          ? SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_history[_activeIdx].target,
                    style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 10, fontFamily: 'monospace')),
                const SizedBox(height: 12),
                ValidationReport(result: _history[_activeIdx].result),
              ]))
          : Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.rule_outlined, size: 40, color: Color(0xFF2e3848)),
              const SizedBox(height: 12),
              Text(l.valEmptyPrompt,
                  style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 11, fontFamily: 'monospace')),
            ]))),
    ]);
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: const TextStyle(color: Color(0xFF00d4aa), fontSize: 9,
          fontWeight: FontWeight.w600, letterSpacing: 1.5, fontFamily: 'monospace'));
}
