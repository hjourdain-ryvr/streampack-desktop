import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:convert';
import 'package:xml/xml.dart';
import 'models.dart';
import 'ffmpeg.dart';
// Accent folding

/// Accented Latin letter (by code point) -> ASCII base, "simple fold": the
/// diacritic is dropped to the base letter (e-acute -> e, u-umlaut -> u,
/// a-ring -> a). The few characters with no single base expand (sharp-s -> ss,
/// ligatures ae/oe, thorn -> th). Covers the languages supported (FR/DE/SV) plus
/// the rest of Latin-1.
const Map<int, String> _accentFold = {
  0x00C0:'A',0x00C1:'A',0x00C2:'A',0x00C3:'A',0x00C4:'A',0x00C5:'A',0x00C6:'AE',
  0x00C7:'C',
  0x00C8:'E',0x00C9:'E',0x00CA:'E',0x00CB:'E',
  0x00CC:'I',0x00CD:'I',0x00CE:'I',0x00CF:'I',
  0x00D0:'D',0x00D1:'N',
  0x00D2:'O',0x00D3:'O',0x00D4:'O',0x00D5:'O',0x00D6:'O',0x00D8:'O',
  0x00D9:'U',0x00DA:'U',0x00DB:'U',0x00DC:'U',
  0x00DD:'Y',0x00DE:'TH',0x00DF:'ss',
  0x00E0:'a',0x00E1:'a',0x00E2:'a',0x00E3:'a',0x00E4:'a',0x00E5:'a',0x00E6:'ae',
  0x00E7:'c',
  0x00E8:'e',0x00E9:'e',0x00EA:'e',0x00EB:'e',
  0x00EC:'i',0x00ED:'i',0x00EE:'i',0x00EF:'i',
  0x00F0:'d',0x00F1:'n',
  0x00F2:'o',0x00F3:'o',0x00F4:'o',0x00F5:'o',0x00F6:'o',0x00F8:'o',
  0x00F9:'u',0x00FA:'u',0x00FB:'u',0x00FC:'u',
  0x00FD:'y',0x00FF:'y',0x00FE:'th',
  0x0152:'OE',0x0153:'oe', // OE / oe ligature
  0x0178:'Y',              // Y with diaeresis
  0x1E9E:'SS',             // capital sharp s
};

/// Transliterate accented Latin letters to ASCII so titles keep their letters in
/// output filenames and manifest URIs (e-acute -> e) instead of dropping them.
/// Precomposed characters go through [_accentFold]. Combining marks (NFD input)
/// are removed, leaving the base letter.
String foldAccents(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final m = _accentFold[r];
    if (m != null) {
      b.write(m);
    } else if (r >= 0x0300 && r <= 0x036F) {
      // combining diacritical mark -> drop (base letter already written)
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

// Stem sanitisation

/// Return a safe filename stem from an input path.
/// Rules applied in order:
///   1. Spaces -> underscores
///   2. Strip unsafe URI characters (keep word chars and hyphens)
///   3. Collapse multiple underscores -> single underscore
///   4. Clean up _-_, _-, -_ patterns -> single hyphen
///   5. Collapse underscores again (in case step 4 produced new sequences)
///   6. Strip leading/trailing underscores and hyphens
String sanitiseStem(String inputPath) {
  // Basename (handle both / and \ so Windows paths work on any host), no ext.
  var stem = inputPath.split(RegExp(r'[/\\]')).last;
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot);
  return stemFromName(stem);
}

/// Sanitise a plain name (no path/extension handling) into a filesystem - and
/// URI - safe stem: spaces -> underscore, keep word chars + hyphen, collapse.
/// Used for the segment directory, segment filenames and manifest URIs.
String stemFromName(String name) {
  // Fold accents first, so accented letters become ASCII (e-acute -> e) instead
  // of being deleted by the word-char strip below.
  var stem = foldAccents(name).replaceAll(RegExp(r'\s+'), '_');
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
  // Fold accents to ASCII (keeping spaces/brackets) so the master manifest name
  // matches the ASCII segment stem and needs no URL-encoding when served.
  final s = foldAccents(name).replaceAll(RegExp(r'[\\/:*?"<>|]'), '').trim();
  return s.isEmpty ? stemFromName(name) : s;
}

// NVIDIA NVENC detection

/// Cached result of NVENC availability check.
/// null = not yet checked, true = available, false = not available.
bool? _nvencAvailable;

/// Check whether h264_nvenc is available at runtime.
/// Uses a 1-frame encode from the color filter source.
/// nullsrc produces wrapped_avframe which requires a decoder not in our
/// minimal build - color filter outputs raw frames directly.
/// Result is cached - only probed once per session.
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

// Source colour / HDR probing

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
      // are not mangled by the platform's default codepage.
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
    // H.264 -> always 8-bit (10-bit SDR reduced 10->8). H.265 -> keep input depth.
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
///   10-bit is preserved and 10-bit-SDR->H.264 is reduced 10->8.
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
     required EncodeQuality quality, HdrMetadata? hdr, VideoQuality? vq,
     bool sdrTags = false}) {
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
      ]
      // Tone-mapped SDR rung: tag bt709 explicitly so players/manifests report
      // SDR (the tonemap chain already outputs bt709 frames).
      else if (sdrTags) ...[
        '-colorspace:v:$i', 'bt709',
        '-color_primaries:v:$i', 'bt709',
        '-color_trc:v:$i', 'bt709',
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
    } else if (sdrTags) {
      params.addAll(['colorprim=bt709', 'transfer=bt709', 'colormatrix=bt709']);
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
    if (sdrTags) ...[
      '-colorspace:v:$i', 'bt709',
      '-color_primaries:v:$i', 'bt709',
      '-color_trc:v:$i', 'bt709',
    ],
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
        if (stereo) ...['-ac:a:$i', '2'],
        '-b:a:$i', stereo ? '128k' : '384k',
        '-ar:a:$i', '44100',
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
/// this filter runs, so no padding needed - just scale down.
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
      '-ac:a:$i', '2',
      '-ar:a:$i', '44100',
    ]);
  }
  return args;
}

