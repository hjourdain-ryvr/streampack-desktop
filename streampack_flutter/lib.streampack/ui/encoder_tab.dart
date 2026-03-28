import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models.dart';
import '../job_runner.dart';
import '../ffmpeg.dart';
import '../l10n.dart';
import '../encoder.dart' show sanitiseStem, nvencAvailable;
import 'job_card.dart';

class EncoderTab extends StatefulWidget {
  const EncoderTab({super.key});
  @override
  State<EncoderTab> createState() => _EncoderTabState();
}

class _EncoderTabState extends State<EncoderTab> {
  final _inputCtrl   = TextEditingController();
  final _hlsDirCtrl  = TextEditingController();
  final _dashDirCtrl = TextEditingController();
  EncodeFormat  _format  = EncodeFormat.hls;
  EncodeQuality _quality = EncodeQuality.balanced;
  final Set<int> _selectedPresets = {1, 2};
  double _segmentDuration = 6;
  bool _ffmpegOk = false, _nvencOk = false;
  int  _srcWidth = 0, _srcHeight = 0;
  List<String> _selectedFiles = []; // empty = use _inputCtrl text
  bool _suppressInputListener = false;

  bool _wouldUpscale(int i) => _srcHeight > 0 && kPresets[i].height > _srcHeight;

  @override
  void initState() {
    super.initState();
    ffmpegAvailable().then((ok) => setState(() => _ffmpegOk = ok));
    nvencAvailable().then((ok) => setState(() => _nvencOk = ok));
    _inputCtrl.addListener(_onInputChanged);
    languageNotifier.addListener(_onLang);
  }
  void _onLang() => setState(() {});

  String _lastProbedPath = '';
  void _onInputChanged() {
    if (_suppressInputListener) return;
    final path = _inputCtrl.text.trim();
    if (path.isEmpty || path == _lastProbedPath) return;
    // User typed manually — clear multi-selection
    if (_selectedFiles.isNotEmpty) setState(() => _selectedFiles = []);
    if (File(path).existsSync()) {
      _lastProbedPath = path;
      setState(() { _srcWidth = 0; _srcHeight = 0; });
      _probeDimensions(path);
    }
  }

