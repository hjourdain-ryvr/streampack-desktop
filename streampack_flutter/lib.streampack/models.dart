import 'dart:convert';
import 'dart:math' as math;

// ── Preset ────────────────────────────────────────────────────────────────────

class Preset {
  final String label;
  final int width;
  final int height;
  final String videoBitrate;
  final String audioBitrate;
  final int bandwidth;

  const Preset({
    required this.label,
    required this.width,
    required this.height,
    required this.videoBitrate,
    required this.audioBitrate,
    required this.bandwidth,
  });
}

const kPresets = <Preset>[
  Preset(label: '2160p (4K)',    width: 3840, height: 2160, videoBitrate: '15000k', audioBitrate: '192k', bandwidth: 15360000),
  Preset(label: '1080p (Full HD)',width: 1920, height: 1080, videoBitrate:  '5000k', audioBitrate: '192k', bandwidth:  5376000),
  Preset(label: '720p (HD)',     width: 1280, height:  720, videoBitrate:  '2800k', audioBitrate: '128k', bandwidth:  2969600),
  Preset(label: '480p (SD)',     width:  832, height:  468, videoBitrate:  '1400k', audioBitrate: '128k', bandwidth:  1548800),
  Preset(label: '360p (Low)',    width:  640, height:  360, videoBitrate:   '800k', audioBitrate:  '96k', bandwidth:   917504),
  Preset(label: '240p (Mobile)', width:  416, height:  234, videoBitrate:   '400k', audioBitrate:  '64k', bandwidth:   475136),
];

// ── Format ────────────────────────────────────────────────────────────────────

enum EncodeFormat { hls, dash, both }

// ── Quality ───────────────────────────────────────────────────────────────────

enum EncodeQuality {
  balanced,  // NVENC: p4 (~317 fps @ 1080p) — libx264: medium
  high,      // NVENC: p6 (~235 fps @ 1080p) — libx264: slow
}

extension EncodeQualityLabel on EncodeQuality {
  String get label => switch (this) {
    EncodeQuality.balanced => 'Balanced',
    EncodeQuality.high     => 'High',
  };
  String get nvencPreset => switch (this) {
    EncodeQuality.balanced => 'p4',
    EncodeQuality.high     => 'p6',
  };
  String get x264Preset => switch (this) {
    EncodeQuality.balanced => 'medium',
    EncodeQuality.high     => 'slow',
  };
}

// ── Advanced video quality (3.0.0) ──────────────────────────────────────────
// Basic encodes leave Job.videoQuality null -> the fixed per-preset bitrate
// ladder is used (legacy 2.0.0 behaviour, unchanged). The Advanced Video
// sub-tab sets an explicit override: either a target bitrate (a 4K anchor that
// is scaled down per rendition) or a CRF/CQ quality level (same value on every
// rendition).
enum VideoQualityMode { bitrate, crf }

/// Encoder quality/effort (higher = better quality, slower). Curated set, never
/// below p4 (Balanced) since faster presets hurt quality too much. Maps to NVENC
/// p4/p5/p6 and the libx26x equivalents. Used only by the Advanced video tab;
/// Basic uses EncodeQuality.
enum VideoEffort { balanced, high, best }

extension VideoEffortPresets on VideoEffort {
  String get nvencPreset => switch (this) {
    VideoEffort.balanced => 'p4',
    VideoEffort.high     => 'p5',
    VideoEffort.best     => 'p6',
  };
  String get cpuPreset => switch (this) {  // libx264 / libx265
    VideoEffort.balanced => 'medium',
    VideoEffort.high     => 'slow',
    VideoEffort.best     => 'slower',
  };
}

/// Codec-appropriate 4K bitrate anchors (kbps) and CRF tiers, offered by the UI.
/// H.264 needs ~1.8x the bits of H.265 for similar quality; CRF numbers are
/// codec-native (same scale here, picked per job).
const kHevcBitrateAnchorsKbps = <int>[25000, 20000, 15000, 10000];
const kAvcBitrateAnchorsKbps  = <int>[40000, 32000, 24000, 16000];
const kHevcDefaultAnchorKbps  = 15000;
const kAvcDefaultAnchorKbps   = 24000;
const kCrfTiers               = <int>[18, 20, 22];
const kDefaultCrf             = 22;