// === HDR+SDR dual ladder (3.2.0) =============================================
// Produce an HDR (HEVC/PQ) ladder AND a tone-mapped SDR ladder in one pass, so
// Apple HLS clients that reject HDR still get an SDR rung. HLS always operates
// on CPU frames, so tone-mapping is done on the CPU with libzimg (zscale) +
// the Hable operator - this drives both NVENC and libx26x SDR encoding.

/// CPU HDR->SDR tone-map chain (PQ/BT.2020 -> BT.709). Applied once to the SDR
/// source split, then fanned out to the SDR rungs.
const _cpuTonemap =
    'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
    'tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p';

/// Build the dual-ladder video filter graph, per-rung video encoder args, and
/// per-rung variant names. HDR rungs are the low output indices (0..H-1),
/// tone-mapped SDR rungs follow (H..H+S-1). Variant names carry an `hdr_`/`sdr_`
/// prefix so [promoteHlsMaster] can set per-variant VIDEO-RANGE.
({List<String> filter, List<String> videoArgs, List<String> names})
    _dualLadderVideo(
  List<Preset> hdrRes,
  List<Preset> sdrRes,
  VideoOutput output,
  InputColor inputColor, {
  required bool nvenc,
  required EncodeQuality quality,
  HdrMetadata? hdrMeta,
  VideoQuality? vq,
}) {
  final hdrSpec = _OutSpec.from(VideoOutput.h265Hdr, inputColor); // HEVC/10/HDR
  final sdrSpec = output.sdrIsHevc
      ? const _OutSpec(true, false, false)   // HEVC SDR, 8-bit
      : const _OutSpec(false, false, false); // H.264 SDR, 8-bit
  // The single (H.265) bitrate anchor maps to the SDR ladder's own codec tier
  // (H.264 SDR gets the proportionally higher AVC anchor); CRF is shared (its
  // per-codec cap is already handled in _rateCtl). See [sdrAnchorKbps].
  final sdrVq = (vq != null && !output.sdrIsHevc &&
                 vq.mode == VideoQualityMode.bitrate)
      ? VideoQuality(mode: vq.mode, crf: vq.crf, effort: vq.effort,
          bitrate4kKbps: sdrAnchorKbps(vq.bitrate4kKbps, output))
      : vq;
  final h = hdrRes.length, s = sdrRes.length;

  String scale(String inLbl, Preset r, String outLbl) =>
      '[$inLbl]scale=${r.width}:${r.height}'
      ':force_original_aspect_ratio=decrease:force_divisible_by=2[$outLbl]';

  final g = StringBuffer('[0:v]split=2[hdrsrc][sdrsrc];');
  g.write('[hdrsrc]split=$h${[for (var i = 0; i < h; i++) '[hin$i]'].join()};');
  for (var i = 0; i < h; i++) g.write('${scale('hin$i', hdrRes[i], 'hdr$i')};');
  g.write('[sdrsrc]$_cpuTonemap[sdrtm];');
  g.write('[sdrtm]split=$s${[for (var j = 0; j < s; j++) '[sin$j]'].join()};');
  for (var j = 0; j < s; j++) {
    g.write(scale('sin$j', sdrRes[j], 'sdr$j'));
    if (j < s - 1) g.write(';');
  }

  final videoArgs = <String>[];
  final names = <String>[];
  for (var i = 0; i < h; i++) {
    videoArgs.addAll([
      '-map', '[hdr$i]',
      ..._videoEncoderArgs(i, hdrRes[i], hdrSpec,
          nvenc: nvenc, gpuFrames: false, quality: quality, hdr: hdrMeta, vq: vq),
    ]);
    names.add('hdr_${hdrRes[i].height}p');
  }
  for (var j = 0; j < s; j++) {
    videoArgs.addAll([
      '-map', '[sdr$j]',
      ..._videoEncoderArgs(h + j, sdrRes[j], sdrSpec,
          nvenc: nvenc, gpuFrames: false, quality: quality, hdr: null, vq: sdrVq,
          sdrTags: true),
    ]);
    names.add('sdr_${sdrRes[j].height}p');
  }
  return (filter: ['-filter_complex', g.toString()], videoArgs: videoArgs, names: names);
}