  @override
  void dispose() {
    languageNotifier.removeListener(_onLang);
    _inputCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose(); _hlsDirCtrl.dispose(); _dashDirCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickInput() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: true,
      dialogTitle: context.l10n.pickInputTitle);
    if (result == null || result.files.isEmpty) return;
    final paths = result.files.map((f) => f.path!).where((p) => p.isNotEmpty).toList();
    if (paths.isEmpty) return;
    setState(() {
      _selectedFiles = paths;
      _srcWidth = 0; _srcHeight = 0;
      _suppressInputListener = true;
      if (paths.length == 1) {
        _inputCtrl.text = paths.first;
        final stem = sanitiseStem(paths.first);
        if (_hlsDirCtrl.text.isEmpty) _hlsDirCtrl.text = _defaultHlsDir(stem);
        if (_dashDirCtrl.text.isEmpty) _dashDirCtrl.text = _defaultDashDir(stem);
      } else {
        _inputCtrl.text = '${paths.length} files selected';
      }
      _suppressInputListener = false;
    });
    // Probe all files in parallel, constrain grid to minimum height
    _probeAllDimensions(paths);
  }

  /// Probes all [paths] in parallel and sets _srcHeight to the minimum
  /// height found, so the rendition grid only shows safe options for
  /// every file in the selection.
  Future<void> _probeAllDimensions(List<String> paths) async {
    final futures = paths.map((p) => _probeSingleDimensions(p));
    final results = await Future.wait(futures);
    final valid = results.where((r) => r != null).cast<({int w, int h})>().toList();
    if (valid.isEmpty) return;
    // Constrain to the smallest source — upscaling any file wastes space
    final minH = valid.map((r) => r.h).reduce((a, b) => a < b ? a : b);
    final minW = valid.firstWhere((r) => r.h == minH).w;
    setState(() {
      _srcWidth  = minW;
      _srcHeight = minH;
      _selectedPresets.removeWhere(_wouldUpscale);
      if (_selectedPresets.isEmpty) {
        for (var i = 0; i < kPresets.length; i++) {
          if (!_wouldUpscale(i)) { _selectedPresets.add(i); break; }
        }
      }
    });
  }

  Future<({int w, int h})?> _probeSingleDimensions(String path) async {
    try {
      final r = await Process.run(ffprobePath(), [
        '-v','error','-select_streams','v:0',
        '-show_entries','stream=width,height','-of','csv=s=x:p=0', path]);
      if (r.exitCode == 0) {
        final parts = (r.stdout as String).trim().split('x');
        if (parts.length == 2) {
          final w = int.tryParse(parts[0]) ?? 0, h = int.tryParse(parts[1]) ?? 0;
          if (w > 0 && h > 0) return (w: w, h: h);
        }
      }
    } catch (e) { debugPrint('[probe] $e'); }
    return null;
  }

  Future<void> _probeDimensions(String path) async {
    final r = await _probeSingleDimensions(path);
    if (r != null) setState(() {
      _srcWidth  = r.w;
      _srcHeight = r.h;
      _selectedPresets.removeWhere(_wouldUpscale);
      if (_selectedPresets.isEmpty) {
        for (var i = 0; i < kPresets.length; i++) {
          if (!_wouldUpscale(i)) { _selectedPresets.add(i); break; }
        }
      }
    });
  }

  Future<void> _pickHlsDir() async {
    final p = await FilePicker.platform.getDirectoryPath(dialogTitle: context.l10n.pickHlsDirTitle);
    if (p != null) setState(() => _hlsDirCtrl.text = p);
  }
  Future<void> _pickDashDir() async {
    final p = await FilePicker.platform.getDirectoryPath(dialogTitle: context.l10n.pickDashDirTitle);
    if (p != null) setState(() => _dashDirCtrl.text = p);
  }

  String _defaultHlsDir(String s) => Platform.isWindows ? 'C:\\srv\\hls\\streams' : '/srv/hls/streams';
  String _defaultDashDir(String s) => Platform.isWindows ? 'C:\\srv\\dash\\streams' : '/srv/dash/streams';

  Future<void> _submit(JobRunner runner) async {
    final l = context.l10n;
    final hlsDir  = _hlsDirCtrl.text.trim();
    final dashDir = _dashDirCtrl.text.trim();
    final res     = _selectedPresets.map((i) => kPresets[i]).toList();

    // Resolve input files — multi-select or single typed path
    final inputs = _selectedFiles.isNotEmpty
        ? _selectedFiles
        : [_inputCtrl.text.trim()];

    if (inputs.isEmpty || inputs.first.isEmpty) return _toast(l.toastEnterInput);
    if ((_format == EncodeFormat.hls  || _format == EncodeFormat.both) && hlsDir.isEmpty) return _toast(l.toastEnterHlsDir);
    if ((_format == EncodeFormat.dash || _format == EncodeFormat.both) && dashDir.isEmpty) return _toast(l.toastEnterDashDir);
    if (res.isEmpty) return _toast(l.toastSelectRes);
    if (!_ffmpegOk)  return _toast(l.toastFfmpegMissing);

    for (final input in inputs) {
      runner.submit(Job(
        id: DateTime.now().millisecondsSinceEpoch.toRadixString(16).substring(4),
        input: input, hlsOutputDir: hlsDir,
        dashOutputDir: dashDir.isEmpty ? hlsDir : dashDir,
        format: _format, resolutions: res,
        segmentDuration: _segmentDuration.round(), quality: _quality));
      // Small delay so IDs don't collide (millisecond-based)
      await Future.delayed(const Duration(milliseconds: 2));
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));

  @override
  Widget build(BuildContext context) {
    final runner = context.watch<JobRunner>();
    final accent = Theme.of(context).colorScheme.primary;
    final l = context.l10n;

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 380, child: Container(
        decoration: const BoxDecoration(border: Border(right: BorderSide(color: Color(0xFF2e3848)))),
        child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _FfmpegStatus(ok: _ffmpegOk),
              if (_ffmpegOk) ...[const SizedBox(width: 12), _NvencStatus(available: _nvencOk)],
            ]),
            const SizedBox(height: 12),
            _SectionLabel(l.encSource),
            const SizedBox(height: 12),
            _PathField(controller: _inputCtrl, hint: l.encInputHint, label: l.encInputFile,
                onBrowse: _pickInput, browseIcon: Icons.video_file_outlined),
            if (_srcWidth > 0) ...[
              const SizedBox(height: 4),
              Row(children: [
                const Icon(Icons.info_outline, size: 11, color: Color(0xFF9aa3b8)),
                const SizedBox(width: 4),
                Text(
                  _selectedFiles.length > 1
                      ? 'Min source: ${_srcWidth}×$_srcHeight — renditions constrained to smallest file'
                      : '${l.encSourceSize}: ${_srcWidth}×$_srcHeight',
                  style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 10, fontFamily: 'monospace')),
              ]),
            ],
            const SizedBox(height: 16),
            _SectionLabel(l.encFormat),
            const SizedBox(height: 12),
            _FormatToggle(value: _format, bothLabel: l.encFormatBoth,
                onChanged: (f) => setState(() => _format = f)),
            const SizedBox(height: 16),
            _SectionLabel(l.encQuality),
            const SizedBox(height: 12),
            _QualityToggle(value: _quality,
                balancedLabel: l.encQualityBalanced, highLabel: l.encQualityHigh,
                onChanged: (q) => setState(() => _quality = q)),
            const SizedBox(height: 16),
            if (_format != EncodeFormat.dash) ...[
              _PathField(controller: _hlsDirCtrl, hint: '/srv/hls/streams',
                  label: _format == EncodeFormat.both ? l.encHlsOutputDir : l.encOutputDir,
                  onBrowse: _pickHlsDir, browseIcon: Icons.folder_outlined),
              const SizedBox(height: 12),
            ],
            if (_format != EncodeFormat.hls) ...[
              _PathField(controller: _dashDirCtrl, hint: '/srv/dash/streams',
                  label: _format == EncodeFormat.both ? l.encDashOutputDir : l.encOutputDir,
                  onBrowse: _pickDashDir, browseIcon: Icons.folder_outlined),
              const SizedBox(height: 16),
            ],
            const Divider(), const SizedBox(height: 12),
            _SectionLabel(l.encRenditions),
            const SizedBox(height: 12),
            _ResolutionGrid(selected: _selectedPresets, srcWidth: _srcWidth, srcHeight: _srcHeight,
                upscaleTooltipFn: l.upscaleTooltip, upscaleLabel: l.upscaleLabel,
                onToggle: (i) => setState(() {
                  if (_wouldUpscale(i)) return;
                  _selectedPresets.contains(i) ? _selectedPresets.remove(i) : _selectedPresets.add(i);
                })),
            const Divider(), const SizedBox(height: 12),
            _SectionLabel(l.encSegmentDuration),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Slider(value: _segmentDuration, min: 2, max: 12, divisions: 10,
                  activeColor: accent, onChanged: (v) => setState(() => _segmentDuration = v))),
              SizedBox(width: 40, child: Text('${_segmentDuration.round()}s',
                  style: TextStyle(color: accent, fontFamily: 'monospace', fontSize: 12))),
            ]),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: ElevatedButton(
                onPressed: () => _submit(runner), child: Text(l.encStartEncoding))),
          ],
        )),
      )),
      Expanded(child: ColoredBox(color: const Color(0xFF0a0c0f), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
            child: Row(children: [
              Text(l.encJobQueue, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFF20252f),
                    border: Border.all(color: const Color(0xFF4d5870)),
                    borderRadius: BorderRadius.circular(999)),
                child: Text('${runner.jobs.length}',
                    style: const TextStyle(color: Color(0xFFb8bfcf), fontSize: 10, fontFamily: 'monospace')),
              ),
              const Spacer(),
              if (runner.jobs.any((j) =>
                  j.status == JobStatus.queued || j.status == JobStatus.running))
                TextButton(
                  onPressed: () => runner.cancelAll(),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l.jobCancelAll,
                      style: const TextStyle(fontSize: 11)),
                ),
            ])),
          Expanded(child: runner.jobs.isEmpty
              ? _EmptyState(icon: Icons.video_library_outlined, message: l.encNoJobs)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  itemCount: runner.jobs.length,
                  itemBuilder: (_, i) => JobCard(job: runner.jobs[i], runner: runner))),
        ],
      ))),
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

