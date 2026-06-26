import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:convert';
import 'package:xml/xml.dart';
import 'models.dart';
import 'ffmpeg.dart';
// ── Stem sanitisation ─────────────────────────────────────────────────────────

/// Return a safe filename stem from an input path.
/// Rules applied in order:
///   1. Spaces → underscores
///   2. Strip unsafe URI characters (keep word chars and hyphens)
///   3. Collapse multiple underscores → single underscore
///   4. Clean up _-_, _-, -_ patterns → single hyphen
///   5. Collapse underscores again (in case step 4 produced new sequences)
///   6. Strip leading/trailing underscores and hyphens
String sanitiseStem(String inputPath) {
  var stem = File(inputPath).uri.pathSegments.last;
  // Strip extension
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  // Spaces → underscore
  stem = stem.replaceAll(RegExp(r'\s+'), '_');
  // Keep only word chars and hyphens
  stem = stem.replaceAll(RegExp(r'[^\w\-]'), '');
  // Collapse multiple underscores first
  stem = stem.replaceAll(RegExp(r'_+'), '_');
  // Clean up underscore-hyphen combinations → single hyphen
  stem = stem.replaceAll(RegExp(r'_-_'), '-');
  stem = stem.replaceAll(RegExp(r'_-(?!_)'), '-');
  stem = stem.replaceAll(RegExp(r'(?<!_)-_'), '-');
  // Collapse underscores again
  stem = stem.replaceAll(RegExp(r'_+'), '_');
  // Strip leading/trailing underscores or hyphens
  stem = stem.replaceAll(RegExp(r'^[_\-]+|[_\-]+$'), '');
  return stem.isEmpty ? 'output' : stem;
}

// ── NVIDIA NVENC detection ────────────────────────────────────────────────────

/// Cached result of NVENC availability check.
/// null = not yet checked, true = available, false = not available.
bool? _nvencAvailable;

/// Check whether h264_nvenc is available at runtime.
/// Uses a 1-frame encode from the color filter source.
/// nullsrc produces wrapped_avframe which requires a decoder not in our
/// minimal build — color filter outputs raw frames directly.
/// Result is cached — only probed once per session.
Future<bool> nvencAvailable() async {
  if (_nvencAvailable != null) return _nvencAvailable!;
  try {
    final result = await Process.run(ffmpegPath(), [
      '-f', 'lavfi', '-i', 'nullsrc=s=256x256:d=0.04:r=1',
      '-frames:v', '1',
      '-c:v', 'h264_nvenc',
      '-f', 'null', '-',
    ]).timeout(const Duration(seconds: 8));
    _nvencAvailable = result.exitCode == 0;
    if (!_nvencAvailable!) {
      // Log reason for debugging
      debugPrint('[nvenc] detection failed: ${(result.stderr as String).trim().split('\n').last}');
    }
  } catch (e) {
    _nvencAvailable = false;
    debugPrint('[nvenc] detection exception: $e');
  }
  debugPrint('[nvenc] available: $_nvencAvailable');
  return _nvencAvailable!;
}

/// Returns the best available video encoder: h264_nvenc if NVIDIA GPU is
/// present and NVENC is supported, otherwise libx264.
/// [nvenc] should be the cached result from nvencAvailable().
String _videoEncoder(bool nvenc) => nvenc ? 'h264_nvenc' : 'libx264';

// ── Source colour / HDR probing ───────────────────────────────────────────────

/// Probe a source file's colour characteristics (bit-depth + HDR) so the UI can
/// gate which output codecs are valid. Returns [InputColor.sdr8] on any failure.
Future<InputColor> probeInputColor(String input) async {
  try {
    final res = await Process.run(ffprobePath(), [
      '-v', 'error', '-select_streams', 'v:0',
      '-show_entries', 'stream=pix_fmt,color_transfer',
      '-of', 'json', input,
    ]).timeout(const Duration(seconds: 10));
    if (res.exitCode != 0) return InputColor.sdr8;
    final data = jsonDecode(res.stdout as String) as Map<String, dynamic>;
    final streams = (data['streams'] as List?) ?? const [];
    if (streams.isEmpty) return InputColor.sdr8;
    final s = streams.first as Map<String, dynamic>;
    return InputColor.classify(
      pixFmt: s['pix_fmt'] as String?,
      colorTransfer: s['color_transfer'] as String?,
    );
  } catch (_) {
    return InputColor.sdr8;
  }
}

