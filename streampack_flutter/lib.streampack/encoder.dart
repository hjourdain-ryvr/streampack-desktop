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
  // Basename (handle both / and \ so Windows paths work on any host), no ext.
  var stem = inputPath.split(RegExp(r'[/\\]')).last;
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  return stemFromName(stem);
}

/// Sanitise a plain name (no path/extension handling) into a filesystem- and
/// URI-safe stem: spaces -> underscore, keep word chars + hyphen, collapse.
/// Used for the segment directory, segment filenames and manifest URIs.
String stemFromName(String name) {
  var stem = name.replaceAll(RegExp(r'\s+'), '_');
  stem = stem.replaceAll(RegExp(r'[^\w\-]'), '');
  stem = stem.replaceAll(RegExp(r'_+'), '_');
  stem = stem.replaceAll(RegExp(r'_-_'), '-');
  stem = stem.replaceAll(RegExp(r'_-(?!_)'), '-');
  stem = stem.replaceAll(RegExp(r'(?<!_)-_'), '-');
  stem = stem.replaceAll(RegExp(r'_+'), '_');
  stem = stem.replaceAll(RegExp(r'^[_\-]+|[_\-]+$'), '');
  return stem.isEmpty ? 'output' : stem;
}

/// Default output name from a source path: basename without extension, as-is
/// (spaces/brackets kept). This is what the UI pre-fills and the user can edit.
String defaultOutputName(String inputPath) {
  var n = inputPath.split(RegExp(r'[/\\]')).last;
  final dot = n.lastIndexOf('.');
  if (dot > 0) n = n.substring(0, dot);
  return n.trim();
}

