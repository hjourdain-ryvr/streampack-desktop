import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'models.dart';
import 'encoder.dart';
import 'validator.dart';
import 'ffmpeg.dart';
class JobRunner extends ChangeNotifier {
  final List<Job> jobs = [];
  final Map<String, Process> _processes = {};

  // ── Submit ────────────────────────────────────────────────────────────────

  void submit(Job job) {
    jobs.insert(0, job);
    notifyListeners();
    unawaited(_runJob(job));
  }

  // ── Remove ────────────────────────────────────────────────────────────────

  void remove(Job job) {
    jobs.remove(job);
    notifyListeners();
  }

  // ── Cancel ────────────────────────────────────────────────────────────────

  void cancel(Job job) {
    _processes[job.id]?.kill();
    _processes.remove(job.id);
    job.status = JobStatus.cancelled;
    notifyListeners();
  }

  void cancelAll() {
    for (final job in jobs) {
      if (job.status == JobStatus.queued || job.status == JobStatus.running) {
        _processes[job.id]?.kill();
        _processes.remove(job.id);
        job.status = JobStatus.cancelled;
      }
    }
    notifyListeners();
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  /// Notify from a background context. Uses a micro-task so it never fires
  /// mid-build, but does NOT depend on Flutter rendering frames — avoids the
  /// stuck-pending-flag problem caused by addPostFrameCallback when Flutter
  /// is idle during a long encode.
  void _notify() {
    Future.microtask(notifyListeners);
  }

  // ── Core runner ───────────────────────────────────────────────────────────

  Future<void> _runJob(Job job) async {
    try {
      await _runJobInner(job);
    } catch (e, stack) {
      job.status     = JobStatus.error;
      job.error      = 'Unexpected error: $e';
      job.finishedAt = DateTime.now();
      _notify();
      debugPrint('JobRunner unhandled exception: $e\n$stack');
    }
  }

  Future<void> _runJobInner(Job job) async {
    job.status    = JobStatus.running;
    job.startedAt = DateTime.now();
    _notify();

    // Probe source for duration AND dimensions
    double durationS  = 0;
    int    srcWidth   = 0;
    int    srcHeight  = 0;
    try {
      final probe = await Process.run(ffprobePath(), [
        '-v', 'error',
        '-show_entries', 'format=duration:stream=width,height',
        '-select_streams', 'v:0',
        '-of', 'json', job.input,
      ]);
      if (probe.exitCode == 0) {
        final json = probe.stdout as String;
        // Parse duration from format section
        final durMatch = RegExp(r'"duration"\s*:\s*"([\d.]+)"').firstMatch(json);
        durationS = double.tryParse(durMatch?.group(1) ?? '') ?? 0;
        // Parse source dimensions from first video stream
        final wMatch = RegExp(r'"width"\s*:\s*(\d+)').firstMatch(json);
        final hMatch = RegExp(r'"height"\s*:\s*(\d+)').firstMatch(json);
        srcWidth  = int.tryParse(wMatch?.group(1) ?? '') ?? 0;
        srcHeight = int.tryParse(hMatch?.group(1) ?? '') ?? 0;
      }
    } catch (_) {}

    // Filter out renditions that would require upscaling.
    // Upscaling wastes encode time and produces worse quality than
    // the player scaling up a lower-resolution stream itself.
    List<Preset> resolutions = job.resolutions;
    if (srcWidth > 0 && srcHeight > 0) {
      // Filter by height only — height is the canonical streaming dimension.
      // The scale filter handles width via force_original_aspect_ratio=decrease.
      final filtered = resolutions.where((r) => r.height <= srcHeight).toList();
      if (filtered.isEmpty) {
        // All requested renditions are larger than source — use source as-is.
        // Keep the lowest requested rendition and let ffmpeg scale down to source.
        filtered.add(resolutions.last);
      }
      if (filtered.length < resolutions.length) {
        final skipped = resolutions
            .where((r) => !filtered.contains(r))
            .map((r) => r.label)
            .join(', ');
        job.skippedRenditions = skipped;
        resolutions = filtered;
        _notify();
      }
    }
    // Replace job resolutions with filtered list for this encode
    job.activeResolutions = resolutions;


    // Detect NVENC once per job (cached globally after first check)
    final useNvenc = await nvencAvailable();
    if (useNvenc) {
      debugPrint('[job] NVENC available — using h264_nvenc');
    }

    final passes = switch (job.format) {
      EncodeFormat.hls  => ['hls'],
      EncodeFormat.dash => ['dash'],
      EncodeFormat.both => ['hls', 'dash'],
    };

    for (final pass in passes) {
      job.currentPass = pass;
      _notify();

      final outDir = pass == 'dash' ? job.dashOutputDir : job.hlsOutputDir;
      final stem   = sanitiseStem(job.input);
      final segDir = Directory('$outDir${Platform.pathSeparator}$stem');

      try {
        await segDir.create(recursive: true);
      } on PathAccessException {
        job.status     = JobStatus.error;
        job.error      = 'Permission denied creating output directory:\n'
                         '${segDir.path}\n'
                         'Check that the directory exists and is writable.';
        job.finishedAt = DateTime.now();
        _notify();
        return;
      } catch (e) {
        job.status     = JobStatus.error;
        job.error      = 'Could not create output directory:\n${segDir.path}\n$e';
        job.finishedAt = DateTime.now();
        _notify();
        return;
      }

      final cmd = pass == 'hls'
          ? buildHlsCmd(
              input: job.input, outputDir: outDir,
              resolutions: job.activeResolutions,
              segmentDuration: job.segmentDuration,
              nvenc: useNvenc,
              quality: job.quality)
          : buildDashCmd(
              input: job.input, outputDir: outDir,
              resolutions: job.activeResolutions,
              segmentDuration: job.segmentDuration,
              nvenc: useNvenc,
              quality: job.quality);

      final success = await _runPass(
        job: job, cmd: cmd, pass: pass,
        durationS: durationS,
        passIndex: passes.indexOf(pass),
        totalPasses: passes.length,
      );
      if (!success) return;
    }

    // ── Promote and validate ───────────────────────────────────────────────
    job.status = JobStatus.validating;
    _notify();

    ValidationResult? hlsResult;
    ValidationResult? dashResult;

    if (job.format == EncodeFormat.hls || job.format == EncodeFormat.both) {
      try {
        await promoteHlsMaster(input: job.input, outputDir: job.hlsOutputDir);
        final stem = sanitiseStem(job.input);
        hlsResult = await validateM3u8(
            '${job.hlsOutputDir}${Platform.pathSeparator}$stem.m3u8');
      } catch (e) {
        job.status = JobStatus.error;
        job.error  = 'Failed to promote HLS master playlist: $e';
        _notify();
        return;
      }
    }

    if (job.format == EncodeFormat.dash || job.format == EncodeFormat.both) {
      try {
        await promoteDashManifest(input: job.input, outputDir: job.dashOutputDir);
        final stem = sanitiseStem(job.input);
        dashResult = await validateMpd(
            '${job.dashOutputDir}${Platform.pathSeparator}$stem.mpd');
      } catch (e) {
        job.status = JobStatus.error;
        job.error  = 'Failed to promote DASH manifest: $e';
        _notify();
        return;
      }
    }

    job.validation = job.format == EncodeFormat.both
        ? ValidationResult(
            summary: _combineSummary([hlsResult!.summary, dashResult!.summary]),
            checks: [], variants: [],
            hls: hlsResult, dash: dashResult)
        : (hlsResult ?? dashResult)!;

    job.status     = JobStatus.done;
    job.progress   = 1.0;
    job.finishedAt = DateTime.now();
    _notify();
  }

  Future<bool> _runPass({
    required Job job,
    required List<String> cmd,
    required String pass,
    required double durationS,
    required int passIndex,
    required int totalPasses,
  }) async {
    final process = await Process.start(cmd.first, cmd.skip(1).toList());
    _processes[job.id] = process;

    final timeRe  = RegExp(r'time=(\d+):(\d+):([\d.]+)');
    final errorRe = RegExp(
        r'(error|Error|invalid|Invalid|failed|Failed|No such|unable|Unable|cannot|Cannot|not found|Could not)',
        caseSensitive: false);
    final errorLines = <String>[];

    // Timer-driven UI updates every 500ms, completely independent of ffmpeg
    // stderr rate and Flutter's frame scheduler.
    final uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _notify();
    });