/// Extract HDR10 static metadata (mastering display + content light level) from
/// the first frame, formatted for libx265's -x265-params. Returns null if absent.
Future<HdrMetadata?> probeHdrMetadata(String input) async {
  try {
    final res = await Process.run(ffprobePath(), [
      '-v', 'error', '-select_streams', 'v:0',
      '-read_intervals', '%+#1',
      '-show_frames',
      '-show_entries',
      'frame_side_data=side_data_type,red_x,red_y,green_x,green_y,'
          'blue_x,blue_y,white_point_x,white_point_y,'
          'min_luminance,max_luminance,max_content,max_average',
      '-of', 'json', input,
    ]).timeout(const Duration(seconds: 15));
    if (res.exitCode != 0) return null;
    final data = jsonDecode(res.stdout as String) as Map<String, dynamic>;
    final frames = (data['frames'] as List?) ?? const [];

    // Numerator of an "X/Y" rational (libx265 wants the integer numerators).
    int numer(Map sd, String key) {
      final v = sd[key]?.toString() ?? '';
      final slash = v.indexOf('/');
      return int.tryParse(slash >= 0 ? v.substring(0, slash) : v) ?? 0;
    }

    String? masterDisplay, maxCll;
    for (final f in frames) {
      for (final sd in (f['side_data_list'] as List?) ?? const []) {
        final type = (sd['side_data_type'] ?? '').toString();
        if (type == 'Mastering display metadata') {
          masterDisplay =
              'G(${numer(sd, 'green_x')},${numer(sd, 'green_y')})'
              'B(${numer(sd, 'blue_x')},${numer(sd, 'blue_y')})'
              'R(${numer(sd, 'red_x')},${numer(sd, 'red_y')})'
              'WP(${numer(sd, 'white_point_x')},${numer(sd, 'white_point_y')})'
              'L(${numer(sd, 'max_luminance')},${numer(sd, 'min_luminance')})';
        } else if (type == 'Content light level metadata') {
          maxCll = '${numer(sd, 'max_content')},${numer(sd, 'max_average')}';
        }
      }
    }
    if (masterDisplay == null && maxCll == null) return null;
    return HdrMetadata(masterDisplay: masterDisplay, maxCll: maxCll);
  } catch (_) {
    return null;
  }
}

/// Concrete output characteristics derived from the chosen [VideoOutput] and
/// the probed [InputColor]. H.264 is always 8-bit; H.265 preserves the input's
/// bit-depth (and HDR signal for H.265 HDR).
class _OutSpec {
  final bool hevc;
  final bool tenBit;
  final bool hdr;
  const _OutSpec(this.hevc, this.tenBit, this.hdr);

  factory _OutSpec.from(VideoOutput out, InputColor input) {
    final hevc = out.isHevc;
    final hdr  = out.isHdr;
    // H.264 → always 8-bit (10-bit SDR reduced 10→8). H.265 → keep input depth.
    final tenBit = hdr || (hevc && input.is10bit);
    return _OutSpec(hevc, tenBit, hdr);
  }

  /// Software pixel format for CPU-frame paths (libx264/libx265 and CPU-frame nvenc).
  String get cpuPixFmt  => tenBit ? 'yuv420p10le' : 'yuv420p';
  /// scale_cuda output format for GPU-frame paths.
  String get cudaPixFmt => tenBit ? 'p010le' : 'yuv420p';
}