class _PathField extends StatelessWidget {
  final TextEditingController controller;
  final String hint, label;
  final VoidCallback onBrowse;
  final IconData browseIcon;
  const _PathField({required this.controller, required this.hint, required this.label,
      required this.onBrowse, required this.browseIcon});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: Color(0xFFb8bfcf), fontSize: 11, fontWeight: FontWeight.w600)),
    const SizedBox(height: 5),
    Row(children: [
      Expanded(child: TextField(controller: controller,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: InputDecoration(hintText: hint))),
      const SizedBox(width: 6),
      SizedBox(height: 44, child: OutlinedButton(
          onPressed: onBrowse,
          style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFb8bfcf),
              side: const BorderSide(color: Color(0xFF4d5870)),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          child: Icon(browseIcon, size: 16))),
    ]),
  ]);
}

class _FormatToggle extends StatelessWidget {
  final EncodeFormat value;
  final String bothLabel;
  final ValueChanged<EncodeFormat> onChanged;
  const _FormatToggle({required this.value, required this.bothLabel, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF20252f),
          border: Border.all(color: const Color(0xFF2e3848)), borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(3),
      child: Row(children: EncodeFormat.values.map((fmt) {
        final sel = fmt == value;
        final lbl = switch (fmt) { EncodeFormat.hls => 'HLS', EncodeFormat.dash => 'DASH', EncodeFormat.both => bothLabel };
        return Expanded(child: GestureDetector(onTap: () => onChanged(fmt),
          child: AnimatedContainer(duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(color: sel ? const Color(0xFF00d4aa) : Colors.transparent,
                borderRadius: BorderRadius.circular(5)),
            alignment: Alignment.center,
            child: Text(lbl, style: TextStyle(color: sel ? const Color(0xFF0a0c0f) : const Color(0xFFb8bfcf),
                fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)))));
      }).toList()),
    );
  }
}

