import 'dart:io';
import 'package:xml/xml.dart';
import 'models.dart';
import 'ffmpeg.dart';
import 'encoder.dart' show sanitiseStem;

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ── HLS validation ────────────────────────────────────────────────────────────

Future<ValidationResult> validateM3u8(String target) async {
  final checks   = <CheckItem>[];
  final variants = <VariantResult>[];

  void ok(String code, String msg)   => checks.add(CheckItem(CheckLevel.ok,   code, msg));
  void warn(String code, String msg) => checks.add(CheckItem(CheckLevel.warn, code, msg));
  void fail(String code, String msg) => checks.add(CheckItem(CheckLevel.fail, code, msg));

  ValidationResult done() {
    final levels = [
      ...checks.map((c) => c.level),
      ...variants.expand((v) => v.checks.map((c) => c.level)),
    ];
    final summary = levels.contains(CheckLevel.fail)
        ? ValidationSummary.fail
        : levels.contains(CheckLevel.warn)
            ? ValidationSummary.warn
            : ValidationSummary.pass;
    return ValidationResult(summary: summary, checks: checks, variants: variants);
  }

  // ── 1. Accessibility ────────────────────────────────────────────────────
  final isUrl = target.startsWith('http://') || target.startsWith('https://');
  if (!isUrl) {
    final f = File(target);
    if (!f.existsSync()) {
      fail('FILE_NOT_FOUND', 'File does not exist: $target');
      return done();
    }
    if (!target.toLowerCase().endsWith('.m3u8')) {
      warn('EXTENSION', 'File does not have a .m3u8 extension');
    }
    ok('FILE_EXISTS', 'File is accessible: ${f.uri.pathSegments.last}');
  } else {
    ok('URL_TARGET', 'Validating remote URL: $target');
  }

  // ── 2. Read ─────────────────────────────────────────────────────────────
  final text = await readPlaylist(target);
  if (text == null) {
    fail('READ_ERROR', 'Could not read playlist content');
    return done();
  }
  final lines = text.split('\n').map((l) => l.trimRight()).toList();

  if (lines.isEmpty || lines.first.trim() != '#EXTM3U') {
    fail('MISSING_EXTM3U', 'Playlist does not start with #EXTM3U');
  } else {
    ok('EXTM3U', 'Playlist starts with #EXTM3U');
  }

  // ── 3. Type detection ───────────────────────────────────────────────────
  final isMaster = lines.any((l) => l.startsWith('#EXT-X-STREAM-INF'));
  final isMedia  = lines.any((l) => l.startsWith('#EXTINF'));

  if (isMaster && isMedia) {
    warn('MIXED_PLAYLIST', 'Playlist mixes #EXT-X-STREAM-INF and #EXTINF');
  } else if (isMaster) {
    ok('PLAYLIST_TYPE', 'Detected master playlist');
  } else if (isMedia) {
    ok('PLAYLIST_TYPE', 'Detected media (variant) playlist');
  }

  final verLines = lines.where((l) => l.startsWith('#EXT-X-VERSION')).toList();
  if (verLines.isEmpty) {
    warn('NO_VERSION', '#EXT-X-VERSION tag is missing (recommended)');
  } else {
    ok('VERSION', 'HLS version declared: ${verLines.first.split(':').last.trim()}');
  }

  // ── 4. Master playlist ──────────────────────────────────────────────────
  if (isMaster) {
    final pairs = <(String, String)>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF')) {
        for (var j = i + 1; j < lines.length; j++) {
          if (lines[j].trim().isNotEmpty && !lines[j].startsWith('#')) {
            pairs.add((lines[i], lines[j].trim()));
            break;
          }
        }
      }
    }

    if (pairs.isEmpty) {
      fail('NO_VARIANTS', 'Master playlist has no variant streams');
    } else {
      ok('VARIANT_COUNT', 'Found ${pairs.length} variant stream(s)');
    }

    final bandwidths = <int>[];
    for (final (attrs, uri) in pairs) {
      final bwMatch  = RegExp(r'BANDWIDTH=(\d+)').firstMatch(attrs);
      final resMatch = RegExp(r'RESOLUTION=(\d+x\d+)').firstMatch(attrs);
      final bw  = bwMatch  != null ? int.parse(bwMatch.group(1)!)  : null;
      var   res = resMatch != null ? resMatch.group(1)! : '';

      if (bw == null) {
        warn('MISSING_BANDWIDTH', 'Variant $uri is missing BANDWIDTH');
      } else {
        bandwidths.add(bw);
      }
      if (resMatch == null) {
        warn('MISSING_RESOLUTION', 'Variant $uri is missing RESOLUTION');
      }

      final fullUri = resolveRef(target, uri);
      final vChecks = <CheckItem>[];
      void vok(String c, String m)   => vChecks.add(CheckItem(CheckLevel.ok,   c, m));
      void vwarn(String c, String m) => vChecks.add(CheckItem(CheckLevel.warn, c, m));
      void vfail(String c, String m) => vChecks.add(CheckItem(CheckLevel.fail, c, m));

      // Probe the variant playlist
      final probe = await ffprobeJson(fullUri);
      if (probe == null) {
        vfail('PROBE_FAILED', 'ffprobe could not read: $fullUri');
      } else {
        final streams = (probe['streams'] as List?) ?? [];
        final vidStreams = streams.where((s) => s['codec_type'] == 'video').toList();
        final audStreams = streams.where((s) => s['codec_type'] == 'audio').toList();
        final fmt = (probe['format'] as Map?) ?? {};

        if (vidStreams.isEmpty) {
          vfail('NO_VIDEO', 'No video stream found');
          // No video — label by actual content type from probe
          if (res.isEmpty) {
            if (audStreams.isNotEmpty) res = 'audio';
            else res = 'unknown';
          }
        } else {
          final vs     = vidStreams.first as Map;
          final codec  = vs['codec_name'] ?? 'unknown';
          final width  = vs['width']?.toString() ?? '?';
          final height = vs['height']?.toString() ?? '?';
          final pix    = vs['pix_fmt'] ?? 'unknown';
          vok('VIDEO_STREAM', 'Video: $codec ${width}×$height ($pix)');

          if (!['h264','hevc','av1'].contains(codec)) {
            vwarn('VIDEO_CODEC', "Codec '$codec' may not be widely supported (prefer h264)");
          }
          if (!['yuv420p','yuvj420p'].contains(pix)) {
            vwarn('PIX_FMT', "Pixel format '$pix' may cause issues (prefer yuv420p)");
          }
          if (res != 'unknown' && '${width}x$height' != res) {
            vwarn('RESOLUTION_MISMATCH', 'Declared RESOLUTION=$res but actual is ${width}×$height');
          } else if (res != 'unknown') {
            vok('RESOLUTION_MATCH', 'Declared and actual resolution match ($res)');
          }
        }

        if (audStreams.isEmpty) {
          vwarn('NO_AUDIO', 'No audio stream found');
        } else {
          final a = audStreams.first as Map;
          vok('AUDIO_STREAM', 'Audio: ${a['codec_name']} ${a['sample_rate']}Hz ${a['channels']}ch');
        }

        final duration = double.tryParse(fmt['duration']?.toString() ?? '') ?? 0;
        if (duration > 0) {
          vok('DURATION', 'Duration: ${duration.toStringAsFixed(1)}s (${(duration/60).toStringAsFixed(1)} min)');
        } else {
          vwarn('NO_DURATION', 'Could not determine stream duration');
        }

        // Probe first segment for bitrate
        final varText = await readPlaylist(fullUri);
        int? actualBw;
        if (varText != null) {
          final segUri = varText.split('\n').firstWhere(
            (l) => l.trim().isNotEmpty && !l.trim().startsWith('#'),
            orElse: () => '',
          );
          if (segUri.isNotEmpty) {
            final segFull  = resolveRef(fullUri, segUri.trim());
            final segProbe = await ffprobeJson(segFull);
            if (segProbe != null) {
              actualBw = int.tryParse(
                  ((segProbe['format'] as Map?))?['bit_rate']?.toString() ?? '');
            }
          }
        }

        if (actualBw != null && actualBw > 0 && bw != null) {
          final ratio = actualBw / bw;
          if (ratio > 1.25) {
            vwarn('BANDWIDTH_HIGH',
              'Actual bitrate (${actualBw ~/ 1000} kbps) exceeds declared '
              'BANDWIDTH (${bw ~/ 1000} kbps) by ${((ratio-1)*100).toStringAsFixed(0)}%');
          } else if (ratio < 0.5) {
            vwarn('BANDWIDTH_LOW',
              'Actual bitrate (${actualBw ~/ 1000} kbps) much lower than '
              'declared BANDWIDTH (${bw ~/ 1000} kbps)');
          } else {
            vok('BANDWIDTH_OK',
              'Actual bitrate (${actualBw ~/ 1000} kbps) consistent with '
              'declared BANDWIDTH (${bw ~/ 1000} kbps)');
          }
        }
      }

      variants.add(VariantResult(
        uri: uri,
        resolution: res.isEmpty ? 'unknown' : res,
        declaredBandwidth: bw,
        checks: vChecks,
      ));
    }

    if (bandwidths.length > 1) {
      final sorted     = [...bandwidths]..sort();
      final sortedDesc = sorted.reversed.toList();
      final isAsc  = _listEquals(bandwidths, sorted);
      final isDesc = _listEquals(bandwidths, sortedDesc);
      if (isAsc || isDesc) {
        ok('BANDWIDTH_ORDER', 'Variant streams are in consistent bandwidth order');
      } else {
        warn('BANDWIDTH_ORDER', 'Variant streams are not in ascending bandwidth order (convention, not required by RFC 8216)');
      }
      if (bandwidths.toSet().length != bandwidths.length) {
        warn('DUPLICATE_BANDWIDTH', 'Two or more variants declare identical BANDWIDTH values');
      }
    }
  }

  // ── 5. Media playlist ───────────────────────────────────────────────────
  if (isMedia) {
    final extinfs    = lines.where((l) => l.startsWith('#EXTINF')).toList();
    final segUris    = <String>[];
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('#EXTINF')) {
        for (var j = i + 1; j < lines.length; j++) {
          if (lines[j].trim().isNotEmpty && !lines[j].startsWith('#')) {
            segUris.add(lines[j].trim());
            break;
          }
        }
      }
    }
    ok('SEGMENT_COUNT', 'Found ${extinfs.length} segment(s)');

    final durations = extinfs
        .map((l) => double.tryParse(RegExp(r'#EXTINF:([\d.]+)').firstMatch(l)?.group(1) ?? ''))
        .whereType<double>()
        .toList();

    if (durations.isNotEmpty) {
      final total = durations.reduce((a, b) => a + b);
      final maxD  = durations.reduce((a, b) => a > b ? a : b);
      final minD  = durations.reduce((a, b) => a < b ? a : b);
      ok('TOTAL_DURATION', 'Total: ${total.toStringAsFixed(1)}s (${(total/60).toStringAsFixed(1)} min)');

      final tdLine = lines.firstWhere(
          (l) => l.startsWith('#EXT-X-TARGETDURATION'), orElse: () => '');
      if (tdLine.isEmpty) {
        fail('MISSING_TARGETDURATION', '#EXT-X-TARGETDURATION is required');
      } else {
        final td = int.tryParse(tdLine.split(':').last.trim()) ?? 0;
        if (maxD > td) {
          fail('TARGETDURATION_EXCEEDED',
              '#EXT-X-TARGETDURATION is ${td}s but a segment is ${maxD.toStringAsFixed(2)}s');
        } else {
          ok('TARGETDURATION_OK', 'All segments ≤ #EXT-X-TARGETDURATION (${td}s)');
        }
      }

      if (maxD - minD > 1.0) {
        warn('DURATION_VARIANCE',
            'Segment durations vary by more than 1s (min ${minD.toStringAsFixed(2)}s, max ${maxD.toStringAsFixed(2)}s)');
      } else {
        ok('DURATION_CONSISTENCY',
            'Segment durations are consistent (avg ${(total/durations.length).toStringAsFixed(2)}s)');
      }
    }

    final hasEndlist    = lines.any((l) => l.trim() == '#EXT-X-ENDLIST');
    final hasIndependent = lines.any((l) => l.contains('INDEPENDENT-SEGMENTS'));

    hasEndlist
        ? ok('ENDLIST', '#EXT-X-ENDLIST present — complete VOD')
        : warn('NO_ENDLIST', '#EXT-X-ENDLIST missing — live stream or incomplete VOD');

    hasIndependent
        ? ok('INDEPENDENT_SEGMENTS', '#EXT-X-INDEPENDENT-SEGMENTS present')
        : warn('NO_INDEPENDENT_SEGMENTS', '#EXT-X-INDEPENDENT-SEGMENTS not set');

    // Spot-check first and last segment (local only)
    if (!isUrl && segUris.isNotEmpty) {
      for (final (label, uri) in [('First', segUris.first), ('Last', segUris.last)]) {
        final seg = File(resolveRef(target, uri));
        if (seg.existsSync()) {
          ok('SEGMENT_${label.toUpperCase()}_OK',
              '$label segment accessible: ${seg.uri.pathSegments.last} '
              '(${seg.lengthSync() ~/ 1024} KB)');
        } else {
          fail('SEGMENT_${label.toUpperCase()}_MISSING',
              '$label segment not found: ${seg.path}');
        }
      }
    }
  }

  return done();
}

