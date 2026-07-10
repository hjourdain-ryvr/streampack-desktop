import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models.dart';
import '../job_runner.dart';
import '../ffmpeg.dart';
import '../l10n.dart';
import '../encoder.dart' show nvencAvailable, probeInputColor, probeMediaStreams, defaultOutputName;
import 'job_card.dart';

class EncoderTab extends StatefulWidget {
  const EncoderTab({super.key});
  @override
  State<EncoderTab> createState() => _EncoderTabState();
}

class _EncoderTabState extends State<EncoderTab> {
  final _inputCtrl   = TextEditingController();
  final _outputNameCtrl = TextEditingController();
  final _hlsDirCtrl  = TextEditingController();
  final _dashDirCtrl = TextEditingController();
  // Track which output-dir fields the user set explicitly, so a single entered
  // path can become the default for the other format(s) instead of the app
  // default. _syncingDirs guards programmatic writes from flipping the flags.
  bool _hlsDirUserSet  = false;
  bool _dashDirUserSet = false;
  bool _syncingDirs    = false;
  EncodeFormat  _format  = EncodeFormat.hls;
  EncodeQuality _quality = EncodeQuality.balanced;
  InputColor    _inputColor = InputColor.sdr8;
  VideoOutput   _output     = VideoOutput.h264Sdr;
  final Set<int> _selectedPresets = {1, 2};
  double _segmentDuration = 6;
  bool _ffmpegOk = false, _nvencOk = false;
  int  _srcWidth = 0, _srcHeight = 0;
  List<String> _selectedFiles = []; // empty = use _inputCtrl text
  bool _suppressInputListener = false;

  // Advanced tab (single-file only): probed streams + per-track audio plan.
  MediaStreams? _streams;
  List<AudioSelection> _audioPlan = [];
  int _configTab = 0; // 0 = Basic, 1 = Advanced
  int _advTab = 0;    // 0 = Audio, 1 = Video, 2 = Subtitles

  // Advanced video quality. Applies only once the user engages these controls
  // (_vqTouched); otherwise the Basic preset bitrate ladder is used unchanged.
  VideoQualityMode _vqMode = VideoQualityMode.bitrate;
  int  _vqBitrate4k = kHevcDefaultAnchorKbps;
  int  _vqCrf       = kDefaultCrf;
  VideoEffort _vqEffort = VideoEffort.balanced;
  bool _vqEffortTouched = false;  // false = mirror the Basic quality choice
  bool _vqTouched   = false;

  // Effort shown/used in Advanced: mirrors the Basic quality (Balanced->balanced,
  // Best->best) until the user picks an explicit Advanced effort.
  VideoEffort get _effectiveEffort => _vqEffortTouched
      ? _vqEffort
      : (_quality == EncodeQuality.high ? VideoEffort.best : VideoEffort.balanced);

  bool get _isAvc => _output == VideoOutput.h264Sdr;
  List<int> get _anchorList =>
      _isAvc ? kAvcBitrateAnchorsKbps : kHevcBitrateAnchorsKbps;

  bool _wouldUpscale(int i) => _srcHeight > 0 && kPresets[i].height > _srcHeight;

  String _inputColorLabel(InputColor c) => switch (c) {
    InputColor.sdr8  => 'SDR (8-bit)',
    InputColor.sdr10 => 'SDR (10-bit)',
    InputColor.hdr   => 'HDR (10-bit)',
  };