/// Per-rendition target bitrate (kbps) from a 4K anchor: scale by pixel count to
/// the 0.75 power (+15% for HDR). Shared by the encoder and the UI ladder preview.
int scaledVideoBitrateKbps(int anchor4kKbps, int width, int height, {bool hdr = false}) {
  final ratio = (width * height) / (3840 * 2160);
  var kbps = anchor4kKbps * math.pow(ratio, 0.75);
  if (hdr) kbps *= 1.15;
  return kbps.round();
}

class VideoQuality {
  final VideoQualityMode mode;
  final int bitrate4kKbps;  // chosen 4K anchor (kbps), used in bitrate mode
  final int crf;            // chosen CRF/CQ value, used in crf mode
  final VideoEffort effort; // encoder preset (speed vs compression)

  const VideoQuality({
    this.mode          = VideoQualityMode.bitrate,
    this.bitrate4kKbps = kHevcDefaultAnchorKbps,
    this.crf           = kDefaultCrf,
    this.effort        = VideoEffort.balanced,
  });
}

// ── Video output codec / range ──────────────────────────────────────────────
//
// User-selectable output. H.264 is always 8-bit SDR (10-bit SDR sources are
// reduced 10→8 for free; HDR sources can't target H.264). H.265 preserves the
// input's bit-depth, and H.265 (HDR) additionally preserves the HDR signal.

enum VideoOutput { h264Sdr, h265Sdr, h265Hdr }

extension VideoOutputInfo on VideoOutput {
  String get label => switch (this) {
    VideoOutput.h264Sdr => 'H.264 (SDR)',
    VideoOutput.h265Sdr => 'H.265 (SDR)',
    VideoOutput.h265Hdr => 'H.265 (HDR)',
  };
  bool get isHevc => this != VideoOutput.h264Sdr;
  bool get isHdr  => this == VideoOutput.h265Hdr;
}

// ── Input colour classification (from ffprobe) ──────────────────────────────

enum InputColor {
  sdr8, sdr10, hdr;

  /// Classify from ffprobe pix_fmt + color_transfer.
  static InputColor classify({required String? pixFmt, required String? colorTransfer}) {
    final isHdr = colorTransfer == 'smpte2084' || colorTransfer == 'arib-std-b67';
    if (isHdr) return InputColor.hdr;
    final tenBit = (pixFmt ?? '').contains('10') || (pixFmt ?? '').contains('p010');
    return tenBit ? InputColor.sdr10 : InputColor.sdr8;
  }
}

extension InputColorInfo on InputColor {
  bool get is10bit => this != InputColor.sdr8;
  bool get isHdr   => this == InputColor.hdr;

  /// Outputs offered for this input (others are greyed out in the UI).
  /// HDR→SDR (tone-mapping) is intentionally not supported, so HDR inputs
  /// only offer H.265 (HDR). SDR inputs offer both H.264 and H.265 — the free
  /// 10→8 reduction keeps H.264 available for 10-bit SDR.
  Set<VideoOutput> get validOutputs => switch (this) {
    InputColor.sdr8  => {VideoOutput.h264Sdr, VideoOutput.h265Sdr},
    InputColor.sdr10 => {VideoOutput.h264Sdr, VideoOutput.h265Sdr},
    InputColor.hdr   => {VideoOutput.h265Hdr},
  };

  VideoOutput get defaultOutput =>
      this == InputColor.hdr ? VideoOutput.h265Hdr : VideoOutput.h264Sdr;
}

/// HDR10 static metadata extracted from the source, formatted for libx265.
class HdrMetadata {
  /// e.g. "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)"
  final String? masterDisplay;
  /// e.g. "1000,400" (MaxCLL,MaxFALL)
  final String? maxCll;
  const HdrMetadata({this.masterDisplay, this.maxCll});

  bool get isEmpty => masterDisplay == null && maxCll == null;
}

