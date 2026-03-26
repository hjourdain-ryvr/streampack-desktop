import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models.dart';
import '../job_runner.dart';
import '../ffmpeg.dart';
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

  EncodeFormat _format = EncodeFormat.hls;
  EncodeQuality _quality = EncodeQuality.balanced;
  final Set<int> _selectedPresets = {1, 2}; // 1080p + 720p by default
  double _segmentDuration = 6;

  bool _ffmpegOk  = false;
  bool _nvencOk   = false;
  int  _srcWidth  = 0;   // 0 = unknown (no file selected yet)
  int  _srcHeight = 0;

  /// Returns true if preset [i] would require upscaling the source.
  /// Check is based on height only — height is the canonical streaming
  /// dimension (360p, 720p etc.) and the scale filter handles width
  /// automatically via force_original_aspect_ratio=decrease.
  bool _wouldUpscale(int i) {
    if (_srcHeight == 0) return false;
    return kPresets[i].height > _srcHeight;
  }

  @override
  void initState() {
    super.initState();
    ffmpegAvailable().then((ok) => setState(() => _ffmpegOk = ok));
    nvencAvailable().then((ok) => setState(() => _nvencOk = ok));
    // Probe dimensions when path is typed manually (not just via file picker)
    _inputCtrl.addListener(_onInputChanged);
  }

  String _lastProbedPath = '';

  void _onInputChanged() {
    final path = _inputCtrl.text.trim();
    if (path.isEmpty || path == _lastProbedPath) return;
    if (File(path).existsSync()) {
      _lastProbedPath = path;
      setState(() { _srcWidth = 0; _srcHeight = 0; });
      _probeSourceDimensions(path);
    }
  }

  @override
  void dispose() {
    _inputCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose();
    _hlsDirCtrl.dispose();
    _dashDirCtrl.dispose();
    super.dispose();
  }

  // ── File / directory pickers ─────────────────────────────────────────────

  Future<void> _pickInput() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,  // use video type instead of custom — handles all video extensions including uppercase
      dialogTitle: 'Select input video file',
    );
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      setState(() {
        _inputCtrl.text = path;
        _srcWidth  = 0;
        _srcHeight = 0;
        final stem = sanitiseStem(path);
        if (_hlsDirCtrl.text.isEmpty) _hlsDirCtrl.text = _defaultHlsDir(stem);
        if (_dashDirCtrl.text.isEmpty) _dashDirCtrl.text = _defaultDashDir(stem);
      });
      // Probe source dimensions in the background
      _probeSourceDimensions(path);
    }
  }

  Future<void> _probeSourceDimensions(String path) async {
    try {
      final result = await Process.run(ffprobePath(), [
        '-v', 'error',
        '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height',
        '-of', 'csv=s=x:p=0',
        path,
      ]);
      if (result.exitCode == 0) {
        final out = (result.stdout as String).trim();
        final parts = out.split('x');
        if (parts.length == 2) {
          final w = int.tryParse(parts[0]) ?? 0;
          final h = int.tryParse(parts[1]) ?? 0;
          if (w > 0 && h > 0) {
            setState(() {
              _srcWidth  = w;
              _srcHeight = h;
              _selectedPresets.removeWhere((i) => _wouldUpscale(i));
              if (_selectedPresets.isEmpty) {
                for (var i = 0; i < kPresets.length; i++) {
                  if (!_wouldUpscale(i)) {
                    _selectedPresets.add(i);
                    break;
                  }
                }
              }
            });
          }
        }
      } else {
        // Log probe failure so it's visible in terminal
        debugPrint('[probe] ffprobe failed (${result.exitCode}): '
            '${(result.stderr as String).trim()}');
      }
    } catch (e) {
      debugPrint('[probe] exception: $e');
    }
  }

  Future<void> _pickHlsDir() async {
    final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select HLS output directory');
    if (path != null) setState(() => _hlsDirCtrl.text = path);
  }

  Future<void> _pickDashDir() async {
    final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select DASH output directory');
    if (path != null) setState(() => _dashDirCtrl.text = path);
  }

  String _defaultHlsDir(String stem) {
    return Platform.isWindows
        ? 'C:\\srv\\hls\\streams'
        : '/srv/hls/streams';
  }

  String _defaultDashDir(String stem) {
    return Platform.isWindows
        ? 'C:\\srv\\dash\\streams'
        : '/srv/dash/streams';
  }

  // ── Submit ───────────────────────────────────────────────────────────────

  Future<void> _submit(JobRunner runner) async {
    final input  = _inputCtrl.text.trim();
    final hlsDir = _hlsDirCtrl.text.trim();
    final dashDir = _dashDirCtrl.text.trim();
    final resolutions = _selectedPresets.map((i) => kPresets[i]).toList();

    if (input.isEmpty) return _toast('Enter an input file path');
    if ((_format == EncodeFormat.hls  || _format == EncodeFormat.both) && hlsDir.isEmpty)
      return _toast('Enter an HLS output directory');
    if ((_format == EncodeFormat.dash || _format == EncodeFormat.both) && dashDir.isEmpty)
      return _toast('Enter a DASH output directory');
    if (resolutions.isEmpty) return _toast('Select at least one resolution');
    if (!_ffmpegOk) return _toast('ffmpeg not found — install it first');

    final job = Job(
      id:              DateTime.now().millisecondsSinceEpoch.toRadixString(16).substring(4),
      input:           input,
      hlsOutputDir:    hlsDir,
      dashOutputDir:   dashDir.isEmpty ? hlsDir : dashDir,
      format:          _format,
      resolutions:     resolutions,
      segmentDuration: _segmentDuration.round(),
      quality:         _quality,
    );

    runner.submit(job);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final runner = context.watch<JobRunner>();
    final theme  = Theme.of(context);
    final accent = theme.colorScheme.primary;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Left panel — form ──────────────────────────────────────
        SizedBox(
          width: 380,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: Color(0xFF252a33))),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ffmpeg status
                  // ffmpeg status + NVENC indicator
                  Row(children: [
                    _FfmpegStatus(ok: _ffmpegOk),
                    if (_ffmpegOk) ...[ 
                      const SizedBox(width: 12),
                      _NvencStatus(available: _nvencOk),
                    ],
                  ]),
                  const SizedBox(height: 12),

                  // Input file
                  _SectionLabel('Source'),
                  const SizedBox(height: 12),
                  _PathField(
                    controller: _inputCtrl,
                    hint: '/srv/videos/movie.mp4',
                    label: 'Input file',
                    onBrowse: _pickInput,
                    browseIcon: Icons.video_file_outlined,
                  ),
                  if (_srcWidth > 0) ...[
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.info_outline,
                          size: 11, color: Color(0xFF4a5168)),
                      const SizedBox(width: 4),
                      Text('Source: ${_srcWidth}×$_srcHeight',
                          style: const TextStyle(
                              color: Color(0xFF4a5168),
                              fontSize: 10, fontFamily: 'monospace')),
                    ]),
                  ],
                  const SizedBox(height: 16),

                  // Format toggle
                  _SectionLabel('Format'),
                  const SizedBox(height: 12),
                  _FormatToggle(
                    value: _format,
                    onChanged: (f) => setState(() => _format = f),
                  ),
                  const SizedBox(height: 16),

                  // Quality toggle
                  _SectionLabel('Quality'),
                  const SizedBox(height: 12),
                  _QualityToggle(
                    value: _quality,
                    onChanged: (q) => setState(() => _quality = q),
                  ),
                  const SizedBox(height: 16),

                  // Output dirs
                  if (_format != EncodeFormat.dash) ...[
                    _PathField(
                      controller: _hlsDirCtrl,
                      hint: '/srv/hls/streams',
                      label: _format == EncodeFormat.both
                          ? 'HLS output directory' : 'Output directory',
                      onBrowse: _pickHlsDir,
                      browseIcon: Icons.folder_outlined,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_format != EncodeFormat.hls) ...[
                    _PathField(
                      controller: _dashDirCtrl,
                      hint: '/srv/dash/streams',
                      label: _format == EncodeFormat.both
                          ? 'DASH output directory' : 'Output directory',
                      onBrowse: _pickDashDir,
                      browseIcon: Icons.folder_outlined,
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Renditions
                  const Divider(),
                  const SizedBox(height: 12),
                  _SectionLabel('Renditions'),
                  const SizedBox(height: 12),
                  _ResolutionGrid(
                    selected: _selectedPresets,
                    srcWidth: _srcWidth,
                    srcHeight: _srcHeight,
                    onToggle: (i) => setState(() {
                      if (_wouldUpscale(i)) return; // ignore taps on disabled
                      if (_selectedPresets.contains(i)) {
                        _selectedPresets.remove(i);
                      } else {
                        _selectedPresets.add(i);
                      }
                    }),
                  ),

                  // Segment duration
                  const Divider(),
                  const SizedBox(height: 12),
                  _SectionLabel('Segment Duration'),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: Slider(
                        value: _segmentDuration,
                        min: 2, max: 12, divisions: 10,
                        activeColor: accent,
                        onChanged: (v) => setState(() => _segmentDuration = v),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text('${_segmentDuration.round()}s',
                          style: TextStyle(
                              color: accent,
                              fontFamily: 'monospace',
                              fontSize: 12)),
                    ),
                  ]),
                  const SizedBox(height: 16),

                  // Encode button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => _submit(runner),
                      child: const Text('START ENCODING'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ── Right panel — job queue ────────────────────────────────
        Expanded(
          child: ColoredBox(
            color: const Color(0xFF0a0c0f),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                child: Row(children: [
                  const Text('Job Queue',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF181c22),
                      border: Border.all(color: const Color(0xFF2e3440)),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('${runner.jobs.length}',
                        style: const TextStyle(
                            color: Color(0xFF8a92a8),
                            fontSize: 10, fontFamily: 'monospace')),
                  ),
                ]),
              ),
              Expanded(
                child: runner.jobs.isEmpty
                    ? const _EmptyState(
                        icon: Icons.video_library_outlined,
                        message: 'No jobs yet — configure and encode')
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        itemCount: runner.jobs.length,
                        itemBuilder: (_, i) => JobCard(
                          job: runner.jobs[i],
                          runner: runner,
                        ),
                      ),
              ),
            ],
          ),
          ),  // ColoredBox
        ),
      ],
    );
  }
}