  // ── Basic config form (the 2.0.0 settings) ────────────────────────────────
  // Basic form is laid out in two columns (see build) so it fits without
  // scrolling in a window that stays within a 1080-logical-pixel screen.
  // Left column: source, output name, format + output directory(ies).
  List<Widget> _basicLeft(AppLocalizations l, Color accent) => [
    _SectionLabel(l.encSource),
    const SizedBox(height: 12),
    _PathField(controller: _inputCtrl, hint: l.encInputHint, label: l.encInputFile,
        onBrowse: _pickInput, browseIcon: Icons.video_file_outlined),
    if (_srcWidth > 0) ...[
      const SizedBox(height: 4),
      Row(children: [
        const Icon(Icons.info_outline, size: 11, color: Color(0xFF9aa3b8)),
        const SizedBox(width: 4),
        Expanded(child: Text(
          _selectedFiles.length > 1
              ? 'Min source: ${_srcWidth}x$_srcHeight'
              : '${l.encSourceSize}: ${_srcWidth}x$_srcHeight',
          style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 10, fontFamily: 'monospace'))),
      ]),
    ],
    const SizedBox(height: 12),
    _PathField(controller: _outputNameCtrl, hint: l.encOutputNameHint, label: l.encOutputName),
    const SizedBox(height: 16),
    _SectionLabel(l.encFormat),
    const SizedBox(height: 12),
    _FormatToggle(value: _format, bothLabel: l.encFormatBoth,
        // DASH dual-ladder (HDR+SDR tone-mapping) is not implemented yet, so
        // dual-ladder modes are HLS-only for now.
        disabled: _output.hasSdrLadder
            ? const {EncodeFormat.dash, EncodeFormat.both} : const {},
        disabledTip: l.encDashUnavailableDual,
        onChanged: (f) => setState(() { _format = f; _syncDirDefaults(); })),
    const SizedBox(height: 16),
    if (_format != EncodeFormat.dash) ...[
      _PathField(controller: _hlsDirCtrl, hint: '/srv/hls/streams',
          label: _format == EncodeFormat.both ? l.encHlsOutputDir : l.encOutputDir,
          onBrowse: _pickHlsDir, browseIcon: Icons.folder_outlined),
      const SizedBox(height: 12),
    ],
    if (_format != EncodeFormat.hls)
      _PathField(controller: _dashDirCtrl, hint: '/srv/dash/streams',
          label: _format == EncodeFormat.both ? l.encDashOutputDir : l.encOutputDir,
          onBrowse: _pickDashDir, browseIcon: Icons.folder_outlined),
  ];

  // Basic form, middle column (Part 2): video output, quality, renditions.
  // Kept in both Basic and Advanced modes so Renditions stay available.
  List<Widget> _basicRight(AppLocalizations l, Color accent) => [
    _SectionLabel(l.encVideoOutput),
    const SizedBox(height: 12),
    _OutputToggle(value: _output, valid: _inputColor.validOutputs,
        onChanged: (o) => setState(() {
          _output = o;
          // Dual-ladder modes are HLS-only for now (no DASH tone-mapping yet);
          // snap the format back to HLS if DASH/Both was selected.
          if (o.hasSdrLadder && _format != EncodeFormat.hls) {
            _format = EncodeFormat.hls;
            _syncDirDefaults();
          }
          // Bitrate anchors differ by codec; snap to the codec default if the
          // current anchor isn't in the new codec's list.
          if (!_anchorList.contains(_vqBitrate4k)) {
            _vqBitrate4k = _isAvc ? kAvcDefaultAnchorKbps : kHevcDefaultAnchorKbps;
          }
        })),
    if (_srcWidth > 0) ...[
      const SizedBox(height: 4),
      Row(children: [
        const Icon(Icons.palette_outlined, size: 11, color: Color(0xFF9aa3b8)),
        const SizedBox(width: 4),
        Text('${l.encDetected}: ${_inputColorLabel(_inputColor)}',
            style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 10, fontFamily: 'monospace')),
      ]),
    ],
    const SizedBox(height: 16),
    _SectionLabel(l.encQuality),
    const SizedBox(height: 12),
    _QualityToggle(value: _quality, balancedLabel: l.encQualityBalanced, highLabel: l.encQualityBest,
        onChanged: (q) => setState(() => _quality = q)),
    const SizedBox(height: 16),
    _SectionLabel(l.encRenditions),
    const SizedBox(height: 12),
    _ResolutionGrid(selected: _selectedPresets, srcWidth: _srcWidth, srcHeight: _srcHeight,
        upscaleTooltipFn: l.upscaleTooltip, upscaleLabel: l.upscaleLabel,
        onToggle: (i) => setState(() {
          if (_wouldUpscale(i)) return;
          _selectedPresets.contains(i) ? _selectedPresets.remove(i) : _selectedPresets.add(i);
        })),
  ];

  // ── Advanced form (per-track audio / video / subtitles) ────────────────────
  // Single-file only; Audio is functional, Subtitles read-only, Video a summary.
  List<Widget> _advancedForm(AppLocalizations l) {
    final s = _streams;
    if (s == null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(l.encAdvancedNeedsFile,
              style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 12, fontStyle: FontStyle.italic)),
        ),
      ];
    }
    return [
      _SubTabToggle(index: _advTab, labels: [l.encAudioTab, l.encVideoTab, l.encSubtitlesTab],
          onChanged: (i) => setState(() => _advTab = i)),
      const SizedBox(height: 12),
      if (_advTab == 0) ..._audioSubTab(s, l),
      if (_advTab == 1) ..._videoSubTab(l),
      if (_advTab == 2) ..._subtitleSubTab(s, l),
    ];
  }

  List<Widget> _audioSubTab(MediaStreams s, AppLocalizations l) {
    if (s.audio.isEmpty) {
      return [Text(l.encNoAudio,
          style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 11))];
    }
    return [
      for (var i = 0; i < s.audio.length && i < _audioPlan.length; i++)
        _audioRow(s.audio[i], i, l),
    ];
  }

  // Friendly source channel-layout label, e.g. "5.1" from "5.1(side)".
  String _chLabel(AudioTrack t) {
    final cl = t.channelLayout;
    if (cl != null && cl.isNotEmpty) {
      return cl.replaceAll('(side)', '').replaceAll('(back)', '').trim();
    }
    return '${t.channels}ch';
  }

  Widget _audioRow(AudioTrack t, int i, AppLocalizations l) {
    final sel = _audioPlan[i];
    final modes = <String, String>{
      'aac': 'AAC', 'ac3': 'AC-3', 'eac3': 'E-AC-3',
      if (t.canPassthrough) 'copy': l.encPassthrough,
      'remove': l.encRemove,
    };
    final cur = sel.action == AudioAction.remove
        ? 'remove'
        : sel.action == AudioAction.passthrough
            ? 'copy'
            : sel.target.name; // aac | ac3 | eac3
    void setMode(String? m) {
      if (m == null) return;
      setState(() {
        if (m == 'remove') { sel.action = AudioAction.remove; sel.isDefault = false; }
        else if (m == 'copy') { sel.action = AudioAction.passthrough; }
        else {
          sel.action = AudioAction.transcode;
          sel.target = AudioTarget.values.firstWhere((e) => e.name == m);
        }
        // Keep exactly one default among the kept tracks (e.g. if the current
        // default was just removed).
        final kept = _audioPlan.where((a) => a.action != AudioAction.remove);
        if (kept.isNotEmpty && !kept.any((a) => a.isDefault)) kept.first.isDefault = true;
      });
    }
    final kept  = sel.action != AudioAction.remove;
    final label = [
      if (t.language != null) t.language!.toUpperCase(),
      t.codecLabel,                              // e.g. "DTS-HD MA" vs "DTS"
      '${t.channels}ch',
      if (t.title != null && t.title!.isNotEmpty) t.title!,
    ].join('  |  ');

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF20252f),
        border: Border.all(color: const Color(0xFF2e3848)),
        borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Info can be long (title, layout); wrap to 2 lines + hover tooltip for
        // the full string.
        Tooltip(message: label, waitDuration: const Duration(milliseconds: 400),
            child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFb8bfcf), fontSize: 11, fontWeight: FontWeight.w600))),
        const SizedBox(height: 6),
        Row(children: [
          SizedBox(width: 150, child: DropdownButton<String>(
            value: cur, isDense: true, isExpanded: true,
            dropdownColor: const Color(0xFF20252f),
            underline: const SizedBox.shrink(),
            style: const TextStyle(color: Color(0xFFb8bfcf), fontSize: 11),
            items: [for (final e in modes.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: setMode,
          )),
          const SizedBox(width: 8),
          if (kept) GestureDetector(
            onTap: () => setState(() {
              for (final a in _audioPlan) { a.isDefault = false; }
              sel.isDefault = true;
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: sel.isDefault ? const Color(0xFF00d4aa) : Colors.transparent,
                border: Border.all(color: const Color(0xFF2e3848)),
                borderRadius: BorderRadius.circular(5)),
              child: Text(l.encDefault, style: TextStyle(
                  color: sel.isDefault ? const Color(0xFF0a0c0f) : const Color(0xFF9aa3b8),
                  fontSize: 10, fontWeight: FontWeight.w700)),
            )),
        ]),
        // Channel choice only matters for multichannel sources: downmix to
        // stereo, or keep the original layout (e.g. 5.1).
        if (sel.action == AudioAction.transcode && t.channels > 2) ...[
          const SizedBox(height: 6),
          _SubTabToggle(
            index: sel.channels == AudioChannelMode.stereo ? 0 : 1,
            labels: ['${l.encStereo} (2.0)', '${l.encKeep} ${_chLabel(t)}'],
            onChanged: (idx) => setState(() => sel.channels =
                idx == 0 ? AudioChannelMode.stereo : AudioChannelMode.source),
          ),
        ],
      ]),
    );
  }

  // Resolutions that will actually be encoded (selected, minus upscales),
  // highest first, for the bitrate ladder preview.
  List<Preset> get _previewResolutions {
    final sel = _selectedPresets.toList()..sort();
    final keep = [for (final i in sel) if (!_wouldUpscale(i)) kPresets[i]];
    final list = keep.isEmpty
        ? [for (final i in sel) kPresets[i]]
        : keep;
    return list..sort((a, b) => b.height.compareTo(a.height));
  }

  Widget _vqRadio(String label, bool selected, VoidCallback onTap, {String? suffix}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Container(
            width: 15, height: 15,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: selected ? const Color(0xFF00d4aa) : const Color(0xFF4a5366),
                  width: 2),
            ),
            child: selected
                ? Center(child: Container(width: 7, height: 7,
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: Color(0xFF00d4aa))))
                : null,
          ),
          const SizedBox(width: 9),
          Text(label, style: TextStyle(
              color: selected ? const Color(0xFFe8ebf0) : const Color(0xFFb8bfcf),
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
          if (suffix != null) ...[
            const SizedBox(width: 6),
            Text(suffix, style: const TextStyle(color: Color(0xFF8a92a6), fontSize: 10)),
          ],
        ]),
      ),
    );
  }

  List<Widget> _videoSubTab(AppLocalizations l) {
    final hdr          = _output.isHdr;   // HDR ladder gets the +15% bump
    final isDual       = _output.hasSdrLadder;
    final anchors      = _anchorList;
    final codecDefault = _isAvc ? kAvcDefaultAnchorKbps : kHevcDefaultAnchorKbps;
    final anchor       = anchors.contains(_vqBitrate4k) ? _vqBitrate4k : codecDefault;
    final resList      = _previewResolutions;
    // Top rung = highest selected resolution (not necessarily 2160p). All
    // displayed values follow it + the HDR bump, and recompute on every rebuild
    // (so they track changes to the selected renditions).
    final topRes       = resList.isEmpty ? kPresets[1] : resList.first;

    String mbps(int kbps) => (kbps / 1000).toStringAsFixed(kbps >= 10000 ? 0 : 1);
    int topKbps(int a) => scaledVideoBitrateKbps(a, topRes.width, topRes.height, hdr: hdr);
    String ladderOf(List<Preset> rl, int anc, bool hdrBump) => [
      for (final r in rl)
        '${r.height}p ${mbps(scaledVideoBitrateKbps(anc, r.width, r.height, hdr: hdrBump))}',
    ].join('  ·  ');

    // Single mode: one ladder. Dual mode: HDR (H.265, +15%) plus the tone-mapped
    // SDR ladder at its own codec tier (H.264 capped at 1080p, mapped anchor).
    final ladder     = ladderOf(resList, anchor, hdr);
    final sdrLadder  = isDual
        ? ladderOf(sdrLadderFor(resList, _output),
                   sdrAnchorKbps(anchor, _output), false)
        : '';
    final sdrCodec   = _output.sdrIsHevc ? 'H.265' : 'H.264';

    return [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(l.encVideoOutput, style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 11)),
        Text(_output.label, style: const TextStyle(color: Color(0xFFb8bfcf), fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 12),
      _SubTabToggle(
        index: _vqMode == VideoQualityMode.bitrate ? 0 : 1,
        labels: [l.encBitrate, l.encCrf],
        onChanged: (i) => setState(() {
          _vqMode = i == 0 ? VideoQualityMode.bitrate : VideoQualityMode.crf;
          _vqTouched = true;
        }),
      ),
      const SizedBox(height: 12),
      if (_vqMode == VideoQualityMode.bitrate) ...[
        Text('${l.encTargetBitrate}  (${topRes.height}p${hdr ? " HDR" : ""})',
            style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 11)),
        const SizedBox(height: 4),
        for (final a in anchors)
          _vqRadio('${mbps(topKbps(a))} Mbps', a == anchor,
              () => setState(() { _vqBitrate4k = a; _vqTouched = true; }),
              suffix: a == codecDefault ? '(${l.encDefaultWord})' : null),
        const SizedBox(height: 8),
        if (isDual) ...[
          Text('${l.encLadderPreview}:', style: const TextStyle(color: Color(0xFF8a92a6), fontSize: 10)),
          const SizedBox(height: 2),
          Text('  HDR (H.265):  $ladder Mbps',
              style: const TextStyle(color: Color(0xFF8a92a6), fontSize: 10, fontFamily: 'monospace')),
          Text('  SDR ($sdrCodec):  $sdrLadder Mbps',
              style: const TextStyle(color: Color(0xFF8a92a6), fontSize: 10, fontFamily: 'monospace')),
        ] else
          Text('${l.encLadderPreview}:  $ladder Mbps',
              style: const TextStyle(color: Color(0xFF8a92a6), fontSize: 10, fontFamily: 'monospace')),
      ] else ...[
        Text('CRF', style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 11)),
        const SizedBox(height: 4),
        for (final c in kCrfTiers)
          _vqRadio('$c', (kCrfTiers.contains(_vqCrf) ? _vqCrf : kDefaultCrf) == c,
              () => setState(() { _vqCrf = c; _vqTouched = true; }),
              suffix: c == kDefaultCrf ? '(${l.encDefaultWord})' : null),
        const SizedBox(height: 8),
        Text(l.encCrfNote,
            style: const TextStyle(color: Color(0xFF8a92a6), fontSize: 10, fontStyle: FontStyle.italic)),
      ],
      const SizedBox(height: 14),
      Text('${l.encQuality}  (NVENC)', style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 11)),
      const SizedBox(height: 4),
      _SubTabToggle(
        index: _effectiveEffort.index,
        labels: [l.encQualityBalanced, l.encQualityHigh, l.encQualityBest],
        onChanged: (i) => setState(() {
          _vqEffort = VideoEffort.values[i];
          _vqEffortTouched = true;
          _vqTouched = true;
        }),
      ),
      const SizedBox(height: 4),
      Text(l.encEffortNote,
          style: const TextStyle(color: Color(0xFF8a92a6), fontSize: 10, fontStyle: FontStyle.italic)),
      if (!_vqTouched) ...[
        const SizedBox(height: 8),
        Text(l.encVideoUntouchedNote,
            style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 10, fontStyle: FontStyle.italic)),
      ],
    ];
  }

  List<Widget> _subtitleSubTab(MediaStreams s, AppLocalizations l) {
    if (s.subtitles.isEmpty) {
      return [Text(l.encNoSubtitles,
          style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 11))];
    }
    return [
      Text(l.encSubtitlesReadonly,
          style: const TextStyle(color: Color(0xFF9aa3b8), fontSize: 10, fontStyle: FontStyle.italic)),
      const SizedBox(height: 6),
      for (final sub in s.subtitles)
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(
            '${(sub.language ?? "und").toUpperCase()}  |  ${sub.codec}${sub.isImageBased ? "  (image)" : ""}',
            style: const TextStyle(color: Color(0xFF8a92a6), fontSize: 10, fontFamily: 'monospace')),
        ),
    ];
  }

  @override
  void initState() {
    super.initState();
    ffmpegAvailable().then((ok) => setState(() => _ffmpegOk = ok));
    nvencAvailable().then((ok) => setState(() => _nvencOk = ok));
    _inputCtrl.addListener(_onInputChanged);
    _hlsDirCtrl.addListener(() {
      if (!_syncingDirs) _hlsDirUserSet = _hlsDirCtrl.text.trim().isNotEmpty;
    });
    _dashDirCtrl.addListener(() {
      if (!_syncingDirs) _dashDirUserSet = _dashDirCtrl.text.trim().isNotEmpty;
    });
    languageNotifier.addListener(_onLang);
  }
  void _onLang() => setState(() {});

  /// Fill any output-dir field the user hasn't set: inherit the other field's
  /// user-entered value if present, otherwise the app default. So a single
  /// entered path becomes the default for the other format(s).
  void _syncDirDefaults() {
    _syncingDirs = true;
    if (!_hlsDirUserSet) {
      _hlsDirCtrl.text = _dashDirUserSet ? _dashDirCtrl.text.trim() : _defaultHlsDir('');
    }
    if (!_dashDirUserSet) {
      _dashDirCtrl.text = _hlsDirUserSet ? _hlsDirCtrl.text.trim() : _defaultDashDir('');
    }
    _syncingDirs = false;
  }

  String _lastProbedPath = '';
  void _onInputChanged() {
    if (_suppressInputListener) return;
    final path = _inputCtrl.text.trim();
    if (path.isEmpty || path == _lastProbedPath) return;
    // User typed manually — clear multi-selection
    if (_selectedFiles.isNotEmpty) setState(() => _selectedFiles = []);
    if (File(path).existsSync()) {
      _lastProbedPath = path;
      if (_outputNameCtrl.text.trim().isEmpty) _outputNameCtrl.text = defaultOutputName(path);
      setState(() { _srcWidth = 0; _srcHeight = 0; });
      _probeDimensions(path);
    }
  }

  @override
  void dispose() {
    languageNotifier.removeListener(_onLang);
    _inputCtrl.removeListener(_onInputChanged);
    _inputCtrl.dispose(); _outputNameCtrl.dispose(); _hlsDirCtrl.dispose(); _dashDirCtrl.dispose();
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
        _outputNameCtrl.text = defaultOutputName(paths.first);
        _syncDirDefaults();
      } else {
        _inputCtrl.text = '${paths.length} files selected';
        _outputNameCtrl.text = '';
      }
      _suppressInputListener = false;
    });
    // Probe all files in parallel, constrain grid to minimum height
    _probeAllDimensions(paths);
    _probeStreams(paths);
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
    _probeStreams([path]);
  }

  /// Probe the colour (bit-depth + HDR) to gate output codecs, and — for a
  /// single file — the full stream layout for the Advanced tab. Mixed/multi
  /// selections fall back to SDR-8 and disable the Advanced tab (per-file audio
  /// selection only makes sense for one file).
  Future<void> _probeStreams(List<String> paths) async {
    final colors = await Future.wait(paths.map(probeInputColor));
    if (!mounted || colors.isEmpty) return;
    final uniform = colors.every((c) => c == colors.first) ? colors.first : InputColor.sdr8;

    MediaStreams? streams;
    var plan = <AudioSelection>[];
    if (paths.length == 1) {
      streams = await probeMediaStreams(paths.first);
      plan = streams.audio.map(AudioSelection.defaultFor).toList();
      // Exactly one default rendition: keep the source's default, else first.
      if (plan.isNotEmpty && !plan.any((a) => a.isDefault)) plan.first.isDefault = true;
      var seenDefault = false;
      for (final a in plan) {
        if (a.isDefault && seenDefault) { a.isDefault = false; }
        else if (a.isDefault) { seenDefault = true; }
      }
    }
    if (!mounted) return;
    setState(() {
      _inputColor = uniform;
      _output     = uniform.defaultOutput;
      _streams    = streams;
      _audioPlan  = plan;
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

    // The per-track audio plan only applies to a single-file selection; for
    // multi-file the plan is left empty (2.0.0 behaviour) since track layouts
    // differ per file.
    final singleFile = inputs.length == 1;
    for (final input in inputs) {
      runner.submit(Job(
        id: DateTime.now().millisecondsSinceEpoch.toRadixString(16).substring(4),
        input: input, hlsOutputDir: hlsDir,
        dashOutputDir: dashDir.isEmpty ? hlsDir : dashDir,
        format: _format, resolutions: res,
        segmentDuration: _segmentDuration.round(), quality: _quality,
        output: _output, inputColor: _inputColor,
        audioPlan: singleFile ? List.of(_audioPlan) : const [],
        videoQuality: (singleFile && _vqTouched)
            ? VideoQuality(mode: _vqMode, bitrate4kKbps: _vqBitrate4k,
                crf: _vqCrf, effort: _effectiveEffort)
            : null,
        // Output name applies to a single file; multi-file jobs each fall back
        // to their own source name.
        outputName: singleFile ? _outputNameCtrl.text.trim() : ''));
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
      SizedBox(width: 730, child: Container(
        decoration: const BoxDecoration(border: Border(right: BorderSide(color: Color(0xFF2e3848)))),
        child: Padding(padding: const EdgeInsets.all(24), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status + Basic/Advanced toggle, spanning the top of Parts 1-2.
            Row(children: [
              _FfmpegStatus(ok: _ffmpegOk),
              if (_ffmpegOk) ...[const SizedBox(width: 12), _NvencStatus(available: _nvencOk)],
            ]),
            const SizedBox(height: 12),
            // Regions 1 (source) and 2 (encoder) side by side, filling the height;
            // the vertical divider runs down to the horizontal divider above
            // Region 3. Each region scrolls on its own (Advanced can be tall).
            Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // Region 1: Basic/Advanced toggle (over Region 1 only), the source/
              // format inputs (or the Advanced form), and Segment duration pinned
              // at the bottom.
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _SubTabToggle(index: _configTab, labels: [l.encBasic, l.encAdvanced],
                    onChanged: (i) => setState(() => _configTab = i)),
                const SizedBox(height: 16),
                Expanded(child: SingleChildScrollView(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _configTab == 0 ? _basicLeft(l, accent) : _advancedForm(l),
                ))),
                const SizedBox(height: 12),
                _SectionLabel(l.encSegmentDuration),
                const SizedBox(height: 2),
                Row(children: [
                  Expanded(child: Slider(value: _segmentDuration, min: 2, max: 12, divisions: 10,
                      activeColor: accent, onChanged: (v) => setState(() => _segmentDuration = v))),
                  SizedBox(width: 36, child: Text('${_segmentDuration.round()}s',
                      style: TextStyle(color: accent, fontFamily: 'monospace', fontSize: 12))),
                ]),
              ])),
              const VerticalDivider(width: 41, thickness: 1, color: Color(0xFF2e3848)),
              // Region 2: video output / quality / renditions (both modes). An
              // invisible toggle reserves the same height so its content starts
              // level with Region 1's content.
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Visibility(visible: false, maintainSize: true, maintainAnimation: true,
                    maintainState: true,
                    child: _SubTabToggle(index: 0, labels: [l.encBasic, l.encAdvanced], onChanged: (_) {})),
                const SizedBox(height: 16),
                Expanded(child: SingleChildScrollView(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _basicRight(l, accent),
                ))),
              ])),
            ])),
            // Region 3: Start Encoding, centered under Regions 1-2.
            const Divider(height: 33, color: Color(0xFF2e3848)),
            Center(child: SizedBox(width: 240, child: ElevatedButton(
                onPressed: () => _submit(runner), child: Text(l.encStartEncoding)))),
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
  final VoidCallback? onBrowse;      // null = no browse button (plain text field)
  final IconData? browseIcon;
  const _PathField({required this.controller, required this.hint, required this.label,
      this.onBrowse, this.browseIcon});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: Color(0xFFb8bfcf), fontSize: 11, fontWeight: FontWeight.w600)),
    const SizedBox(height: 5),
    Row(children: [
      Expanded(child: TextField(controller: controller,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: InputDecoration(hintText: hint))),
      if (onBrowse != null) ...[
        const SizedBox(width: 6),
        SizedBox(height: 44, child: OutlinedButton(
            onPressed: onBrowse,
            style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFb8bfcf),
                side: const BorderSide(color: Color(0xFF4d5870)),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            child: Icon(browseIcon, size: 16))),
      ],
    ]),
  ]);
}