/// Filesystem-safe master/manifest filename: keep spaces, parentheses, brackets
/// and hyphens (Plex/Jellyfin need e.g. "[tmdbid-348]"), strip only characters
/// illegal in a filename. Falls back to a sanitised stem if empty.
String safeFileName(String name) {
  final s = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
  return s.isEmpty ? stemFromName(name) : s;
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

/// Probe the full stream layout of a source (video colour, audio tracks,
/// subtitle tracks) for the 3.0.0 Advanced tab. Falls back to an SDR-8 / empty
/// result on any failure.
Future<MediaStreams> probeMediaStreams(String input) async {
  try {
    final res = await Process.run(ffprobePath(), [
      '-v', 'error',
      '-show_entries',
      'stream=index,codec_type,codec_name,profile,channels,channel_layout,'
          'pix_fmt,color_transfer:stream_tags=language,title:stream_disposition=default',
      '-of', 'json', input,
      // ffprobe emits UTF-8; force UTF-8 decoding so track titles with accents
      // (e.g. "Stéréo") are not mangled by the platform's default codepage.
    ], stdoutEncoding: utf8).timeout(const Duration(seconds: 15));
    if (res.exitCode != 0) return const MediaStreams(color: InputColor.sdr8);

    final data    = jsonDecode(res.stdout as String) as Map<String, dynamic>;
    final streams = (data['streams'] as List?) ?? const [];

    var color = InputColor.sdr8;
    var sawVideo = false;
    final audio = <AudioTrack>[];
    final subs  = <SubtitleTrack>[];
    var aOrder = 0, sOrder = 0;

    for (final s in streams) {
      final m    = s as Map<String, dynamic>;
      final type = m['codec_type'] as String?;
      final tags = (m['tags'] as Map?) ?? const {};
      if (type == 'video' && !sawVideo) {
        sawVideo = true;
        color = InputColor.classify(
          pixFmt: m['pix_fmt'] as String?,
          colorTransfer: m['color_transfer'] as String?,
        );
      } else if (type == 'audio') {
        final disp = (m['disposition'] as Map?) ?? const {};
        audio.add(AudioTrack(
          index: (m['index'] as num?)?.toInt() ?? 0,
          order: aOrder++,
          codec: (m['codec_name'] as String?) ?? 'unknown',
          profile: m['profile'] as String?,
          channels: (m['channels'] as num?)?.toInt() ?? 0,
          channelLayout: m['channel_layout'] as String?,
          language: tags['language'] as String?,
          title: tags['title'] as String?,
          isDefault: disp['default'] == 1,
        ));
      } else if (type == 'subtitle') {
        subs.add(SubtitleTrack(
          index: (m['index'] as num?)?.toInt() ?? 0,
          order: sOrder++,
          codec: (m['codec_name'] as String?) ?? 'unknown',
          language: tags['language'] as String?,
          title: tags['title'] as String?,
        ));
      }
    }

    final hdr = color == InputColor.hdr ? await probeHdrMetadata(input) : null;
    return MediaStreams(color: color, hdr: hdr, audio: audio, subtitles: subs);
  } catch (_) {
    return const MediaStreams(color: InputColor.sdr8);
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
int _kbpsOf(String br) => int.tryParse(br.replaceAll(RegExp(r'[^\d]'), '')) ?? 5000;

String _scaledVideoBitrate(int anchor4kKbps, Preset r, bool hdr) =>
    '${scaledVideoBitrateKbps(anchor4kKbps, r.width, r.height, hdr: hdr)}k';

/// Rate-control args for stream [i].
/// - vq == null            -> legacy fixed per-preset bitrate (2.0.0, unchanged)
/// - vq bitrate mode       -> scaled 4K anchor with VBV cap
/// - vq crf mode           -> constant CRF/CQ (same every rung) + generous cap
List<String> _rateCtl(int i, Preset r, _OutSpec spec, VideoQuality? vq,
    {required bool nvenc}) {
  if (vq != null && vq.mode == VideoQualityMode.crf) {
    // Generous safety cap (top anchor scaled) so a pathological segment can't
    // blow past the rung's budget; normally it never binds.
    final cap  = _scaledVideoBitrate(
        spec.hevc ? kHevcBitrateAnchorsKbps.first : kAvcBitrateAnchorsKbps.first,
        r, spec.hdr);
    final buf  = '${_kbpsOf(cap) * 2}k';
    if (nvenc) {
      return ['-rc:v:$i', 'vbr', '-cq:v:$i', '${vq.crf}', '-b:v:$i', '0',
              '-maxrate:v:$i', cap, '-bufsize:v:$i', buf];
    }
    return ['-crf:v:$i', '${vq.crf}', '-maxrate:v:$i', cap, '-bufsize:v:$i', buf];
  }
  // Bitrate mode (override or legacy preset ladder)
  final br  = vq != null ? _scaledVideoBitrate(vq.bitrate4kKbps, r, spec.hdr)
                         : r.videoBitrate;
  final buf = '${_kbpsOf(br) * 2}k';
  if (nvenc) {
    return ['-rc:v:$i', 'vbr', '-b:v:$i', br,
            '-maxrate:v:$i', br, '-bufsize:v:$i', buf];
  }
  // CPU: keep the legacy single-arg form when no override (byte-identical);
  // add a VBV cap when the user set an explicit bitrate.
  return vq != null
      ? ['-b:v:$i', br, '-maxrate:v:$i', br, '-bufsize:v:$i', buf]
      : ['-b:v:$i', br];
}

List<String> _videoEncoderArgs(int i, Preset r, _OutSpec spec,
    {required bool nvenc, required bool gpuFrames,
     required EncodeQuality quality, HdrMetadata? hdr, VideoQuality? vq}) {
  // Effort/preset: Advanced override carries its own; Basic uses EncodeQuality.
  final nvPreset  = vq?.effort.nvencPreset ?? quality.nvencPreset;
  final cpuPreset = vq?.effort.cpuPreset   ?? quality.x264Preset;
  if (nvenc) {
    final codec   = spec.hevc ? 'hevc_nvenc' : 'h264_nvenc';
    final profile = spec.hevc ? (spec.tenBit ? 'main10' : 'main') : 'high';
    return [
      '-c:v:$i', codec,
      '-preset:v:$i', nvPreset,
      '-tune:v:$i', 'hq',
      '-profile:v:$i', profile,
      ..._rateCtl(i, r, spec, vq, nvenc: true),
      if (!gpuFrames) ...['-pix_fmt:v:$i', spec.cpuPixFmt],
      // hvc1 (params in init) is required by Apple HLS for HEVC and makes ffmpeg
      // emit the CODECS string in the master playlist.
      if (spec.hevc) ...['-tag:v:$i', 'hvc1'],
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
      '-tag:v:$i', 'hvc1',   // Apple-HLS-compatible HEVC tag + emits CODECS
      '-x265-params:v:$i', params.join(':'),
      ..._rateCtl(i, r, spec, vq, nvenc: false),
    ];
  }

  return [
    '-c:v:$i', 'libx264',
    '-preset:v:$i', quality.x264Preset,
    '-pix_fmt:v:$i', 'yuv420p',
    ..._rateCtl(i, r, spec, vq, nvenc: false),
  ];
}



// === Multi-audio (3.0.0 Advanced tab) =======================================
// Used only when a Job carries a non-empty audioPlan. With an empty plan the
// 2.0.0 single-audio path (audio muxed per video rendition) is used unchanged.

/// Video-only per-rendition map + encoder args (HLS CPU-frame path), i.e. the
/// 2.0.0 _streamArgs without the muxed audio - audio is added separately as
/// alternate renditions.
List<String> _videoStreamArgs(List<Preset> resolutions, _OutSpec spec,
    {required bool nvenc, required EncodeQuality quality, HdrMetadata? hdr,
     VideoQuality? vq}) {
  final args = <String>[];
  for (var i = 0; i < resolutions.length; i++) {
    args.addAll([
      '-map', '[scaled$i]',
      ..._videoEncoderArgs(i, resolutions[i], spec,
          nvenc: nvenc, gpuFrames: false, quality: quality, hdr: hdr, vq: vq),
    ]);
  }
  return args;
}

/// Audio output args (maps + per-track codec) for a stream plan. Audio output
/// streams follow the video streams; codec options use the audio-type index
/// (a:0, a:1, ...) in the order kept tracks are mapped.
List<String> _audioPlanArgs(List<AudioSelection> kept) {
  final args = <String>[];
  for (final s in kept) {
    args.addAll(['-map', '0:a:${s.sourceOrder}?']);
  }
  for (var i = 0; i < kept.length; i++) {
    final s = kept[i];
    if (s.action == AudioAction.passthrough) {
      args.addAll(['-c:a:$i', 'copy']);
    } else {
      final stereo = s.channels == AudioChannelMode.stereo;
      args.addAll([
        '-c:a:$i', s.target.encoder,
        if (stereo) ...['-ac:$i', '2'],
        '-b:a:$i', stereo ? '128k' : '384k',
        '-ar:$i', '44100',
      ]);
    }
  }
  return args;
}

/// var_stream_map for HLS alternate-audio rendition groups: each video variant
/// references the audio group; each kept audio track is a group member with its
/// language and default flag. Audio output index = audio order among kept tracks.
String _hlsVarStreamMapMulti(List<Preset> resolutions, List<AudioSelection> kept) {
  if (kept.isEmpty) {
    // All audio removed -> video-only variants, no audio group.
    return [
      for (var i = 0; i < resolutions.length; i++) 'v:$i,name:${resolutions[i].height}p',
    ].join(' ');
  }
  const grp = 'aud';
  // Exactly one audio rendition must be DEFAULT=YES and the rest explicitly
  // DEFAULT=NO. If none is flagged (e.g. the source default track was removed),
  // fall back to the first kept track. Omitting default entirely makes ffmpeg
  // mark them ALL default AND emit bogus audio STREAM-INF variants -> players
  // show garbled audio track lists and fail to play audio.
  var defIdx = kept.indexWhere((a) => a.isDefault);
  if (defIdx < 0) defIdx = 0;
  final parts = <String>[
    for (var i = 0; i < resolutions.length; i++)
      'v:$i,agroup:$grp,name:${resolutions[i].height}p',
    for (var i = 0; i < kept.length; i++)
      'a:$i,agroup:$grp'
      '${kept[i].language != null ? ',language:${kept[i].language}' : ''}'
      ',default:${i == defIdx ? 'yes' : 'no'}'
      ',name:a${i}_${kept[i].language ?? 'und'}',
  ];
  return parts.join(' ');
}

/// adaptation_sets for DASH: all video renditions in one set (ABR ladder),
/// each kept audio track in its own set. Output stream indices: video 0..n-1,
/// audio n..n+k-1.
String _dashAdaptationSetsMulti(int videoCount, int audioCount) {
  final videoIdx = [for (var i = 0; i < videoCount; i++) i].join(',');
  final sets = <String>['id=0,streams=$videoIdx'];
  for (var i = 0; i < audioCount; i++) {
    sets.add('id=${i + 1},streams=${videoCount + i}');
  }
  return sets.join(' ');
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
    {required bool nvenc, required EncodeQuality quality, HdrMetadata? hdr,
     VideoQuality? vq}) {
  final args = <String>[];
  for (var i = 0; i < resolutions.length; i++) {
    final r = resolutions[i];
    args.addAll([
      '-map', '[scaled$i]', '-map', '0:a:0?',
      ..._videoEncoderArgs(i, r, spec,
          nvenc: nvenc, gpuFrames: false, quality: quality, hdr: hdr, vq: vq),
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
  List<AudioSelection> audioPlan = const [],
  VideoQuality? videoQuality,
  String? stemOverride,
}) {
  final stem   = stemOverride ?? sanitiseStem(input);
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

  final common = <String>[
    '-f', 'hls',
    '-hls_time', '$segmentDuration',
    '-hls_playlist_type', 'vod',
    '-hls_flags', 'independent_segments',
    ...segArgs,
    '-master_pl_name', 'master.m3u8',
  ];

  // Empty plan -> 2.0.0 path: single audio muxed into each video rendition.
  if (audioPlan.isEmpty) {
    return [
      ffmpegPath(), '-y', '-i', input,
      '-sn', '-dn',
      ..._filterComplexArgs(resolutions),
      ..._streamArgs(resolutions, spec, nvenc: nvenc, quality: quality, hdr: hdrMeta, vq: videoQuality),
      ...common,
      '-var_stream_map',
      resolutions.map((r) => 'v:${resolutions.indexOf(r)},a:${resolutions.indexOf(r)},name:${r.height}p').join(' '),
      '$segDir/${stem}_%v.m3u8',
    ];
  }

  // Multi-audio path: video-only variants + alternate audio rendition group.
  final kept = audioPlan.where((s) => s.action != AudioAction.remove).toList();
  return [
    ffmpegPath(), '-y', '-i', input,
    '-sn', '-dn',
    ..._filterComplexArgs(resolutions),
    ..._videoStreamArgs(resolutions, spec, nvenc: nvenc, quality: quality, hdr: hdrMeta, vq: videoQuality),
    ..._audioPlanArgs(kept),
    ...common,
    '-var_stream_map', _hlsVarStreamMapMulti(resolutions, kept),
    '$segDir/${stem}_%v.m3u8',
  ];
}

// ISO 639-2 -> display name (common subset; falls back to the uppercase code).
const _audioLangNames = <String, String>{
  'eng':'English','fra':'French','fre':'French','spa':'Spanish','deu':'German','ger':'German',
  'ita':'Italian','por':'Portuguese','rus':'Russian','jpn':'Japanese','kor':'Korean',
  'zho':'Chinese','chi':'Chinese','nld':'Dutch','dut':'Dutch','swe':'Swedish','nor':'Norwegian',
  'dan':'Danish','fin':'Finnish','pol':'Polish','ces':'Czech','cze':'Czech','tha':'Thai',
  'ara':'Arabic','hin':'Hindi','heb':'Hebrew','tur':'Turkish','ell':'Greek','hun':'Hungarian',
  'ron':'Romanian','ukr':'Ukrainian','vie':'Vietnamese','ind':'Indonesian',
};

String _channelLabel(String? ch) => switch (ch) {
  '1' => 'Mono', '2' => 'Stereo', '6' => '5.1', '8' => '7.1',
  _   => (ch != null && ch.isNotEmpty) ? '${ch}ch' : '',
};

/// Rewrite an #EXT-X-MEDIA:TYPE=AUDIO line: (1) NAME from ffmpeg's auto "audio_N"
/// to a friendly "<Language> <layout>" label (e.g. "English 5.1"), de-duplicated
/// via [used] (appends " (2)", " (3)", ...); (2) prefix the rendition URI with
/// the [stem] subdirectory so it matches where the audio playlists actually live
/// (same prefix the video variant URIs get). Without (2) players load the video
/// but fail to find the audio -> video plays with NO sound.
String _friendlyAudioMediaLine(String line, Set<String> used, String stem) {
  final lang = RegExp(r'LANGUAGE="([^"]*)"').firstMatch(line)?.group(1);
  final ch   = RegExp(r'CHANNELS="([^"]*)"').firstMatch(line)?.group(1);
  final langName = (lang == null || lang.isEmpty || lang == 'und')
      ? '' : (_audioLangNames[lang] ?? lang.toUpperCase());
  final parts = [langName, _channelLabel(ch)].where((s) => s.isNotEmpty).toList();
  var name = parts.isEmpty ? 'Audio' : parts.join(' ');
  if (used.contains(name)) {
    var n = 2;
    while (used.contains('$name ($n)')) { n++; }
    name = '$name ($n)';
  }
  used.add(name);
  var out = line.replaceFirst(RegExp(r'NAME="[^"]*"'), 'NAME="$name"');
  out = out.replaceFirstMapped(RegExp(r'URI="([^"]+)"'), (m) {
    final u = m.group(1)!;
    return (u.endsWith('.m3u8') && !u.startsWith('$stem/'))
        ? 'URI="$stem/$u"' : 'URI="$u"';
  });
  return out;
}

/// Move master.m3u8 from <segDir> to <outputDir>/<stem>.m3u8 and rewrite
/// variant URIs to include the stem subdirectory prefix.
/// Add Apple-HLS-required attributes to a video EXT-X-STREAM-INF line:
/// VIDEO-RANGE (SDR/PQ - required when HDR is present), FRAME-RATE, and
/// CLOSED-CAPTIONS=NONE (required when there are no captions). Idempotent;
/// only touches video variants (those with RESOLUTION).
String _augmentStreamInf(String inf, String videoRange, String frameRate) {
  if (!inf.contains('RESOLUTION=')) return inf;
  var s = inf;
  if (!s.contains('VIDEO-RANGE=')) s += ',VIDEO-RANGE=$videoRange';
  if (frameRate.isNotEmpty && !s.contains('FRAME-RATE=')) s += ',FRAME-RATE=$frameRate';
  if (!s.contains('CLOSED-CAPTIONS')) s += ',CLOSED-CAPTIONS=NONE';
  return s;
}

Future<void> promoteHlsMaster({
  required String input,
  required String outputDir,
  String videoRange = 'SDR',   // 'SDR' | 'PQ' (HDR10) | 'HLG'
  String frameRate  = '',      // e.g. '23.976'; empty = omit
  String? stemOverride,        // segment dir + URIs (safe form of output name)
  String masterName = '',      // master filename (pretty form of output name)
}) async {
  final stem      = stemOverride ?? sanitiseStem(input);
  final sep       = Platform.pathSeparator;
  final segDir    = '$outputDir$sep$stem';
  final srcMaster = File('$segDir${sep}master.m3u8');
  final dstMaster = File('$outputDir$sep${masterName.isNotEmpty ? masterName : stem}.m3u8');

  final lines = await srcMaster.readAsLines();

  // Rewrite variant URIs to include the stem subdirectory prefix,
  // then sort variant blocks by BANDWIDTH ascending (HLS spec SHOULD).
  // Each variant block = one #EXT-X-STREAM-INF line + one URI line.
  final header  = <String>[];   // lines before first variant
  final variants = <({String inf, String uri})>[];
  final usedAudioNames = <String>{};  // for de-duplicating friendly NAMEs
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
      variants.add((inf: _augmentStreamInf(pendingInf!, videoRange, frameRate), uri: uri));
      pendingInf = null;
    } else if (!inVariants) {
      // Replace ffmpeg's auto "audio_N" NAME with a friendly language+layout
      // label (e.g. "English 5.1"), de-duplicated.
      header.add(t.startsWith('#EXT-X-MEDIA:TYPE=AUDIO')
          ? _friendlyAudioMediaLine(line, usedAudioNames, stem)
          : line);
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

  // Apple requires EXT-X-INDEPENDENT-SEGMENTS in the master (our segments are
  // encoded independent via -hls_flags independent_segments).
  if (!header.any((l) => l.contains('EXT-X-INDEPENDENT-SEGMENTS'))) {
    final vIdx = header.indexWhere((l) => l.startsWith('#EXT-X-VERSION'));
    header.insert(vIdx >= 0 ? vIdx + 1 : header.length, '#EXT-X-INDEPENDENT-SEGMENTS');
  }

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
  List<AudioSelection> audioPlan = const [],
  VideoQuality? videoQuality,
  String? stemOverride,
}) {
  final stem   = stemOverride ?? sanitiseStem(input);
  final sep    = Platform.pathSeparator;
  final segDir = '$outputDir$sep$stem';
  final n      = resolutions.length;
  final spec   = _OutSpec.from(output, inputColor);

  const repId = r'$RepresentationID$';
  const num   = r'$Number$';

  // Empty plan -> 2.0.0 single-audio (one AdaptationSet for all audio, muxed per
  // rendition). Non-empty -> one AdaptationSet per kept track (validated: all
  // video renditions share one set; app presets are all 16:9).
  final multi = audioPlan.isNotEmpty;
  final kept  = audioPlan.where((s) => s.action != AudioAction.remove).toList();

  // DASH uses absolute seg names with the platform separator. On Windows this is
  // correct (the muxer does not re-prepend a drive-letter path); the deploy
  // target is Windows. (2.0.0 validated.)
  final dashTail = <String>[
    '-f', 'dash',
    '-seg_duration', '$segmentDuration',
    '-use_timeline', '1',
    '-use_template', '1',
    '-init_seg_name',  '$segDir$sep${stem}_${repId}_init.mp4',
    '-media_seg_name', '$segDir$sep${stem}_${repId}_${num}.m4s',
    '-adaptation_sets',
    multi ? _dashAdaptationSetsMulti(n, kept.length) : 'id=0,streams=v id=1,streams=a',
    '$segDir$sep$stem.mpd',
  ];

  final List<String> cmd;

  if (nvenc) {
    // ── NVENC path: per-stream mapping with scale_cuda + setsar ──────────────
    // Video uses -map 0:v:0 per output with -filter:v:N. Audio is muxed per
    // rendition (2.0.0) or mapped separately as alternate tracks (multi).
    final maps    = <String>[];
    final filters = <String>[];
    final encArgs = <String>[];

    for (var i = 0; i < n; i++) {
      maps.addAll(['-map', '0:v:0']);
      if (!multi) maps.addAll(['-map', '0:a:0?']);
      filters.addAll(['-filter:v:$i',
          'scale_cuda=${resolutions[i].width}:${resolutions[i].height}:format=${spec.cudaPixFmt},setsar=1']);
      encArgs.addAll(_videoEncoderArgs(i, resolutions[i], spec,
          nvenc: true, gpuFrames: true, quality: quality, hdr: hdrMeta, vq: videoQuality));
      if (!multi) {
        encArgs.addAll([
          '-c:a:$i', 'aac', '-b:a:$i', resolutions[i].audioBitrate,
          '-ac:$i', '2', '-ar:$i', '44100',
        ]);
      }
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
      if (multi) ..._audioPlanArgs(kept),
      ...dashTail,
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
      if (!multi) ...['-map', '0:a:0?'],
    ];
    final videoArgs = <String>[
      for (var i = 0; i < n; i++)
        ..._videoEncoderArgs(i, resolutions[i], spec,
            nvenc: false, gpuFrames: false, quality: quality, hdr: hdrMeta, vq: videoQuality),
    ];

    cmd = [
      ffmpegPath(), '-y', '-i', input,
      '-sn', '-dn',
      '-filter_complex', filterComplex,
      ...maps,
      ...videoArgs,
      if (!multi) ...[
        '-c:a:$n', 'aac', '-b:a:$n', resolutions.first.audioBitrate,
        '-ac:$n', '2', '-ar:$n', '44100',
      ],
      if (multi) ..._audioPlanArgs(kept),
      ...dashTail,
    ];
  }

  return cmd;
}


/// Move <stem>.mpd from <segDir> up to <outputDir>/<stem>.mpd and rewrite
/// SegmentTemplate paths to include the stem subdirectory.
Future<void> promoteDashManifest({
  required String input,
  required String outputDir,
  String? stemOverride,
  String masterName = '',
}) async {
  final stem    = stemOverride ?? sanitiseStem(input);
  final sep     = Platform.pathSeparator;
  final segDir  = '$outputDir$sep$stem';
  final srcMpd  = File('$segDir$sep$stem.mpd');
  final dstMpd  = File('$outputDir$sep${masterName.isNotEmpty ? masterName : stem}.mpd');

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

  // Add a human <Label> to each audio AdaptationSet so players show distinct,
  // readable names (e.g. "English 5.1") instead of several identical "eng"
  // entries. Built from lang + channel layout, de-duplicated. Mirrors the
  // friendly HLS rendition names so a track is labelled the same in both.
  final usedDashNames = <String>{};
  for (final as in doc.findAllElements('AdaptationSet')) {
    if (as.getAttribute('contentType') != 'audio') continue;
    final lang = as.getAttribute('lang');
    String? ch;
    for (final e in as.findAllElements('AudioChannelConfiguration')) {
      ch = e.getAttribute('value');
      if (ch != null) break;
    }
    final langName = (lang == null || lang.isEmpty || lang == 'und')
        ? '' : (_audioLangNames[lang] ?? lang.toUpperCase());
    final parts = [langName, _channelLabel(ch)].where((s) => s.isNotEmpty).toList();
    var name = parts.isEmpty ? 'Audio' : parts.join(' ');
    if (usedDashNames.contains(name)) {
      var k = 2;
      while (usedDashNames.contains('$name ($k)')) { k++; }
      name = '$name ($k)';
    }
    usedDashNames.add(name);
    as.children.removeWhere((n) => n is XmlElement && n.name.local == 'Label');
    as.children.insert(0, XmlElement(XmlName('Label'), [], [XmlText(name)]));
  }

  await dstMpd.writeAsString(doc.toXmlString(pretty: false));
  await srcMpd.delete();
}
