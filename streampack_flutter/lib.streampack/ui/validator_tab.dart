import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../validator.dart';
import '../models.dart';
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
  void dispose() {
    _targetCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m3u8', 'mpd'],
      dialogTitle: 'Select HLS or DASH manifest',
    );
    if (result != null && result.files.single.path != null) {
      setState(() => _targetCtrl.text = result.files.single.path!);
    }
  }

  Future<void> _validate() async {
    final target = _targetCtrl.text.trim();
    if (target.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a file path or URL')));
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
        SnackBar(content: Text('Validation error: $e')));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Left panel — input + history ──────────────────────────
        SizedBox(
          width: 320,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: Color(0xFF252a33))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const _SectionLabel('Target'),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _targetCtrl,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11),
                            decoration: const InputDecoration(
                              hintText: '/srv/hls/streams/movie/movie.m3u8',
                            ),
                            onSubmitted: (_) => _validate(),
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          height: 44,
                          child: OutlinedButton(
                            onPressed: _pickFile,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF8a92a8),
                              side: const BorderSide(color: Color(0xFF2e3440)),
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Icon(Icons.folder_outlined, size: 16),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _validate,
                          child: _loading
                              ? const SizedBox(
                                  height: 16, width: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFF0a0c0f)))
                              : const Text('VALIDATE'),
                        ),
                      ),
                    ],
                  ),
                ),

                // History
                if (_history.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: _SectionLabel('History'),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _history.length,
                      itemBuilder: (_, i) {
                        final entry = _history[i];
                        final name  = entry.target.split(RegExp(r'[/\\]')).last;
                        final color = switch (entry.result.summary) {
                          ValidationSummary.pass => const Color(0xFF00d4aa),
                          ValidationSummary.warn => const Color(0xFFf5c542),
                          ValidationSummary.fail => const Color(0xFFff4f6a),
                        };
                        return ListTile(
                          dense: true,
                          selected: i == _activeIdx,
                          selectedTileColor: accent.withOpacity(0.08),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6)),
                          title: Text(name,
                              style: const TextStyle(
                                  fontSize: 11, fontFamily: 'monospace'),
                              overflow: TextOverflow.ellipsis),
                          trailing: Icon(Icons.circle, color: color, size: 8),
                          onTap: () => setState(() {
                            _activeIdx = i;
                            _targetCtrl.text = entry.target;
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── Right panel — report ───────────────────────────────────
        Expanded(
          child: _activeIdx >= 0
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _history[_activeIdx].target,
                        style: const TextStyle(
                            color: Color(0xFF4a5168),
                            fontSize: 10, fontFamily: 'monospace'),
                      ),
                      const SizedBox(height: 12),
                      ValidationReport(result: _history[_activeIdx].result),
                    ],
                  ),
                )
              : const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.rule_outlined, size: 40,
                          color: Color(0xFF252a33)),
                      SizedBox(height: 12),
                      Text('Enter a path or URL and click Validate',
                          style: TextStyle(
                              color: Color(0xFF4a5168),
                              fontSize: 11, fontFamily: 'monospace')),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: const TextStyle(
        color: Color(0xFF00d4aa),
        fontSize: 9, fontWeight: FontWeight.w600, letterSpacing: 1.5,
        fontFamily: 'monospace'),
  );
}