class _FormatToggle extends StatelessWidget {
  final EncodeFormat value;
  final String bothLabel;
  final ValueChanged<EncodeFormat> onChanged;
  final Set<EncodeFormat> disabled;   // greyed out (e.g. DASH for dual-ladder)
  final String disabledTip;
  const _FormatToggle({required this.value, required this.bothLabel,
      required this.onChanged, this.disabled = const {}, this.disabledTip = ''});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF20252f),
          border: Border.all(color: const Color(0xFF2e3848)), borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(3),
      child: Row(children: EncodeFormat.values.map((fmt) {
        final sel = fmt == value;
        final enabled = !disabled.contains(fmt);
        final lbl = switch (fmt) { EncodeFormat.hls => 'HLS', EncodeFormat.dash => 'DASH', EncodeFormat.both => bothLabel };
        final child = AnimatedContainer(duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(color: sel ? const Color(0xFF00d4aa) : Colors.transparent,
                borderRadius: BorderRadius.circular(5)),
            alignment: Alignment.center,
            child: Text(lbl, style: TextStyle(
                color: !enabled ? const Color(0xFF555c6b)
                     : sel ? const Color(0xFF0a0c0f) : const Color(0xFFb8bfcf),
                fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)));
        return Expanded(child: enabled
          ? GestureDetector(onTap: () => onChanged(fmt), child: child)
          : Opacity(opacity: 0.45, child: Tooltip(message: disabledTip, child: child)));
      }).toList()),
    );
  }
}