/// var_stream_map for a dual ladder. Empty audio plan -> each variant muxes the
/// single AAC audio stream (v:i,a:i); otherwise all video variants reference the
/// shared audio rendition group.
String _hlsVarStreamMapDual(List<String> names, List<AudioSelection> kept) {
  final n = names.length;
  if (kept.isEmpty) {
    return [for (var i = 0; i < n; i++) 'v:$i,a:$i,name:${names[i]}'].join(' ');
  }
  const grp = 'aud';
  var defIdx = kept.indexWhere((a) => a.isDefault);
  if (defIdx < 0) defIdx = 0;
  return [
    for (var i = 0; i < n; i++) 'v:$i,agroup:$grp,name:${names[i]}',
    for (var i = 0; i < kept.length; i++)
      'a:$i,agroup:$grp'
          '${kept[i].language != null ? ',language:${kept[i].language}' : ''}'
          ',default:${i == defIdx ? 'yes' : 'no'}'
          ',name:a${i}_${kept[i].language ?? 'und'}',
  ].join(' ');
}

// HLS
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
  // written into segDir (they vanish / land in the CWD) - breaking playback and
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
          // MPEG-TS defaults muxpreload to 0.5s and muxdelay to 0.7s, which
          // stamp the initial PCR ahead of the first DTS (PCR preroll) and let
          // the muxer aggregate AAC PES packets. Both are considered TS-packaging
          // anomalies by some packagers/players. zero them so segments start clean.
          // Only meaningful for TS (H.264 SDR), since fMP4/HEVC segments carry no PCR.
          '-muxdelay', '0', '-muxpreload', '0',
        ];

  final common = <String>[
    '-f', 'hls',
    '-hls_time', '$segmentDuration',
    '-hls_playlist_type', 'vod',
    '-hls_flags', 'independent_segments',
    ...segArgs,
    '-master_pl_name', 'master.m3u8',
  ];

  // Dual-ladder (HDR+SDR) path: HEVC/PQ ladder + tone-mapped SDR ladder in one
  // pass. Uses fMP4 segments (segArgs already picks fMP4 since spec.hevc holds
  // for the HDR rungs; H.264 SDR rungs are valid in fMP4/CMAF too).
  if (output.hasSdrLadder) {
    final sdrRes = sdrLadderFor(resolutions, output);
    final dl = _dualLadderVideo(resolutions, sdrRes, output, inputColor,
        nvenc: nvenc, quality: quality, hdrMeta: hdrMeta, vq: videoQuality);
    final kept = audioPlan.where((s) => s.action != AudioAction.remove).toList();
    final audioArgs = <String>[];
    if (kept.isEmpty) {
      for (var i = 0; i < dl.names.length; i++) {
        audioArgs.addAll(['-map', '0:a:0?']);
      }
      for (var i = 0; i < dl.names.length; i++) {
        audioArgs.addAll(['-c:a:$i', 'aac', '-b:a:$i', '128k',
                          '-ac:a:$i', '2', '-ar:a:$i', '44100']);
      }
    } else {
      audioArgs.addAll(_audioPlanArgs(kept));
    }
    return [
      ffmpegPath(), '-y', '-i', input,
      '-sn', '-dn',
      ...dl.filter,
      ...dl.videoArgs,
      ...audioArgs,
      ...common,
      '-var_stream_map', _hlsVarStreamMapDual(dl.names, kept),
      '$segDir/${stem}_%v.m3u8',
    ];
  }

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

