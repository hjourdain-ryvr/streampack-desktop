import 'package:flutter/foundation.dart';
import 'dart:io';
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

/// Extra flags needed per encoder:
/// - libx264: preset from quality setting (medium/slow)
/// - h264_nvenc: preset p4/p6 from quality, vbr with bufsize, high profile
List<String> _videoEncoderArgs(int streamIdx, Preset r, bool nvenc, EncodeQuality quality) {
  if (nvenc) {
    final bitrateStr = r.videoBitrate;
    final bitrateVal = int.tryParse(
        bitrateStr.replaceAll(RegExp(r'[^\d]'), '')) ?? 5000;
    final unit = bitrateStr.replaceAll(RegExp(r'[\d]'), '');
    final bufsize = '${bitrateVal * 2}$unit';
    return [
      '-c:v:$streamIdx', 'h264_nvenc',
      '-preset:v:$streamIdx', quality.nvencPreset,
      '-tune:v:$streamIdx', 'hq',
      '-profile:v:$streamIdx', 'high',
      '-rc:v:$streamIdx', 'vbr',
      '-b:v:$streamIdx', bitrateStr,
      '-maxrate:v:$streamIdx', bitrateStr,
      '-bufsize:v:$streamIdx', bufsize,
    ];
  }
  return [
    '-c:v:$streamIdx', 'libx264',
    '-preset:v:$streamIdx', quality.x264Preset,
    '-b:v:$streamIdx', r.videoBitrate,
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

List<String> _streamArgs(List<Preset> resolutions, {required bool nvenc, required EncodeQuality quality}) {
  final args = <String>[];
  for (var i = 0; i < resolutions.length; i++) {
    final r = resolutions[i];
    args.addAll([
      '-map', '[scaled$i]', '-map', '0:a',
      ..._videoEncoderArgs(i, r, nvenc, quality),
      '-c:a:$i', 'aac', '-b:a:$i', r.audioBitrate,
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
}) {
  final stem   = sanitiseStem(input);
  final segDir = '$outputDir${Platform.pathSeparator}$stem';

  return [
    ffmpegPath(), '-y', '-i', input,
    ..._filterComplexArgs(resolutions),
    ..._streamArgs(resolutions, nvenc: nvenc, quality: quality),
    '-f', 'hls',
    '-hls_time', '$segmentDuration',
    '-hls_playlist_type', 'vod',
    '-hls_flags', 'independent_segments',
    '-hls_segment_type', 'mpegts',
    '-hls_segment_filename', '$segDir${Platform.pathSeparator}${stem}_%v_%03d.ts',
    '-master_pl_name', 'master.m3u8',
    '-var_stream_map',
    resolutions.map((r) => 'v:${resolutions.indexOf(r)},a:${resolutions.indexOf(r)},name:${r.height}p').join(' '),
    '$segDir${Platform.pathSeparator}${stem}_%v.m3u8',
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
}) {
  final stem   = sanitiseStem(input);
  final segDir = '$outputDir${Platform.pathSeparator}$stem';
  final n      = resolutions.length;

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
      maps.addAll(['-map', '0:v:0', '-map', '0:a:0']);
      filters.addAll(['-filter:v:$i',
          'scale_cuda=${resolutions[i].width}:${resolutions[i].height},setsar=1']);
      encArgs.addAll(_videoEncoderArgs(i, resolutions[i], true, quality));
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
      '-map', '0:a:0',
    ];
    final videoArgs = <String>[
      for (var i = 0; i < n; i++) ..._videoEncoderArgs(i, resolutions[i], false, quality),
    ];

    cmd = [
      ffmpegPath(), '-y', '-i', input,
      '-filter_complex', filterComplex,
      ...maps,
      ...videoArgs,
      '-c:a:$n', 'aac',
      '-b:a:$n', resolutions.first.audioBitrate,
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