class _OutputToggle extends StatelessWidget {
  final VideoOutput value;
  final Set<VideoOutput> valid;
  final ValueChanged<VideoOutput> onChanged;
  const _OutputToggle({required this.value, required this.valid, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF20252f),
          border: Border.all(color: const Color(0xFF2e3848)), borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(3),
      child: Row(children: VideoOutput.values.map((o) {
        final sel = o == value;
        final enabled = valid.contains(o);
        final child = AnimatedContainer(duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          decoration: BoxDecoration(color: sel ? const Color(0xFF00d4aa) : Colors.transparent,
              borderRadius: BorderRadius.circular(5)),
          alignment: Alignment.center,
          child: Text(o.toggleLabel, textAlign: TextAlign.center, maxLines: 2,
              softWrap: true, style: TextStyle(
              color: !enabled ? const Color(0xFF555c6b)
                   : sel ? const Color(0xFF0a0c0f) : const Color(0xFFb8bfcf),
              fontSize: 10, height: 1.15, fontWeight: FontWeight.w700, letterSpacing: 0.3)));
        return Expanded(child: enabled
          ? GestureDetector(onTap: () => onChanged(o), child: child)
          : Opacity(opacity: 0.45, child: Tooltip(
              message: o.isHdr ? 'Source is not HDR' : 'Not available for HDR source',
              child: child)));
      }).toList()),
    );
  }
}

/// Generic N-way segmented toggle (used for the Advanced sub-tab selector and
/// the stereo/source channel toggle).
class _SubTabToggle extends StatelessWidget {
  final int index;
  final List<String> labels;
  final ValueChanged<int> onChanged;
  const _SubTabToggle({required this.index, required this.labels, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF20252f),
          border: Border.all(color: const Color(0xFF2e3848)), borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.all(3),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(child: GestureDetector(onTap: () => onChanged(i),
            child: AnimatedContainer(duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(vertical: 7),
              decoration: BoxDecoration(color: i == index ? const Color(0xFF00d4aa) : Colors.transparent,
                  borderRadius: BorderRadius.circular(5)),
              alignment: Alignment.center,
              child: Text(labels[i], overflow: TextOverflow.ellipsis, style: TextStyle(
                  color: i == index ? const Color(0xFF0a0c0f) : const Color(0xFFb8bfcf),
                  fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.3))))),
      ]),
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