/// Friendly codec label for an audio rendition NAME (e.g. "AAC", "E-AC-3").
String _friendlyCodecLabel(String tag) => tag.startsWith('mp4a') ? 'AAC'
    : tag == 'ec-3' ? 'E-AC-3'
    : tag == 'ac-3' ? 'AC-3'
    : '';

/// Rewrite an #EXT-X-MEDIA:TYPE=AUDIO line: (1) NAME from ffmpeg's auto "audio_N"
/// to a friendly "<Language> <layout> (<codec>)" label (e.g. "English 5.1
/// (E-AC-3)") so the two same-layout tracks in different codec groups are
/// distinguishable, de-duplicated via [used] (appends " (2)", ...); (2) prefix
/// the rendition URI with the [stem] subdirectory so it matches where the audio
/// playlists actually live. Without (2) players load the video but fail to find
/// the audio -> video plays with NO sound.
String _friendlyAudioMediaLine(String line, Set<String> used, String stem,
    [String codecTag = '']) {
  final lang = RegExp(r'LANGUAGE="([^"]*)"').firstMatch(line)?.group(1);
  final ch   = RegExp(r'CHANNELS="([^"]*)"').firstMatch(line)?.group(1);
  final langName = (lang == null || lang.isEmpty || lang == 'und')
      ? '' : (_audioLangNames[lang] ?? lang.toUpperCase());
  final codec = _friendlyCodecLabel(codecTag);
  final parts = [langName, _channelLabel(ch), if (codec.isNotEmpty) '($codec)']
      .where((s) => s.isNotEmpty).toList();
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

String _basename(String p) => p.split('/').last;

/// Peak and average media bit rate (bps) of an HLS media playlist, measured from
/// its #EXTINF durations and the on-disk segment sizes. Returns null if the
/// playlist or its segments can't be read (callers then leave BANDWIDTH as-is).
Future<({int peak, int avg})?> _mediaBw(String playlistPath) async {
  final f = File(playlistPath);
  if (!await f.exists()) return null;
  final dir = f.parent.path;
  final sep = Platform.pathSeparator;
  final segs = <({int bytes, double dur})>[];
  double? dur;
  for (final line in await f.readAsLines()) {
    final t = line.trim();
    if (t.startsWith('#EXTINF:')) {
      dur = double.tryParse(RegExp(r'#EXTINF:([\d.]+)').firstMatch(t)?.group(1) ?? '');
    } else if (t.isNotEmpty && !t.startsWith('#') && dur != null && dur > 0) {
      final seg = File('$dir$sep${_basename(t)}');
      final sz = await seg.exists() ? await seg.length() : 0;
      if (sz > 0) segs.add((bytes: sz, dur: dur));
      dur = null;
    }
  }
  if (segs.isEmpty) return null;
  final totalBytes = segs.fold<int>(0, (a, s) => a + s.bytes);
  final totalDur   = segs.fold<double>(0.0, (a, s) => a + s.dur);
  // Robust peak: ignore segments much shorter than the median duration.
  // Keyframe/scene-boundary fragments (e.g. a 0.3s segment) spike size/duration
  // and would otherwise inflate BANDWIDTH far above the sustainable rate - even
  // inverting the ladder (a 468p rung reading higher than 720p). Fall back to the
  // overall max only if every segment is "short" (uniformly tiny).
  final durs   = segs.map((s) => s.dur).toList()..sort();
  final median = durs[durs.length ~/ 2];
  int peakOf(bool Function(double) keep) {
    var p = 0;
    for (final s in segs) {
      if (!keep(s.dur)) continue;
      final r = (s.bytes * 8 / s.dur).round();
      if (r > p) p = r;
    }
    return p;
  }
  var peak = peakOf((d) => d >= median * 0.5);
  if (peak == 0) peak = peakOf((_) => true);
  return (peak: peak, avg: (totalBytes * 8 / totalDur).round());
}

/// Rewrite BANDWIDTH / AVERAGE-BANDWIDTH on a STREAM-INF line. The lookbehind
/// keeps AVERAGE-BANDWIDTH from being matched by the plain BANDWIDTH pattern.
String _setBandwidth(String inf, int bandwidth, int average) {
  var s = inf.replaceFirst(RegExp(r'AVERAGE-BANDWIDTH=\d+'), 'AVERAGE-BANDWIDTH=$average');
  s = s.replaceFirst(RegExp(r'(?<!-)BANDWIDTH=\d+'), 'BANDWIDTH=$bandwidth');
  return s;
}

/// Rewrite the audio codec token in a STREAM-INF CODECS attribute, keeping the
/// video token(s) and replacing any audio token with [audioTag].
String _replaceAudioCodecTag(String inf, String audioTag) =>
    inf.replaceFirstMapped(RegExp(r'CODECS="([^"]*)"'), (m) {
      final video = m.group(1)!.split(',').map((t) => t.trim()).where((t) =>
          RegExp(r'^(avc1|avc3|hvc1|hev1|dvh1|dvhe)', caseSensitive: false).hasMatch(t));
      return 'CODECS="${[...video, audioTag].join(',')}"';
    });

/// Split a single mixed-codec audio rendition group into one group per codec and
/// duplicate every video variant across the groups (with a codec-correct CODECS
/// string per copy). [audioCodecs] is the RFC 6381 tag for each audio rendition
/// in the order the #EXT-X-MEDIA:TYPE=AUDIO lines appear. Returns the inputs
/// unchanged when there is nothing to split (0 or 1 distinct codec) or the
/// counts don't line up (safety).
int? _attrInt(String s, RegExp re) => int.tryParse(re.firstMatch(s)?.group(1) ?? '');

({List<String> header, List<({String inf, String uri})> variants})
    _regroupAudioByCodec(List<String> header,
        List<({String inf, String uri})> variants, List<String> audioCodecs,
        {List<({int peak, int avg})?> audioBw = const [],
         Map<String, ({int peak, int avg})> videoBw = const {},
         bool aacDefault = false}) {
  final audioIdx = [
    for (var i = 0; i < header.length; i++)
      if (header[i].trimLeft().startsWith('#EXT-X-MEDIA:TYPE=AUDIO')) i,
  ];
  if (audioIdx.isEmpty ||
      audioIdx.length != audioCodecs.length ||
      audioCodecs.toSet().length < 2) {
    return (header: header, variants: variants);
  }

  String gid(String tag) {
    final slug = tag.startsWith('mp4a') ? 'aac'
               : tag == 'ec-3' ? 'ec3'
               : tag == 'ac-3' ? 'ac3'
               : tag.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return 'aud_$slug';
  }

  // Which rendition is DEFAULT=YES in each group:
  //  - [aacDefault] (the H.265-HDR + H.264-SDR mode): AAC is the SOLE default, so
  //    browsers (hls.js) - which auto-load the DEFAULT rendition and can't decode
  //    ec-3/ac-3 - land on a playable track instead of silent video.
  //  - otherwise: respect the user's choice - keep the rendition that was already
  //    DEFAULT=YES within its group, falling back to the first in the group.
  // Every rendition is AUTOSELECT=YES so capable native players can still pick a
  // non-default surround rendition by capability.
  final hasAac = audioCodecs.any((t) => t.startsWith('mp4a'));
  final groupDefaultK = <String, int>{};
  if (aacDefault && hasAac) {
    for (var k = 0; k < audioIdx.length; k++) {
      if (audioCodecs[k].startsWith('mp4a')) { groupDefaultK[gid(audioCodecs[k])] = k; break; }
    }
  } else {
    for (var k = 0; k < audioIdx.length; k++) {
      final g = gid(audioCodecs[k]);
      if (header[audioIdx[k]].contains('DEFAULT=YES') && !groupDefaultK.containsKey(g)) {
        groupDefaultK[g] = k;
      }
    }
    for (var k = 0; k < audioIdx.length; k++) {
      groupDefaultK.putIfAbsent(gid(audioCodecs[k]), () => k);
    }
  }

  final newHeader = List<String>.from(header);
  final groups = <String>[];           // distinct group ids, first-seen order
  final groupCodec = <String, String>{};
  final groupBw = <String, ({int peak, int avg})>{}; // worst-case audio per group
  for (var k = 0; k < audioIdx.length; k++) {
    final tag = audioCodecs[k];
    final g = gid(tag);
    if (!groups.contains(g)) { groups.add(g); groupCodec[g] = tag; }
    // Track the highest-bitrate rendition in each group (a variant may play any
    // rendition of its group, so BANDWIDTH should reflect the worst case).
    final ab = k < audioBw.length ? audioBw[k] : null;
    if (ab != null) {
      final cur = groupBw[g];
      groupBw[g] = cur == null
          ? ab
          : (peak: ab.peak > cur.peak ? ab.peak : cur.peak,
             avg:  ab.avg  > cur.avg  ? ab.avg  : cur.avg);
    }
    var l = newHeader[audioIdx[k]]
        .replaceFirst(RegExp(r'GROUP-ID="[^"]*"'), 'GROUP-ID="$g"');
    final def = groupDefaultK[g] == k ? 'YES' : 'NO';
    l = l.contains('DEFAULT=')
        ? l.replaceFirst(RegExp(r'DEFAULT=(YES|NO)'), 'DEFAULT=$def')
        : '$l,DEFAULT=$def';
    // AUTOSELECT=YES on every rendition (required when DEFAULT=YES; lets capable
    // players auto-select the non-default surround renditions).
    l = l.contains('AUTOSELECT=')
        ? l.replaceFirst(RegExp(r'AUTOSELECT=(YES|NO)'), 'AUTOSELECT=YES')
        : '$l,AUTOSELECT=YES';
    newHeader[audioIdx[k]] = l;
  }

  final bwRe  = RegExp(r'(?<!-)BANDWIDTH=(\d+)');
  final avgRe = RegExp(r'AVERAGE-BANDWIDTH=(\d+)');
  final newVariants = <({String inf, String uri})>[];
  for (final v in variants) {
    // Video component: the measured robust peak/avg (short keyframe-boundary
    // segments filtered out) when available, else ffmpeg's declared value.
    // Each group then ADDS its own audio rate, so the AAC copy and the E-AC-3
    // copy carry honestly different, resolution-ordered numbers.
    final mv   = videoBw[_basename(v.uri)];
    final vBw  = mv?.peak ?? _attrInt(v.inf, bwRe);
    final vAvg = mv?.avg  ?? _attrInt(v.inf, avgRe);
    for (final g in groups) {
      var inf = _replaceAudioCodecTag(
          v.inf.replaceFirst(RegExp(r'AUDIO="[^"]*"'), 'AUDIO="$g"'),
          groupCodec[g]!);
      final ab = groupBw[g];
      if (vBw != null && ab != null) {
        inf = _setBandwidth(inf, vBw + ab.peak, (vAvg ?? vBw) + ab.avg);
      }
      newVariants.add((inf: inf, uri: v.uri));
    }
  }
  return (header: newHeader, variants: newVariants);
}

Future<void> promoteHlsMaster({
  required String input,
  required String outputDir,
  String videoRange = 'SDR',   // 'SDR' | 'PQ' (HDR10) | 'HLG'
  String frameRate  = '',      // e.g. '23.976'; empty = omit
  String? stemOverride,        // segment dir + URIs (safe form of output name)
  String masterName = '',      // master filename (pretty form of output name)
  List<String> audioCodecs = const [],  // RFC6381 tag per audio rendition, in
                                        // stream order (drives per-codec groups)
  bool aacDefault = false,     // force AAC as the sole default audio (mixed
                               // H.265-HDR + H.264-SDR mode -> browser playback)
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
  var audioSeen = 0;                   // audio rendition index -> audioCodecs
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
      // Dual-ladder variants carry an hdr_/sdr_ marker in their playlist name;
      // set VIDEO-RANGE per variant (PQ for HDR rungs, SDR for tone-mapped
      // rungs). Single-ladder variants have no marker -> use the passed default.
      final vr = uri.contains('_sdr_') ? 'SDR'
               : uri.contains('_hdr_') ? 'PQ'
               : videoRange;
      variants.add((inf: _augmentStreamInf(pendingInf!, vr, frameRate), uri: uri));
      pendingInf = null;
    } else if (!inVariants) {
      // Replace ffmpeg's auto "audio_N" NAME with a friendly language+layout+codec
      // label (e.g. "English 5.1 (E-AC-3)"), de-duplicated.
      if (t.startsWith('#EXT-X-MEDIA:TYPE=AUDIO')) {
        final codec = audioSeen < audioCodecs.length ? audioCodecs[audioSeen] : '';
        header.add(_friendlyAudioMediaLine(line, usedAudioNames, stem, codec));
        audioSeen++;
      } else {
        header.add(line);
      }
    }
  }

  // Split a single mixed-codec audio group into one group per codec, and
  // duplicate each video variant across the groups (correct CODECS per copy).
  // hls.js (browsers) filters out any variant whose CODECS contains a codec MSE
  // can't decode; conflating aac/ac-3/ec-3 in one group made every variant
  // advertise ec-3 -> all filtered -> nothing plays. Per-codec groups let the
  // H.264/AAC variants advertise a browser-playable codec. No-op for 0/1 codec.
  // Measure each variant's video and each audio rendition's real bit rate from
  // their segments, so per-codec variant BANDWIDTH is honest: a robust video
  // peak (short keyframe-boundary segments filtered out, see _mediaBw) plus the
  // specific audio codec's rate. Best-effort - if segments are unreadable (e.g.
  // in unit tests) the caller falls back to ffmpeg's declared value.
  final audioBw = <({int peak, int avg})?>[];
  final videoBw = <String, ({int peak, int avg})>{};
  if (audioCodecs.length >= 2 && audioCodecs.toSet().length >= 2) {
    for (final l in header) {
      if (l.trimLeft().startsWith('#EXT-X-MEDIA:TYPE=AUDIO')) {
        final u = RegExp(r'URI="([^"]+)"').firstMatch(l)?.group(1);
        audioBw.add(u == null ? null : await _mediaBw('$segDir$sep${_basename(u)}'));
      }
    }
    for (final v in variants) {
      final b = _basename(v.uri);
      if (!videoBw.containsKey(b)) {
        final m = await _mediaBw('$segDir$sep$b');
        if (m != null) videoBw[b] = m;
      }
    }
  }

  final rg = _regroupAudioByCodec(header, variants, audioCodecs,
      audioBw: audioBw, videoBw: videoBw, aacDefault: aacDefault);
  final outHeader = rg.header;
  final outVariants = rg.variants;

  // Sort by BANDWIDTH= value ascending
  outVariants.sort((a, b) {
    final bwA = RegExp(r'BANDWIDTH=(\d+)').firstMatch(a.inf)?.group(1);
    final bwB = RegExp(r'BANDWIDTH=(\d+)').firstMatch(b.inf)?.group(1);
    final ia  = int.tryParse(bwA ?? '') ?? 0;
    final ib  = int.tryParse(bwB ?? '') ?? 0;
    return ia.compareTo(ib);
  });

  // Apple requires EXT-X-INDEPENDENT-SEGMENTS in the master (our segments are
  // encoded independent via -hls_flags independent_segments).
  if (!outHeader.any((l) => l.contains('EXT-X-INDEPENDENT-SEGMENTS'))) {
    final vIdx = outHeader.indexWhere((l) => l.startsWith('#EXT-X-VERSION'));
    outHeader.insert(vIdx >= 0 ? vIdx + 1 : outHeader.length, '#EXT-X-INDEPENDENT-SEGMENTS');
  }

  final output = [
    ...outHeader,
    for (final v in outVariants) ...[v.inf, v.uri],
    '',
  ];

  await dstMaster.writeAsString(output.join('\n'));
  await srcMaster.delete();
}

// DASH
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
    // NVENC path: per-stream mapping with scale_cuda + setsar
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
          '-ac:a:$i', '2', '-ar:a:$i', '44100',
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
    // CPU path: filter graph with split -> scale
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
        '-c:a:0', 'aac', '-b:a:0', resolutions.first.audioBitrate,
        '-ac:a:0', '2', '-ar:a:0', '44100',
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