/// Per-rendition video encoder flags for the chosen codec/range.
/// - h264_nvenc / hevc_nvenc on GPU; libx264 / libx265 on CPU.
/// - [gpuFrames] true when frames are already in CUDA memory (DASH NVENC path),
///   where scale_cuda sets the pixel format; otherwise we set -pix_fmt here so
///   10-bit is preserved and 10-bit-SDR→H.264 is reduced 10→8.
List<String> _videoEncoderArgs(int i, Preset r, _OutSpec spec,
    {required bool nvenc, required bool gpuFrames,
     required EncodeQuality quality, HdrMetadata? hdr}) {
  final br     = r.videoBitrate;
  final brVal  = int.tryParse(br.replaceAll(RegExp(r'[^\d]'), '')) ?? 5000;
  final unit   = br.replaceAll(RegExp(r'[\d]'), '');
  final bufsize = '${brVal * 2}$unit';

  if (nvenc) {
    final codec   = spec.hevc ? 'hevc_nvenc' : 'h264_nvenc';
    final profile = spec.hevc ? (spec.tenBit ? 'main10' : 'main') : 'high';
    return [
      '-c:v:$i', codec,
      '-preset:v:$i', quality.nvencPreset,
      '-tune:v:$i', 'hq',
      '-profile:v:$i', profile,
      '-rc:v:$i', 'vbr',
      '-b:v:$i', br,
      '-maxrate:v:$i', br,
      '-bufsize:v:$i', bufsize,
      if (!gpuFrames) ...['-pix_fmt:v:$i', spec.cpuPixFmt],
      if (spec.hdr) ...[
        '-colorspace:v:$i', 'bt2020nc',
        '-color_primaries:v:$i', 'bt2020',
        '-color_trc:v:$i', 'smpte2084',
        '-color_range:v:$i', 'tv',
      ],
    ];
  }

  if (spec.hevc) {
    final params = <String>['log-level=error'];
    if (spec.hdr) {
      params.addAll(['colorprim=bt2020', 'transfer=smpte2084',
                     'colormatrix=bt2020nc', 'hdr10=1', 'repeat-headers=1']);
      if (hdr?.masterDisplay != null) params.add('master-display=${hdr!.masterDisplay}');
      if (hdr?.maxCll != null)        params.add('max-cll=${hdr!.maxCll}');
    }
    return [
      '-c:v:$i', 'libx265',
      '-preset:v:$i', quality.x264Preset,
      '-pix_fmt:v:$i', spec.cpuPixFmt,
      '-x265-params:v:$i', params.join(':'),
      '-b:v:$i', br,
    ];
  }

  return [
    '-c:v:$i', 'libx264',
    '-preset:v:$i', quality.x264Preset,
    '-pix_fmt:v:$i', 'yuv420p',
    '-b:v:$i', br,
  ];
}



List<String> _filterComplexArgs(List<Preset> resolutions) {
  final n = resolutions.length;
  final splits = List.generate(n, (i) => '[v$i]').join('');
  final splitFilter = '[0:v]split=$n$splits';
  final scaleFilters = [
    for (var i = 0; i < n; i++) _scaleFilterFromSplit(i, resolutions[i]),
  ];
  return ['-filter_complex', '$splitFilter;${scaleFilters.join(';')}'];
}

/// Build a scale filter for a single output rendition.
/// Input is already cropped to exact 16:9 aspect ratio by the time
/// this filter runs, so no padding needed — just scale down.
/// force_divisible_by=2 ensures libx264 compatibility.
String _scaleFilter(int i, Preset r) {
  return '[cropped]scale=${r.width}:${r.height}'
      ':force_original_aspect_ratio=decrease'
      ':force_divisible_by=2'
      '[scaled$i]';
}

/// For DASH: a split-only filter (no crop prefix, input already cropped).
String _scaleFilterFromSplit(int i, Preset r) {
  return '[v$i]scale=${r.width}:${r.height}'
      ':force_original_aspect_ratio=decrease'
      ':force_divisible_by=2'
      '[scaled$i]';
}