// === Source media streams (3.0.0 Advanced tab) ===============================
// Read-only description of what a source file contains, as probed by ffprobe.
// Used by the Advanced tab to list/select tracks. Stream selection/transform
// lives in separate models (added with the Advanced-tab UI).

class AudioTrack {
  final int index;             // absolute stream index in the source
  final int order;             // 0-based audio order (maps to 0:a:<order>)
  final String codec;          // dts, ac3, eac3, aac, truehd, ...
  final String? profile;       // e.g. "DTS-HD MA", "DTS" (distinguishes variants)
  final int channels;          // 6, 2, ...
  final String? channelLayout; // "5.1(side)", "stereo", ...
  final String? language;      // ISO code, e.g. "eng"
  final String? title;
  final bool isDefault;        // source disposition default flag
  const AudioTrack({
    required this.index, required this.order, required this.codec,
    required this.channels, this.profile, this.channelLayout,
    this.language, this.title, this.isDefault = false,
  });

  /// Display codec name, preferring the meaningful profile (DTS-HD MA vs DTS).
  String get codecLabel =>
      (profile != null && profile != 'unknown' && profile!.isNotEmpty)
          ? profile!
          : codec.toUpperCase();

  // AC-3 / E-AC-3 stream-copy cleanly into HLS and DASH. DTS is target-dependent
  // (DTS-capable players/STBs only); TrueHD / DTS-HD MA are not streamable.
  bool get canPassthrough => codec == 'ac3' || codec == 'eac3';
}

class SubtitleTrack {
  final int index;
  final int order;             // 0-based subtitle order (0:s:<order>)
  final String codec;          // hdmv_pgs_subtitle, subrip, mov_text, ass, ...
  final String? language;
  final String? title;
  const SubtitleTrack({
    required this.index, required this.order, required this.codec,
    this.language, this.title,
  });

  // Image-based subs (PGS / VobSub) cannot be muxed as text; only text subs
  // (subrip/mov_text/ass) convert to WebVTT. (Subtitle handling is post-3.0.0;
  // 3.0.0 only lists these read-only.)
  bool get isImageBased =>
      codec == 'hdmv_pgs_subtitle' || codec == 'dvd_subtitle' || codec == 'dvb_subtitle';
}

class MediaStreams {
  final InputColor color;
  final HdrMetadata? hdr;
  final List<AudioTrack> audio;
  final List<SubtitleTrack> subtitles;
  const MediaStreams({
    required this.color, this.hdr,
    this.audio = const [], this.subtitles = const [],
  });
}

// === Stream selection (3.0.0 Advanced tab) ==================================
// How the user wants each source AUDIO track handled in the output. Built from
// MediaStreams; the defaultFor() factory reproduces 2.0.0 behaviour (transcode
// to AAC stereo, first track default). Subtitles are read-only in 3.0.0 and so
// have no selection model yet.

enum AudioAction { transcode, passthrough, remove }
enum AudioTarget { aac, ac3, eac3 }          // transcode target codec
enum AudioChannelMode { stereo, source }     // downmix to stereo vs preserve source layout

extension AudioTargetName on AudioTarget {
  // ffmpeg encoder name for the chosen target.
  String get encoder => switch (this) {
    AudioTarget.aac  => 'aac',
    AudioTarget.ac3  => 'ac3',
    AudioTarget.eac3 => 'eac3',
  };
}

class AudioSelection {
  final int sourceOrder;       // source audio order -> 0:a:<sourceOrder>
  AudioAction action;
  AudioTarget target;          // used when action == transcode
  AudioChannelMode channels;   // used when action == transcode
  String? language;            // manifest language tag (defaults from source)
  bool isDefault;              // default audio rendition flag

  AudioSelection({
    required this.sourceOrder,
    this.action   = AudioAction.transcode,
    this.target   = AudioTarget.aac,
    this.channels = AudioChannelMode.stereo,
    this.language,
    this.isDefault = false,
  });