    process.stderr.transform(const SystemEncoding().decoder).listen((chunk) {
      for (final line in chunk.split('\n')) {
        final stripped = line.trim();
        if (stripped.isEmpty) continue;
        errorLines.add(stripped);

        final m = timeRe.firstMatch(line);
        if (m != null && durationS > 0) {
          final h   = int.parse(m.group(1)!);
          final mn  = int.parse(m.group(2)!);
          final s   = double.parse(m.group(3)!);
          final elapsed      = h * 3600 + mn * 60 + s;
          final passProgress = (elapsed / durationS).clamp(0.0, 0.99);
          job.progress = totalPasses == 1
              ? passProgress
              : passIndex / totalPasses + passProgress / totalPasses;
          // No notify here — the timer handles UI updates at a steady rate
        }
      }
    });

    final exitCode = await process.exitCode;
    uiTimer.cancel();
    _processes.remove(job.id);

    if (job.status == JobStatus.cancelled) return false;

    if (exitCode != 0) {
      final meaningful = errorLines.where(errorRe.hasMatch).toList();
      final detail = meaningful.isNotEmpty
          ? meaningful.take(8).join('\n')
          : errorLines.reversed.take(8).toList().reversed.join('\n');
      job.status     = JobStatus.error;
      job.error      = 'ffmpeg ($pass) exited with code $exitCode:\n$detail';
      job.finishedAt = DateTime.now();
      _notify();
      return false;
    }
    return true;
  }

  ValidationSummary _combineSummary(List<ValidationSummary> summaries) {
    if (summaries.contains(ValidationSummary.fail)) return ValidationSummary.fail;
    if (summaries.contains(ValidationSummary.warn)) return ValidationSummary.warn;
    return ValidationSummary.pass;
  }
}