List<String> _streamArgs(List<Preset> resolutions, _OutSpec spec,
    {required bool nvenc, required EncodeQuality quality, HdrMetadata? hdr}) {
  final args = <String>[];
  for (var i = 0; i < resolutions.length; i++) {
    final r = resolutions[i];
    args.addAll([
      '-map', '[scaled$i]', '-map', '0:a:0?',
      ..._videoEncoderArgs(i, r, spec,
          nvenc: nvenc, gpuFrames: false, quality: quality, hdr: hdr),
      '-c:a:$i', 'aac', '-b:a:$i', r.audioBitrate,
      '-ac:$i', '2',
      '-ar:$i', '44100',
    ]);
  }
  return args;
}

// ── HLS ───────────────────────────────────────────────────────────────────────

/// Build the ffmpeg command for HLS encoding.
/// Everything is written into <outputDir>/<stem>/ first;
/// [promoteHlsMaster] moves the master playlist up afterwards.
List<String> buildHlsCmd({
  required String input,
  required String outputDir,
  required List<Preset> resolutions,
  required int segmentDuration,
  required bool nvenc,
  required EncodeQuality quality,
  required VideoOutput output,
  required InputColor inputColor,
  HdrMetadata? hdrMeta,
}) {
  final stem   = sanitiseStem(input);
  // Use forward slashes for all HLS output paths. ffmpeg derives the fMP4
  // init-segment directory by scanning the output path for '/', so on Windows
  // backslash paths it finds none, and the per-variant init segments are not
  // written into segDir (they vanish / land in the CWD) — breaking playback and
  // validation. Windows accepts '/' fine, so this works on both platforms.
  final segDir = '$outputDir/$stem'.replaceAll('\\', '/');
  final spec   = _OutSpec.from(output, inputColor);

  // HEVC in HLS must use fMP4 segments (HEVC-in-MPEG-TS is not valid HLS).
  final segArgs = spec.hevc
      ? <String>[
          '-hls_segment_type', 'fmp4',
          '-hls_fmp4_init_filename', '${stem}_%v_init.mp4',
          '-hls_segment_filename', '$segDir/${stem}_%v_%03d.m4s',
        ]
      : <String>[
          '-hls_segment_type', 'mpegts',
          '-hls_segment_filename', '$segDir/${stem}_%v_%03d.ts',
        ];

  return [
    ffmpegPath(), '-y', '-i', input,
    '-sn', '-dn',
    ..._filterComplexArgs(resolutions),
    ..._streamArgs(resolutions, spec, nvenc: nvenc, quality: quality, hdr: hdrMeta),
    '-f', 'hls',
    '-hls_time', '$segmentDuration',
    '-hls_playlist_type', 'vod',
    '-hls_flags', 'independent_segments',
    ...segArgs,
    '-master_pl_name', 'master.m3u8',
    '-var_stream_map',
    resolutions.map((r) => 'v:${resolutions.indexOf(r)},a:${resolutions.indexOf(r)},name:${r.height}p').join(' '),
    '$segDir/${stem}_%v.m3u8',
  ];
}