class _QualityToggle extends StatelessWidget {
  final EncodeQuality value;
  final String balancedLabel, highLabel;
  final ValueChanged<EncodeQuality> onChanged;
  const _QualityToggle({required this.value, required this.balancedLabel,
      required this.highLabel, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF20252f),
          border: Border.all(color: const Color(0xFF2e3848)), borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(3),
      child: Row(children: EncodeQuality.values.map((q) {
        final sel = q == value;
        final lbl = q == EncodeQuality.balanced ? balancedLabel : highLabel;
        final tip = q == EncodeQuality.balanced ? 'GPU: p4 · CPU: medium' : 'GPU: p6 · CPU: slow';
        return Expanded(child: Tooltip(message: tip, child: GestureDetector(onTap: () => onChanged(q),
          child: AnimatedContainer(duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(color: sel ? const Color(0xFF00d4aa) : Colors.transparent,
                borderRadius: BorderRadius.circular(5)),
            alignment: Alignment.center,
            child: Text(lbl, style: TextStyle(color: sel ? const Color(0xFF0a0c0f) : const Color(0xFFb8bfcf),
                fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8))))));
      }).toList()),
    );
  }
}

class _ResolutionGrid extends StatelessWidget {
  final Set<int> selected;
  final ValueChanged<int> onToggle;
  final int srcWidth, srcHeight;
  final String Function(int) upscaleTooltipFn;
  final String upscaleLabel;
  const _ResolutionGrid({required this.selected, required this.onToggle,
      required this.srcWidth, required this.srcHeight,
      required this.upscaleTooltipFn, required this.upscaleLabel});