  // 2.0.0-equivalent default: transcode to AAC stereo; first track is default.
  // Passthrough-capable tracks still default to transcode - the user opts into
  // passthrough explicitly in the Advanced tab.
  factory AudioSelection.defaultFor(AudioTrack t) => AudioSelection(
    sourceOrder: t.order,
    action: AudioAction.transcode,
    target: AudioTarget.aac,
    channels: AudioChannelMode.stereo,
    language: t.language,
    isDefault: t.isDefault, // mirror the source default; corrected to one below
  );
}

// === Job ====================================================================

enum JobStatus { queued, running, validating, done, error, cancelled }

class Job {
  final String id;
  final String input;
  final String hlsOutputDir;
  final String dashOutputDir;
  final EncodeFormat format;
  final List<Preset> resolutions;
  final int segmentDuration;
  final EncodeQuality quality;
  final VideoOutput output;       // chosen video codec / range

  InputColor inputColor;          // probed from source before encode
  HdrMetadata? hdrMeta;           // HDR10 static metadata (HDR sources only)
  List<AudioSelection> audioPlan; // per-track audio plan; empty = 2.0.0 default
  VideoQuality? videoQuality;     // Advanced override; null = preset ladder

  JobStatus status;
  double progress;        // 0.0 – 1.0
  String currentPass;     // "hls" | "dash" | ""
  String? error;
  String? skippedRenditions;      // labels of renditions skipped due to upscale
  List<Preset> activeResolutions; // resolutions actually used (after upscale filter)
  ValidationResult? validation;
  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? finishedAt;

  Job({
    required this.id,
    required this.input,
    required this.hlsOutputDir,
    required this.dashOutputDir,
    required this.format,
    required this.resolutions,
    required this.segmentDuration,
    required this.quality,
    this.output = VideoOutput.h264Sdr,
    this.inputColor = InputColor.sdr8,
    this.hdrMeta,
    this.audioPlan = const [],
    this.videoQuality,
  })  : status = JobStatus.queued,
        progress = 0,
        currentPass = '',
        activeResolutions = List.of(resolutions), // initially all; filtered before encode
        createdAt = DateTime.now();

  String get inputBasename => input.split(RegExp(r'[/\\]')).last;

  String get elapsedLabel {
    final ref = startedAt ?? createdAt;
    final end = finishedAt ?? DateTime.now();
    final s = end.difference(ref).inSeconds;
    if (s < 60) return '${s}s';
    return '${s ~/ 60}m ${s % 60}s';
  }

  /// Estimated time remaining, from elapsed time and progress. Null unless
  /// running with enough progress to extrapolate.
  String? get etaLabel {
    if (status != JobStatus.running || progress < 0.02) return null;
    final ref = startedAt ?? createdAt;
    final elapsed = DateTime.now().difference(ref).inSeconds;
    if (elapsed <= 0) return null;
    final remaining = (elapsed / progress - elapsed).round();
    if (remaining <= 0) return null;
    if (remaining < 60) return '${remaining}s';
    return '${remaining ~/ 60}m ${remaining % 60}s';
  }
}

// ── Validation ────────────────────────────────────────────────────────────────

enum CheckLevel { ok, warn, fail }

class CheckItem {
  final CheckLevel level;
  final String code;
  final String message;
  const CheckItem(this.level, this.code, this.message);
}

class VariantResult {
  final String uri;
  final String resolution;
  final int? declaredBandwidth;
  final List<CheckItem> checks;
  const VariantResult({
    required this.uri,
    required this.resolution,
    this.declaredBandwidth,
    required this.checks,
  });
}

enum ValidationSummary { pass, warn, fail }

class ValidationResult {
  final ValidationSummary summary;
  final List<CheckItem> checks;
  final List<VariantResult> variants;

  /// For "both" format jobs this holds HLS and DASH results separately.
  final ValidationResult? hls;
  final ValidationResult? dash;

  const ValidationResult({
    required this.summary,
    required this.checks,
    required this.variants,
    this.hls,
    this.dash,
  });

  /// True when this is a combined result holding hls + dash sub-results.
  bool get isCombined => hls != null || dash != null;
}