/// Move master.m3u8 from <segDir> to <outputDir>/<stem>.m3u8 and rewrite
/// variant URIs to include the stem subdirectory prefix.
Future<void> promoteHlsMaster({
  required String input,
  required String outputDir,
}) async {
  final stem      = sanitiseStem(input);
  final sep       = Platform.pathSeparator;
  final segDir    = '$outputDir$sep$stem';
  final srcMaster = File('$segDir${sep}master.m3u8');
  final dstMaster = File('$outputDir$sep$stem.m3u8');

  final lines = await srcMaster.readAsLines();

  // Rewrite variant URIs to include the stem subdirectory prefix,
  // then sort variant blocks by BANDWIDTH ascending (HLS spec SHOULD).
  // Each variant block = one #EXT-X-STREAM-INF line + one URI line.
  final header  = <String>[];   // lines before first variant
  final variants = <({String inf, String uri})>[];
  String? pendingInf;
  bool inVariants = false;

  for (final line in lines) {
    final t = line.trim();
    if (t.startsWith('#EXT-X-STREAM-INF')) {
      inVariants = true;
      pendingInf = line;
    } else if (pendingInf != null) {
      final uri = t.isNotEmpty && !t.startsWith('#') && t.endsWith('.m3u8')
          ? '$stem/$t'
          : t;
      variants.add((inf: pendingInf!, uri: uri));
      pendingInf = null;
    } else if (!inVariants) {
      header.add(line);
    }
  }

  // Sort by BANDWIDTH= value ascending
  variants.sort((a, b) {
    final bwA = RegExp(r'BANDWIDTH=(\d+)').firstMatch(a.inf)?.group(1);
    final bwB = RegExp(r'BANDWIDTH=(\d+)').firstMatch(b.inf)?.group(1);
    final ia  = int.tryParse(bwA ?? '') ?? 0;
    final ib  = int.tryParse(bwB ?? '') ?? 0;
    return ia.compareTo(ib);
  });

  final output = [
    ...header,
    for (final v in variants) ...[v.inf, v.uri],
    '',
  ];

  await dstMaster.writeAsString(output.join('\n'));
  await srcMaster.delete();
}

// ── DASH ──────────────────────────────────────────────────────────────────────

/// Build the ffmpeg command for DASH encoding.
///
/// Stream index layout after mapping:
///   0 .. n-1  = video streams (one per resolution, from filter graph)
///   n         = audio stream  (single shared stream from input)
///
/// -adaptation_sets uses absolute output stream indices.
/// v:/a: prefixed selectors only work without a filter graph.
List<String> buildDashCmd({
  required String input,
  required String outputDir,
  required List<Preset> resolutions,
  required int segmentDuration,
  required bool nvenc,
  required EncodeQuality quality,
  required VideoOutput output,
  required InputColor inputColor,
  HdrMetadata? hdrMeta,
}) {
  final stem   = sanitiseStem(input);
  final segDir = '$outputDir${Platform.pathSeparator}$stem';
  final n      = resolutions.length;
  final spec   = _OutSpec.from(output, inputColor);

  const repId = r'$RepresentationID$';
  const num   = r'$Number$';

  final List<String> cmd;

  if (nvenc) {
    // ── NVENC path: per-stream mapping with scale_cuda + setsar ──────────────
    // Uses -map 0:v:0 per output stream with -filter:v:N per stream.
    // scale_cuda requires named w=/h= syntax, not positional.
    // setsar=1 normalises SAR so DASH muxer sees identical aspect ratios.
    final maps    = <String>[];
    final filters = <String>[];
    final encArgs = <String>[];

    for (var i = 0; i < n; i++) {
      maps.addAll(['-map', '0:v:0', '-map', '0:a:0?']);
      filters.addAll(['-filter:v:$i',
          'scale_cuda=${resolutions[i].width}:${resolutions[i].height}:format=${spec.cudaPixFmt},setsar=1']);
      encArgs.addAll(_videoEncoderArgs(i, resolutions[i], spec,
          nvenc: true, gpuFrames: true, quality: quality, hdr: hdrMeta));
      encArgs.addAll([
        '-c:a:$i', 'aac',
        '-b:a:$i', resolutions[i].audioBitrate,
        '-ac:$i', '2',
        '-ar:$i', '44100',
      ]);
    }

    cmd = [
      ffmpegPath(), '-y',
      '-hwaccel', 'cuda',
      '-hwaccel_output_format', 'cuda',
      '-i', input,
      '-sn', '-dn',
      ...maps,
      ...filters,
      ...encArgs,
      '-f', 'dash',
      '-seg_duration', '$segmentDuration',
      '-use_timeline', '1',
      '-use_template', '1',
      '-init_seg_name',  '$segDir${Platform.pathSeparator}${stem}_${repId}_init.mp4',
      '-media_seg_name', '$segDir${Platform.pathSeparator}${stem}_${repId}_${num}.m4s',
      '-adaptation_sets', 'id=0,streams=v id=1,streams=a',
      '$segDir${Platform.pathSeparator}$stem.mpd',
    ];
  } else {
    // ── CPU path: filter graph with split → scale ────────────────────────────
    final splitParts = List.generate(n, (i) => '[v$i]').join();
    final splitFilter = '[0:v]split=$n$splitParts';
    final scaleFilters = [
      for (var i = 0; i < n; i++)
        '[v$i]scale=${resolutions[i].width}:${resolutions[i].height},setsar=1[scaled$i]',
    ];
    final filterComplex = '$splitFilter;${scaleFilters.join(";")}';

    final maps = <String>[
      for (var i = 0; i < n; i++) ...[ '-map', '[scaled$i]' ],
      '-map', '0:a:0?',
    ];
    final videoArgs = <String>[
      for (var i = 0; i < n; i++)
        ..._videoEncoderArgs(i, resolutions[i], spec,
            nvenc: false, gpuFrames: false, quality: quality, hdr: hdrMeta),
    ];

    cmd = [
      ffmpegPath(), '-y', '-i', input,
      '-sn', '-dn',
      '-filter_complex', filterComplex,
      ...maps,
      ...videoArgs,
      '-c:a:$n', 'aac',
      '-b:a:$n', resolutions.first.audioBitrate,
      '-ac:$n', '2',
      '-ar:$n', '44100',
      '-f', 'dash',
      '-seg_duration', '$segmentDuration',
      '-use_timeline', '1',
      '-use_template', '1',
      '-init_seg_name',  '$segDir${Platform.pathSeparator}${stem}_${repId}_init.mp4',
      '-media_seg_name', '$segDir${Platform.pathSeparator}${stem}_${repId}_${num}.m4s',
      '-adaptation_sets', 'id=0,streams=v id=1,streams=a',
      '$segDir${Platform.pathSeparator}$stem.mpd',
    ];
  }

  return cmd;
}