  bool _wouldUpscale(Preset p) => srcHeight > 0 && p.height > srcHeight;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, childAspectRatio: 2.8, crossAxisSpacing: 8, mainAxisSpacing: 8),
      itemCount: kPresets.length,
      itemBuilder: (_, i) {
        final p = kPresets[i], isSel = selected.contains(i), isDis = _wouldUpscale(p);
        final accent = Theme.of(context).colorScheme.primary;
        const dBg = Color(0xFF181d24), dFg = Color(0xFF4d5870);
        return Tooltip(message: isDis ? upscaleTooltipFn(srcHeight) : '',
          child: InkWell(onTap: isDis ? null : () => onToggle(i), borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isDis ? dBg : isSel ? accent.withOpacity(0.1) : const Color(0xFF20252f),
                border: Border.all(color: isDis ? dFg : isSel ? accent : const Color(0xFF4d5870)),
                borderRadius: BorderRadius.circular(8)),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(p.label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                      color: isDis ? dFg : isSel ? accent : const Color(0xFFe8eaf0))),
                  Text(isDis ? '${p.width}×${p.height} $upscaleLabel' : p.videoBitrate,
                      style: TextStyle(fontSize: 9, color: isDis ? dFg : const Color(0xFF9aa3b8), fontFamily: 'monospace')),
                ]),
                if (isSel && !isDis) Icon(Icons.check_circle, color: accent, size: 14),
                if (isDis) Icon(Icons.block, color: dFg, size: 12),
              ]),
            )));
      });
  }
}

class _FfmpegStatus extends StatelessWidget {
  final bool ok;
  const _FfmpegStatus({required this.ok});
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final color = ok ? const Color(0xFF00d4aa) : const Color(0xFFff4f6a);
    return Row(children: [
      Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: color,
          boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 4)])),
      const SizedBox(width: 6),
      Text(ok ? l.statusFfmpegReady : l.statusFfmpegMissing,
          style: TextStyle(color: color, fontSize: 10, fontFamily: 'monospace')),
    ]);
  }
}

class _NvencStatus extends StatelessWidget {
  final bool available;
  const _NvencStatus({required this.available});
  Widget _dot(String label, Color litColor, bool lit) => Row(children: [
    Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle,
        color: lit ? litColor : const Color(0xFF4d5870),
        boxShadow: lit ? [BoxShadow(color: litColor.withOpacity(0.5), blurRadius: 4)] : null)),
    const SizedBox(width: 4),
    Text(label, style: TextStyle(color: lit ? litColor : const Color(0xFF9aa3b8), fontSize: 10, fontFamily: 'monospace')),
  ]);
  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Tooltip(message: available ? l.statusGpuTooltip : l.statusCpuTooltip,
      child: Row(children: [
        _dot('GPU', const Color(0xFF76b900), available),
        const SizedBox(width: 10),
        _dot('CPU', const Color(0xFF00d4aa), !available),
      ]));
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const _EmptyState({required this.icon, required this.message});
  @override
  Widget build(BuildContext context) => Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    Icon(icon, size: 40, color: const Color(0xFF2e3848)),
    const SizedBox(height: 12),
    Text(message, style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 11, fontFamily: 'monospace')),
  ]));
}
