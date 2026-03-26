import 'dart:convert';

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

// ── Job ───────────────────────────────────────────────────────────────────────

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