/// Move <stem>.mpd from <segDir> up to <outputDir>/<stem>.mpd and rewrite
/// SegmentTemplate paths to include the stem subdirectory.
Future<void> promoteDashManifest({
  required String input,
  required String outputDir,
}) async {
  final stem    = sanitiseStem(input);
  final sep     = Platform.pathSeparator;
  final segDir  = '$outputDir$sep$stem';
  final srcMpd  = File('$segDir$sep$stem.mpd');
  final dstMpd  = File('$outputDir$sep$stem.mpd');

  final text = await srcMpd.readAsString();
  final doc  = XmlDocument.parse(text);

  // Segment names are written as absolute paths by ffmpeg.
  // Strip the segDir prefix (+ separator) to get the bare filename,
  // then prepend stem/ for the promoted MPD's relative path.
  final segDirPrefix = '$segDir$sep';

  String _toRelative(String val) {
    // Already correctly relative (e.g. after re-run on existing output)
    if (val.startsWith('$stem/') || val.startsWith('$stem\\')) return val;
    // Strip absolute segDir prefix if present
    final bare = val.startsWith(segDirPrefix)
        ? val.substring(segDirPrefix.length)
        : val;
    return '$stem/$bare';
  }

  for (final node in doc.findAllElements('SegmentTemplate')) {
    for (final attr in ['initialization', 'media']) {
      final val = node.getAttribute(attr);
      if (val != null) node.setAttribute(attr, _toRelative(val));
    }
  }
  for (final node in doc.findAllElements('SegmentURL')) {
    final val = node.getAttribute('media');
    if (val != null) node.setAttribute('media', _toRelative(val));
  }
  for (final node in doc.findAllElements('Initialization')) {
    final val = node.getAttribute('sourceURL');
    if (val != null) node.setAttribute('sourceURL', _toRelative(val));
  }

  await dstMpd.writeAsString(doc.toXmlString(pretty: false));
  await srcMpd.delete();
}