// ── Supporting widgets ────────────────────────────────────────────────────────

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

class _PathField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String label;
  final VoidCallback onBrowse;
  final IconData browseIcon;

  const _PathField({
    required this.controller,
    required this.hint,
    required this.label,
    required this.onBrowse,
    required this.browseIcon,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label,
          style: const TextStyle(
              color: Color(0xFF8a92a8),
              fontSize: 11, fontWeight: FontWeight.w600)),
      const SizedBox(height: 5),
      Row(children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(hintText: hint),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          height: 44,
          child: OutlinedButton(
            onPressed: onBrowse,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF8a92a8),
              side: const BorderSide(color: Color(0xFF2e3440)),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: Icon(browseIcon, size: 16),
          ),
        ),
      ]),
    ],
  );
}

class _FormatToggle extends StatelessWidget {
  final EncodeFormat value;
  final ValueChanged<EncodeFormat> onChanged;
  const _FormatToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF181c22),
        border: Border.all(color: const Color(0xFF252a33)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: EncodeFormat.values.map((fmt) {
          final selected = fmt == value;
          final label = switch (fmt) {
            EncodeFormat.hls  => 'HLS',
            EncodeFormat.dash => 'DASH',
            EncodeFormat.both => 'Both',
          };
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(fmt),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF00d4aa)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                ),
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? const Color(0xFF0a0c0f)
                        : const Color(0xFF8a92a8),
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _QualityToggle extends StatelessWidget {
  final EncodeQuality value;
  final ValueChanged<EncodeQuality> onChanged;
  const _QualityToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF181c22),
        border: Border.all(color: const Color(0xFF252a33)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: EncodeQuality.values.map((q) {
          final selected = q == value;
          final sublabel = switch (q) {
            EncodeQuality.balanced => 'GPU: p4 · CPU: medium',
            EncodeQuality.high     => 'GPU: p6 · CPU: slow',
          };
          return Expanded(
            child: Tooltip(
              message: sublabel,
              child: GestureDetector(
                onTap: () => onChanged(q),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFF00d4aa)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    q.label,
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFF0a0c0f)
                          : const Color(0xFF8a92a8),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ResolutionGrid extends StatelessWidget {
  final Set<int> selected;
  final ValueChanged<int> onToggle;
  final int srcWidth;
  final int srcHeight;
  const _ResolutionGrid({
    required this.selected,
    required this.onToggle,
    required this.srcWidth,
    required this.srcHeight,
  });

  bool _wouldUpscale(Preset p) {
    if (srcHeight == 0) return false;
    return p.height > srcHeight;
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 2.8,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: kPresets.length,
      itemBuilder: (_, i) {
        final preset      = kPresets[i];
        final isSelected  = selected.contains(i);
        final isDisabled  = _wouldUpscale(preset);
        final accent      = Theme.of(context).colorScheme.primary;
        const disabledBg  = Color(0xFF13161b);
        const disabledFg  = Color(0xFF2e3440);

        return Tooltip(
          message: isDisabled
              ? 'Would upscale — source height is ${srcHeight}p'
              : '',
          child: InkWell(
            onTap: isDisabled ? null : () => onToggle(i),
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isDisabled
                    ? disabledBg
                    : isSelected
                        ? accent.withOpacity(0.1)
                        : const Color(0xFF181c22),
                border: Border.all(
                  color: isDisabled
                      ? disabledFg
                      : isSelected
                          ? accent
                          : const Color(0xFF2e3440),
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(preset.label,
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w700,
                              color: isDisabled
                                  ? disabledFg
                                  : isSelected
                                      ? accent
                                      : const Color(0xFFe8eaf0))),
                      Text(
                        isDisabled
                            ? '${preset.width}×${preset.height} — upscale'
                            : preset.videoBitrate,
                        style: TextStyle(
                            fontSize: 9,
                            color: isDisabled
                                ? disabledFg
                                : const Color(0xFF4a5168),
                            fontFamily: 'monospace')),
                    ],
                  ),
                  if (isSelected && !isDisabled)
                    Icon(Icons.check_circle, color: accent, size: 14),
                  if (isDisabled)
                    Icon(Icons.block, color: disabledFg, size: 12),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FfmpegStatus extends StatelessWidget {
  final bool ok;
  const _FfmpegStatus({required this.ok});

  @override
  Widget build(BuildContext context) => Row(children: [
    Container(
      width: 7, height: 7,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ok ? const Color(0xFF00d4aa) : const Color(0xFFff4f6a),
        boxShadow: [BoxShadow(
          color: (ok ? const Color(0xFF00d4aa) : const Color(0xFFff4f6a))
              .withOpacity(0.5),
          blurRadius: 4,
        )],
      ),
    ),
    const SizedBox(width: 6),
    Text(ok ? 'ffmpeg ready' : 'ffmpeg not found',
        style: TextStyle(
            color: ok ? const Color(0xFF00d4aa) : const Color(0xFFff4f6a),
            fontSize: 10, fontFamily: 'monospace')),
  ]);
}

class _NvencStatus extends StatelessWidget {
  final bool available;
  const _NvencStatus({required this.available});

  Widget _indicator(String label, Color litColor, bool lit) => Row(children: [
    Container(
      width: 7, height: 7,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: lit ? litColor : const Color(0xFF2e3440),
        boxShadow: lit ? [BoxShadow(
          color: litColor.withOpacity(0.5),
          blurRadius: 4,
        )] : null,
      ),
    ),
    const SizedBox(width: 4),
    Text(label,
        style: TextStyle(
            color: lit ? litColor : const Color(0xFF4a5168),
            fontSize: 10, fontFamily: 'monospace')),
  ]);

  @override
  Widget build(BuildContext context) => Tooltip(
    message: available
        ? 'NVIDIA GPU detected — encoding with h264_nvenc'
        : 'No NVIDIA GPU — encoding with libx264',
    child: Row(children: [
      _indicator('GPU', const Color(0xFF76b900), available),   // NVIDIA green when active
      const SizedBox(width: 10),
      _indicator('CPU', const Color(0xFF00d4aa), !available),  // teal when active
    ]),
  );
}


class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 40, color: const Color(0xFF252a33)),
        const SizedBox(height: 12),
        Text(message,
            style: const TextStyle(
                color: Color(0xFF4a5168),
                fontSize: 11, fontFamily: 'monospace')),
      ],
    ),
  );
}