// ── DASH validation ───────────────────────────────────────────────────────────

/// Returns a human-readable track type label for an AdaptationSet element,
/// used when no resolution is available (audio, text, etc.)
String _trackLabel(XmlElement adapt) {
  final ct = adapt.getAttribute('contentType') ?? '';
  final mt = adapt.getAttribute('mimeType') ?? '';
  if (ct.isNotEmpty) return ct;       // e.g. 'audio', 'video', 'text'
  if (mt.startsWith('audio')) return 'audio';
  if (mt.startsWith('video')) return 'video';
  if (mt.startsWith('text'))  return 'text';
  return 'unknown';
}

Future<ValidationResult> validateMpd(String target) async {
  final checks   = <CheckItem>[];
  final variants = <VariantResult>[];

  void ok(String code, String msg)   => checks.add(CheckItem(CheckLevel.ok,   code, msg));
  void warn(String code, String msg) => checks.add(CheckItem(CheckLevel.warn, code, msg));
  void fail(String code, String msg) => checks.add(CheckItem(CheckLevel.fail, code, msg));

  ValidationResult done() {
    final levels = [
      ...checks.map((c) => c.level),
      ...variants.expand((v) => v.checks.map((c) => c.level)),
    ];
    final summary = levels.contains(CheckLevel.fail)
        ? ValidationSummary.fail
        : levels.contains(CheckLevel.warn)
            ? ValidationSummary.warn
            : ValidationSummary.pass;
    return ValidationResult(summary: summary, checks: checks, variants: variants);
  }

  // ── 1. Accessibility ────────────────────────────────────────────────────
  final isUrl = target.startsWith('http://') || target.startsWith('https://');
  if (!isUrl) {
    final f = File(target);
    if (!f.existsSync()) {
      fail('FILE_NOT_FOUND', 'File does not exist: $target');
      return done();
    }
    if (!target.toLowerCase().endsWith('.mpd')) {
      warn('EXTENSION', 'File does not have a .mpd extension');
    }
    ok('FILE_EXISTS', 'File is accessible: ${f.uri.pathSegments.last}');
  } else {
    ok('URL_TARGET', 'Validating remote URL: $target');
  }

  // ── 2. Read and parse ───────────────────────────────────────────────────
  final text = await readPlaylist(target);
  if (text == null) {
    fail('READ_ERROR', 'Could not read manifest content');
    return done();
  }

  XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } catch (e) {
    fail('XML_PARSE_ERROR', 'Manifest is not valid XML: $e');
    return done();
  }
  ok('XML_VALID', 'Manifest parses as valid XML');

  final root = doc.rootElement;
  if (root.localName != 'MPD') {
    fail('ROOT_ELEMENT', 'Root element is <${root.localName}>, expected <MPD>');
    return done();
  }
  ok('ROOT_ELEMENT', 'Root element is <MPD>');

  final profiles = root.getAttribute('profiles') ?? '';
  profiles.isEmpty
      ? warn('NO_PROFILES', "No 'profiles' attribute on <MPD>")
      : ok('PROFILES', 'Profiles: $profiles');

  final mpdType = root.getAttribute('type') ?? 'static';
  ok('MPD_TYPE', 'Manifest type: $mpdType');
  if (mpdType == 'static') {
    final dur = root.getAttribute('mediaPresentationDuration');
    dur == null
        ? warn('NO_DURATION', 'Static MPD has no mediaPresentationDuration')
        : ok('DURATION', 'Duration: $dur');
  }

  // ── 3. Periods ──────────────────────────────────────────────────────────
  final periods = root.findElements('Period').toList();
  if (periods.isEmpty) {
    fail('NO_PERIODS', 'Manifest contains no <Period> elements');
    return done();
  }
  ok('PERIOD_COUNT', 'Found ${periods.length} period(s)');

  // ── 4. AdaptationSets and Representations ───────────────────────────────
  for (var pIdx = 0; pIdx < periods.length; pIdx++) {
    final adaptSets = periods[pIdx].findElements('AdaptationSet').toList();
    if (adaptSets.isEmpty) {
      fail('NO_ADAPTATION_SETS', 'Period $pIdx has no <AdaptationSet> elements');
      continue;
    }

    final videoSets = adaptSets.where((a) =>
        a.getAttribute('contentType') == 'video' ||
        (a.getAttribute('mimeType') ?? '').startsWith('video')).toList();
    final audioSets = adaptSets.where((a) =>
        a.getAttribute('contentType') == 'audio' ||
        (a.getAttribute('mimeType') ?? '').startsWith('audio')).toList();

    if (videoSets.isEmpty) warn('NO_VIDEO_ADAPTATION', 'Period $pIdx: no video AdaptationSet');
    if (audioSets.isEmpty) warn('NO_AUDIO_ADAPTATION', 'Period $pIdx: no audio AdaptationSet');

    for (final adapt in adaptSets) {
      for (final rep in adapt.findElements('Representation')) {
        final repId     = rep.getAttribute('id') ?? '?';
        final bandwidth = int.tryParse(rep.getAttribute('bandwidth') ?? '');
        final width     = rep.getAttribute('width');
        final height    = rep.getAttribute('height');
        final codec     = rep.getAttribute('codecs') ?? '';

        final vChecks = <CheckItem>[];
        void vok(String c, String m)   => vChecks.add(CheckItem(CheckLevel.ok,   c, m));
        void vwarn(String c, String m) => vChecks.add(CheckItem(CheckLevel.warn, c, m));

        bandwidth != null
            ? vok('BANDWIDTH', 'Declared bandwidth: ${bandwidth ~/ 1000} kbps')
            : vwarn('NO_BANDWIDTH', 'Representation $repId missing bandwidth');

        // Resolution check only applies to video — audio has no width/height
        final isVideo = adapt.getAttribute('contentType') == 'video' ||
            (adapt.getAttribute('mimeType') ?? '').startsWith('video') ||
            (rep.getAttribute('mimeType') ?? '').startsWith('video');
        if (isVideo) {
          (width != null && height != null)
              ? vok('RESOLUTION', 'Resolution: ${width}×$height')
              : vwarn('NO_RESOLUTION', 'Representation $repId missing width/height');
        }

        codec.isNotEmpty
            ? vok('CODEC', 'Codec: $codec')
            : vwarn('NO_CODEC', 'Representation $repId missing codecs attribute');

        // Probe init segment
        final segTmpl = rep.findElements('SegmentTemplate').firstOrNull ??
                        adapt.findElements('SegmentTemplate').firstOrNull;
        if (segTmpl != null) {
          final initTmpl = segTmpl.getAttribute('initialization') ?? '';
          if (initTmpl.isNotEmpty) {
            final initPath = initTmpl.replaceAll('\$RepresentationID\$', repId);
            final initFull = resolveRef(target, initPath);
            final initProbe = await ffprobeJson(initFull);
            if (initProbe != null) {
              final streams = (initProbe['streams'] as List?) ?? [];
              final vid = streams.firstWhere(
                  (s) => s['codec_type'] == 'video', orElse: () => null);
              final aud = streams.firstWhere(
                  (s) => s['codec_type'] == 'audio', orElse: () => null);
              if (vid != null) {
                final aw = vid['width']?.toString() ?? '?';
                final ah = vid['height']?.toString() ?? '?';
                final ac = vid['codec_name'] ?? '?';
                vok('INIT_PROBE', 'Init segment readable: $ac ${aw}×$ah');
                if (width != null && height != null && '${aw}x$ah' != '${width}x$height') {
                  vwarn('RESOLUTION_MISMATCH',
                      'Declared ${width}×$height but actual is ${aw}×$ah');
                }
              }
              if (aud != null) {
                vok('AUDIO_STREAM',
                    'Audio: ${aud['codec_name']} ${aud['sample_rate']}Hz ${aud['channels']}ch');
              }
            } else {
              vwarn('INIT_NOT_FOUND', 'Init segment not accessible: $initFull');
            }
          }
        }

        variants.add(VariantResult(
          uri: repId,
          resolution: (width != null && height != null)
              ? '${width}x$height'
              : _trackLabel(adapt),
          declaredBandwidth: bandwidth,
          checks: vChecks,
        ));
      }
    }
  }

  return done();
}

/// Auto-dispatch to the correct validator based on file extension.
Future<ValidationResult> validateAuto(String target) {
  return target.toLowerCase().endsWith('.mpd')
      ? validateMpd(target)
      : validateM3u8(target);
}
