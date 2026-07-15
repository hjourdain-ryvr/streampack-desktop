// Regression tests for the HLS multi-audio master playlist:
//   - exactly one DEFAULT=YES audio rendition (even if the source default was
//     removed) -> avoids ffmpeg flagging ALL audio default and leaking bogus
//     audio STREAM-INF variants (VLC: garbled track list + no audio).
//   - HEVC output carries the hvc1 tag (emits CODECS string + Apple-HLS compat).
//   - promoteHlsMaster rewrites ffmpeg's "audio_N" NAMEs into friendly,
//     de-duplicated language+layout labels and preserves a single default.
//
// Relative imports (not package:streampack/...) so the test runs against the
// lib.streampack source without requiring the build-time lib rename.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib.streampack/encoder.dart';
import '../lib.streampack/models.dart';

String _varStreamMap(List<String> cmd) => cmd[cmd.indexOf('-var_stream_map') + 1];

void main() {
  group('HLS multi-audio var_stream_map', () {
    test('exactly one default:yes when the source default track was removed', () {
      // User plan: kept audio orders 1,3,5,11 — none flagged default (the
      // source default, order 0, was removed in the Advanced tab).
      final plan = [
        AudioSelection(sourceOrder: 1, target: AudioTarget.eac3, channels: AudioChannelMode.source, language: 'eng'),
        AudioSelection(sourceOrder: 3, language: 'eng'),
        AudioSelection(sourceOrder: 5, target: AudioTarget.eac3, channels: AudioChannelMode.source, language: 'fra'),
        AudioSelection(sourceOrder: 11, action: AudioAction.passthrough, language: 'eng'),
      ];
      final cmd = buildHlsCmd(
        input: '/in.mkv', outputDir: '/out',
        resolutions: [kPresets[2], kPresets[3]],
        segmentDuration: 6, nvenc: true, quality: EncodeQuality.balanced,
        output: VideoOutput.h265Hdr, inputColor: InputColor.hdr,
        audioPlan: plan,
      );
      final vsm = _varStreamMap(cmd);
      expect('default:yes'.allMatches(vsm).length, 1);
      expect('default:no'.allMatches(vsm).length, 3);
    });

    test('honours an explicit default among the kept tracks', () {
      final plan = [
        AudioSelection(sourceOrder: 1, language: 'eng'),
        AudioSelection(sourceOrder: 5, language: 'fra', isDefault: true),
      ];
      final cmd = buildHlsCmd(
        input: '/in.mkv', outputDir: '/out',
        resolutions: [kPresets[2]],
        segmentDuration: 6, nvenc: true, quality: EncodeQuality.balanced,
        output: VideoOutput.h265Sdr, inputColor: InputColor.sdr10,
        audioPlan: plan,
      );
      final vsm = _varStreamMap(cmd);
      expect(vsm.contains('a:1,agroup:aud,language:fra,default:yes'), isTrue);
      expect('default:yes'.allMatches(vsm).length, 1);
    });

    test('stereo downmix targets the audio stream (a: specifier, not bare index)', () {
      // Bug (<=3.2.1): -ac used a bare index, which points at a VIDEO output
      // stream (video is emitted first), so a 5.1 source stayed 5.1 in the AAC.
      final plan = [
        AudioSelection(sourceOrder: 0, target: AudioTarget.aac,
            channels: AudioChannelMode.stereo, language: 'eng', isDefault: true),
      ];
      final cmd = buildHlsCmd(
        input: '/in.mkv', outputDir: '/out',
        resolutions: [kPresets[1], kPresets[2]], // video streams come first
        segmentDuration: 6, nvenc: false, quality: EncodeQuality.balanced,
        output: VideoOutput.h265Sdr, inputColor: InputColor.sdr8,
        audioPlan: plan,
      );
      expect(cmd.contains('-ac:a:0'), isTrue);        // audio-type index
      expect(cmd.contains('-ac:0'), isFalse);         // never the bare index
      expect(cmd[cmd.indexOf('-ac:a:0') + 1], '2');   // downmix to 2 channels
    });
  });

  group('HEVC hvc1 tagging', () {
    test('H.265 output carries -tag:v hvc1 (CODECS + Apple HLS)', () {
      final cmd = buildHlsCmd(
        input: '/in.mkv', outputDir: '/out', resolutions: [kPresets[2]],
        segmentDuration: 6, nvenc: false, quality: EncodeQuality.balanced,
        output: VideoOutput.h265Sdr, inputColor: InputColor.sdr8,
      ).join(' ');
      expect(cmd.contains('-tag:v:0 hvc1'), isTrue);
    });

    test('H.264 output does NOT carry an hvc1 tag', () {
      final cmd = buildHlsCmd(
        input: '/in.mkv', outputDir: '/out', resolutions: [kPresets[2]],
        segmentDuration: 6, nvenc: false, quality: EncodeQuality.balanced,
        output: VideoOutput.h264Sdr, inputColor: InputColor.sdr8,
      ).join(' ');
      expect(cmd.contains('hvc1'), isFalse);
    });

    test('MPEG-TS (H.264) zeroes muxdelay/muxpreload; fMP4 (H.265) does not', () {
      final ts = buildHlsCmd(
        input: '/in.mkv', outputDir: '/out', resolutions: [kPresets[2]],
        segmentDuration: 6, nvenc: false, quality: EncodeQuality.balanced,
        output: VideoOutput.h264Sdr, inputColor: InputColor.sdr8,
      ).join(' ');
      expect(ts.contains('-hls_segment_type mpegts'), isTrue);
      expect(ts.contains('-muxdelay 0 -muxpreload 0'), isTrue);

      final fmp4 = buildHlsCmd(
        input: '/in.mkv', outputDir: '/out', resolutions: [kPresets[2]],
        segmentDuration: 6, nvenc: false, quality: EncodeQuality.balanced,
        output: VideoOutput.h265Sdr, inputColor: InputColor.sdr8,
      ).join(' ');
      expect(fmp4.contains('-hls_segment_type fmp4'), isTrue);
      expect(fmp4.contains('-muxdelay'), isFalse);
    });
  });

  test('promoteHlsMaster: friendly de-duped NAMEs, single default, CODECS kept', () async {
    final tmp = await Directory.systemTemp.createTemp('sp_hls_');
    const stem = 'Movie';
    final seg = Directory('${tmp.path}/$stem')..createSync(recursive: true);
    File('${seg.path}/master.m3u8').writeAsStringSync('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_2",DEFAULT=YES,LANGUAGE="eng",CHANNELS="6",URI="p_a0.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_3",DEFAULT=NO,LANGUAGE="eng",CHANNELS="2",URI="p_a1.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_4",DEFAULT=NO,LANGUAGE="fra",CHANNELS="6",URI="p_a2.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_5",DEFAULT=NO,LANGUAGE="eng",CHANNELS="2",URI="p_a3.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=764267,RESOLUTION=832x468,CODECS="hvc1.2.4.L90.B01,ec-3",AUDIO="group_aud"
p_468p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1933470,RESOLUTION=1280x720,CODECS="hvc1.2.4.L93.B01,ec-3",AUDIO="group_aud"
p_720p.m3u8
''');

    await promoteHlsMaster(input: '${tmp.path}/$stem.mkv', outputDir: tmp.path,
        videoRange: 'PQ', frameRate: '23.976');
    final out = File('${tmp.path}/$stem.m3u8').readAsStringSync();

    // Apple iOS/tvOS HLS authoring requirements
    expect('VIDEO-RANGE=PQ'.allMatches(out).length, 2);       // one per video variant
    expect('FRAME-RATE=23.976'.allMatches(out).length, 2);
    expect('CLOSED-CAPTIONS=NONE'.allMatches(out).length, 2);
    expect(out.contains('#EXT-X-INDEPENDENT-SEGMENTS'), isTrue);
    expect(out.contains('VIDEO-RANGE'), isTrue);

    expect(out.contains('NAME="English 5.1"'), isTrue);
    expect(out.contains('NAME="English Stereo"'), isTrue);
    expect(out.contains('NAME="French 5.1"'), isTrue);
    expect(out.contains('NAME="English Stereo (2)"'), isTrue); // dedup of the 2nd eng stereo
    expect(out.contains('audio_'), isFalse);                   // no leftover auto names
    expect('DEFAULT=YES'.allMatches(out).length, 1);           // exactly one default
    expect(out.contains('hvc1.2.4'), isTrue);                  // video CODECS preserved
    expect(out.contains('$stem/p_720p.m3u8'), isTrue);         // variant URI prefixed
    // audio rendition URIs MUST also get the subdir prefix, else players load
    // video but find no audio (silent playback).
    expect(out.contains('URI="$stem/p_a0.m3u8"'), isTrue);
    expect(out.contains('URI="$stem/p_a3.m3u8"'), isTrue);
    expect(out.contains('URI="p_a0.m3u8"'), isFalse);          // no un-prefixed audio URI left

    await tmp.delete(recursive: true);
  });

  group('Advanced video quality', () {
    final res = [kPresets[0], kPresets[1], kPresets[2], kPresets[3]]; // 2160..480
    List<String> hls({VideoQuality? vq, VideoOutput out = VideoOutput.h265Sdr,
        InputColor ic = InputColor.sdr10, bool nvenc = false, HdrMetadata? hdr}) =>
      buildHlsCmd(input: '/i.mkv', outputDir: '/o', resolutions: res,
        segmentDuration: 6, nvenc: nvenc, quality: EncodeQuality.balanced,
        output: out, inputColor: ic, hdrMeta: hdr, videoQuality: vq);
    String after(List<String> c, String flag) => c[c.indexOf(flag) + 1];

    test('no override = legacy preset ladder (byte-identical)', () {
      final c = hls(out: VideoOutput.h264Sdr, ic: InputColor.sdr8);
      expect(after(c, '-b:v:0'), '15000k');
      expect(after(c, '-b:v:1'), '5000k');
      expect(after(c, '-b:v:2'), '2800k');
      expect(after(c, '-b:v:3'), '1400k');
      expect(c.contains('-maxrate:v:0'), isFalse); // legacy CPU path: -b only
    });

    test('bitrate mode scales by 0.75 power + adds VBV cap', () {
      final c = hls(vq: const VideoQuality(bitrate4kKbps: 15000));
      expect(after(c, '-b:v:0'), '15000k');
      expect(after(c, '-b:v:1'), '5303k');  // 15000 * 0.25^0.75
      expect(after(c, '-maxrate:v:1'), '5303k');
    });

    test('HDR adds +15% to the anchor', () {
      final c = hls(out: VideoOutput.h265Hdr, ic: InputColor.hdr,
          hdr: const HdrMetadata(), vq: const VideoQuality(bitrate4kKbps: 15000));
      expect(after(c, '-b:v:0'), '17250k'); // 15000 * 1.15
    });

    test('CRF mode = same crf every rung + generous cap, no -b', () {
      final c = hls(vq: const VideoQuality(mode: VideoQualityMode.crf, crf: 22));
      expect(after(c, '-crf:v:0'), '22');
      expect(after(c, '-crf:v:3'), '22');           // same on every rung
      expect(after(c, '-maxrate:v:0'), '25000k');   // top HEVC anchor scaled
      expect(c.contains('-b:v:0'), isFalse);
    });

    test('CRF mode on NVENC uses -cq with -b 0', () {
      final c = hls(nvenc: true,
          vq: const VideoQuality(mode: VideoQualityMode.crf, crf: 20));
      expect(after(c, '-cq:v:0'), '20');
      expect(after(c, '-b:v:0'), '0');
    });

    test('quality/effort selects the NVENC preset (override beats Basic quality)', () {
      final cBest = hls(nvenc: true,
          vq: const VideoQuality(effort: VideoEffort.best));
      expect(after(cBest, '-preset:v:0'), 'p6');
      final cBal = hls(nvenc: true,
          vq: const VideoQuality(effort: VideoEffort.balanced));
      expect(after(cBal, '-preset:v:0'), 'p4');
      final cHigh = hls(nvenc: true,
          vq: const VideoQuality(effort: VideoEffort.high));
      expect(after(cHigh, '-preset:v:0'), 'p5');
    });

    test('no override falls back to Basic EncodeQuality preset', () {
      final c = buildHlsCmd(input: '/i.mkv', outputDir: '/o', resolutions: res,
        segmentDuration: 6, nvenc: true, quality: EncodeQuality.high,
        output: VideoOutput.h265Sdr, inputColor: InputColor.sdr10);
      expect(after(c, '-preset:v:0'), 'p6'); // EncodeQuality.high
    });
  });

  group('output name', () {
    test('defaultOutputName keeps the raw source name', () {
      expect(defaultOutputName(r"D:\vids\Alien - Director's Cut.mkv"),
          "Alien - Director's Cut");
      expect(defaultOutputName('/x/Movie.2160p.mkv'), 'Movie.2160p');
    });
    test('stemFromName sanitises; safeFileName keeps Plex chars', () {
      const pretty = 'Alien (1979) [tmdbid-348] - Directors Cut 2160P HDR';
      // segment stem: URI/filesystem safe, no spaces/brackets
      expect(stemFromName(pretty), isNot(contains(' ')));
      expect(stemFromName(pretty), isNot(contains('[')));
      expect(stemFromName(pretty), contains('tmdbid-348'));
      // master filename: brackets/spaces preserved for Jellyfin/Plex matching
      expect(safeFileName(pretty), pretty);
    });

    test('promote: master uses pretty name, subdir/URIs use safe stem', () async {
      final tmp = await Directory.systemTemp.createTemp('sp_name_');
      const pretty = 'Alien (1979) [tmdbid-348] - HDR';
      final stem = stemFromName(pretty);
      Directory('${tmp.path}/$stem').createSync(recursive: true);
      File('${tmp.path}/$stem/master.m3u8').writeAsStringSync('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1920x1080,CODECS="hvc1"
p_1080p.m3u8
''');
      await promoteHlsMaster(input: '/x/whatever.mkv', outputDir: tmp.path,
          stemOverride: stem, masterName: safeFileName(pretty));
      // master file named with the pretty name
      expect(File('${tmp.path}/$pretty.m3u8').existsSync(), isTrue);
      final out = File('${tmp.path}/$pretty.m3u8').readAsStringSync();
      // variant URI uses the safe stem subdir
      expect(out.contains('$stem/p_1080p.m3u8'), isTrue);
      await tmp.delete(recursive: true);
    });
  });

  group('per-codec audio groups (browser/hls.js)', () {
    // A mixed eac3 (5.1) + aac (stereo) title with an H.264 SDR + H.265 HDR
    // ladder. Before the fix every variant advertised ec-3 -> hls.js dropped
    // them all. After: one group per codec, variants duplicated, so the avc1
    // variant advertises avc1+mp4a and browsers can play it.
    Future<String> promote(List<String> audioCodecs, {bool aacDefault = true}) async {
      final tmp = await Directory.systemTemp.createTemp('sp_grp_');
      const stem = 'Movie';
      Directory('${tmp.path}/$stem').createSync(recursive: true);
      File('${tmp.path}/$stem/master.m3u8').writeAsStringSync('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_0",DEFAULT=YES,LANGUAGE="eng",CHANNELS="6",URI="${stem}_a0.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_1",DEFAULT=NO,LANGUAGE="eng",CHANNELS="2",URI="${stem}_a1.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="hvc1.2.4,ec-3",AUDIO="group_aud"
${stem}_hdr_1080p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,ec-3",AUDIO="group_aud"
${stem}_sdr_1080p.m3u8
''');
      await promoteHlsMaster(input: '${tmp.path}/$stem.mkv', outputDir: tmp.path,
          stemOverride: stem, audioCodecs: audioCodecs, aacDefault: aacDefault);
      final out = File('${tmp.path}/$stem.m3u8').readAsStringSync();
      await tmp.delete(recursive: true);
      return out;
    }

    test('mixed eac3+aac -> per-codec groups; avc1 gets a browser-playable copy', () async {
      final out = await promote(['ec-3', 'mp4a.40.2']); // aacDefault (mixed mode)
      // two codec groups, none left conflated under the original id
      expect(out.contains('GROUP-ID="aud_ec3"'), isTrue);
      expect(out.contains('GROUP-ID="aud_aac"'), isTrue);
      expect(out.contains('GROUP-ID="group_aud"'), isFalse);
      // the H.264 SDR variant now has an avc1+mp4a copy referencing the aac group
      expect(out.contains('CODECS="avc1.640028,mp4a.40.2"'), isTrue);
      expect(RegExp(r'CODECS="avc1.640028,mp4a.40.2".*AUDIO="aud_aac"').hasMatch(out), isTrue);
      // HDR (hvc1) variant is duplicated across both groups too (full per-codec)
      expect(out.contains('CODECS="hvc1.2.4,mp4a.40.2"'), isTrue);
      expect(out.contains('CODECS="hvc1.2.4,ec-3"'), isTrue);
      // 2 video variants x 2 groups = 4 STREAM-INF
      expect('#EXT-X-STREAM-INF'.allMatches(out).length, 4);
      // AAC is the sole default (browsers auto-play it, not the undecodable
      // ec-3); every rendition is AUTOSELECT=YES for capable native players.
      expect('DEFAULT=YES'.allMatches(out).length, 1);
      expect(RegExp(r'GROUP-ID="aud_aac"[^\n]*DEFAULT=YES').hasMatch(out), isTrue);
      expect(RegExp(r'GROUP-ID="aud_ec3"[^\n]*DEFAULT=YES').hasMatch(out), isFalse);
      expect('AUTOSELECT=YES'.allMatches(out).length, 2); // both renditions
    });

    test('respect-mode keeps the user default (one per group, not forced AAC)', () async {
      // aacDefault:false = non-mixed modes. The source default (audio_0, ec-3)
      // stays default in its group; each group gets its own default.
      final out = await promote(['ec-3', 'mp4a.40.2'], aacDefault: false);
      expect(RegExp(r'GROUP-ID="aud_ec3"[^\n]*DEFAULT=YES').hasMatch(out), isTrue);
      expect(RegExp(r'GROUP-ID="aud_aac"[^\n]*DEFAULT=YES').hasMatch(out), isTrue);
      expect('DEFAULT=YES'.allMatches(out).length, 2); // one per group
    });

    test('friendly audio NAME includes the codec (distinguishes same-layout tracks)', () async {
      final out = await promote(['ec-3', 'mp4a.40.2']);
      expect(out.contains('NAME="English 5.1 (E-AC-3)"'), isTrue);
      expect(out.contains('NAME="English Stereo (AAC)"'), isTrue);
    });

    test('per-codec variants carry honest BANDWIDTH (video + that codec audio)', () async {
      final tmp = await Directory.systemTemp.createTemp('sp_bw_');
      const stem = 'grp';
      final d = Directory('${tmp.path}/$stem')..createSync(recursive: true);
      // Audio measured from 1s segments: ec-3 80000B -> 640000 bps, aac 16000B
      // -> 128000 bps. No video segments here, so the video component falls back
      // to the manifest value (800000). (Robust video measurement is covered by
      // the next test.)
      void seg(String name, int bytes) =>
          File('${d.path}/$name').writeAsBytesSync(List<int>.filled(bytes, 0));
      void playlist(String name, String segName) =>
          File('${d.path}/$name').writeAsStringSync(
              '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n'
              '#EXTINF:1.000,\n$segName\n#EXT-X-ENDLIST\n');
      seg('${stem}_a0_000.m4s', 80000);
      seg('${stem}_a1_000.m4s', 16000);
      playlist('${stem}_a0.m3u8', '${stem}_a0_000.m4s');
      playlist('${stem}_a1.m3u8', '${stem}_a1_000.m4s');
      File('${d.path}/master.m3u8').writeAsStringSync('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_0",DEFAULT=YES,LANGUAGE="eng",CHANNELS="6",URI="${stem}_a0.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_1",DEFAULT=NO,LANGUAGE="eng",CHANNELS="2",URI="${stem}_a1.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=800000,AVERAGE-BANDWIDTH=800000,RESOLUTION=1920x1080,CODECS="avc1.640028,ec-3,mp4a.40.2",AUDIO="group_aud"
${stem}_v.m3u8
''');
      await promoteHlsMaster(input: '${tmp.path}/$stem.mkv', outputDir: tmp.path,
          stemOverride: stem, masterName: stem,
          audioCodecs: ['ec-3', 'mp4a.40.2']);
      final out = File('${tmp.path}/$stem.m3u8').readAsStringSync();
      // ec-3 copy: 800000 (video, from manifest) + 640000 (ec-3) = 1440000
      expect(RegExp(r'BANDWIDTH=1440000\b.*AUDIO="aud_ec3"').hasMatch(out), isTrue);
      // aac copy: 800000 + 128000 = 928000  (honestly lower than the ec-3 copy)
      expect(RegExp(r'BANDWIDTH=928000\b.*AUDIO="aud_aac"').hasMatch(out), isTrue);
      expect(out.contains('BANDWIDTH=800000,'), isFalse); // base augmented, not left bare
      await tmp.delete(recursive: true);
    });

    test('robust video peak ignores short keyframe-boundary segments', () async {
      final tmp = await Directory.systemTemp.createTemp('sp_rob_');
      const stem = 'rob';
      final d = Directory('${tmp.path}/$stem')..createSync(recursive: true);
      void seg(String name, int bytes) =>
          File('${d.path}/$name').writeAsBytesSync(List<int>.filled(bytes, 0));
      // Video: three 2.0s segments @ 500000 B (= 2_000_000 bps) plus one 0.3s
      // fragment @ 300000 B (= 8_000_000 bps). Median dur = 2.0, so the 0.3s
      // fragment (< 1.0) is dropped -> robust peak = 2_000_000, not 8_000_000.
      seg('${stem}_v_000.m4s', 500000);
      seg('${stem}_v_001.m4s', 500000);
      seg('${stem}_v_002.m4s', 500000);
      seg('${stem}_v_003.m4s', 300000);
      File('${d.path}/${stem}_v.m3u8').writeAsStringSync(
          '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n'
          '#EXTINF:2.000,\n${stem}_v_000.m4s\n#EXTINF:2.000,\n${stem}_v_001.m4s\n'
          '#EXTINF:2.000,\n${stem}_v_002.m4s\n#EXTINF:0.300,\n${stem}_v_003.m4s\n'
          '#EXT-X-ENDLIST\n');
      void aud(String name, int bytes) {
        seg('${stem}_${name}_000.m4s', bytes);
        File('${d.path}/${stem}_$name.m3u8').writeAsStringSync(
            '#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n'
            '#EXTINF:1.000,\n${stem}_${name}_000.m4s\n#EXT-X-ENDLIST\n');
      }
      aud('a0', 80000); // ec-3 -> 640000 bps
      aud('a1', 16000); // aac -> 128000 bps
      File('${d.path}/master.m3u8').writeAsStringSync('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_0",DEFAULT=YES,LANGUAGE="eng",CHANNELS="6",URI="${stem}_a0.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_1",DEFAULT=NO,LANGUAGE="eng",CHANNELS="2",URI="${stem}_a1.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=9999,AVERAGE-BANDWIDTH=9999,RESOLUTION=1920x1080,CODECS="avc1.640028,ec-3,mp4a.40.2",AUDIO="group_aud"
${stem}_v.m3u8
''');
      await promoteHlsMaster(input: '${tmp.path}/$stem.mkv', outputDir: tmp.path,
          stemOverride: stem, masterName: stem, audioCodecs: ['ec-3', 'mp4a.40.2']);
      final out = File('${tmp.path}/$stem.m3u8').readAsStringSync();
      // aac copy: robust video 2_000_000 + aac 128_000 = 2_128_000 (NOT 8M-ish)
      expect(RegExp(r'BANDWIDTH=2128000\b.*AUDIO="aud_aac"').hasMatch(out), isTrue);
      // ec-3 copy: 2_000_000 + 640_000 = 2_640_000
      expect(RegExp(r'BANDWIDTH=2640000\b.*AUDIO="aud_ec3"').hasMatch(out), isTrue);
      // the inflated 8 Mbps fragment must not have leaked into any BANDWIDTH
      expect(RegExp(r'BANDWIDTH=8\d{6}').hasMatch(out), isFalse);
      await tmp.delete(recursive: true);
    });

    test('single-codec plan is left as one group (no duplication)', () async {
      final out = await promote(['mp4a.40.2', 'mp4a.40.2']);
      expect(out.contains('GROUP-ID="group_aud"'), isTrue); // unchanged
      expect(out.contains('aud_mp4a'), isFalse);
      expect('#EXT-X-STREAM-INF'.allMatches(out).length, 2); // not duplicated
    });
  });

  test('AudioSelection.hlsCodecTag maps transcode + passthrough codecs', () {
    expect(AudioSelection(sourceOrder: 0).hlsCodecTag, 'mp4a.40.2'); // aac transcode
    expect(AudioSelection(sourceOrder: 0, target: AudioTarget.eac3).hlsCodecTag, 'ec-3');
    expect(AudioSelection(sourceOrder: 0, target: AudioTarget.ac3).hlsCodecTag, 'ac-3');
    expect(AudioSelection(sourceOrder: 0, action: AudioAction.passthrough,
        sourceCodec: 'eac3').hlsCodecTag, 'ec-3');
    expect(AudioSelection(sourceOrder: 0, action: AudioAction.passthrough,
        sourceCodec: 'ac3').hlsCodecTag, 'ac-3');
  });

  test('promoteDashManifest adds friendly de-duped audio Labels', () async {
    final tmp = await Directory.systemTemp.createTemp('sp_dash_');
    const stem = 'Movie';
    Directory('${tmp.path}/$stem').createSync(recursive: true);
    File('${tmp.path}/$stem/$stem.mpd').writeAsStringSync('''
<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period>
<AdaptationSet id="0" contentType="video"><Representation id="0" codecs="hvc1"/></AdaptationSet>
<AdaptationSet id="1" contentType="audio" lang="eng"><Representation id="1" codecs="ec-3"><AudioChannelConfiguration value="6"/></Representation></AdaptationSet>
<AdaptationSet id="2" contentType="audio" lang="eng"><Representation id="2" codecs="mp4a.40.2"><AudioChannelConfiguration value="2"/></Representation></AdaptationSet>
<AdaptationSet id="3" contentType="audio" lang="fra"><Representation id="3" codecs="ec-3"><AudioChannelConfiguration value="6"/></Representation></AdaptationSet>
<AdaptationSet id="4" contentType="audio" lang="eng"><Representation id="4" codecs="ac-3"><AudioChannelConfiguration value="2"/></Representation></AdaptationSet>
</Period></MPD>''');

    await promoteDashManifest(input: '/x/$stem.mkv', outputDir: tmp.path);
    final out = File('${tmp.path}/$stem.mpd').readAsStringSync();

    expect(out.contains('<Label>English 5.1</Label>'), isTrue);
    expect(out.contains('<Label>English Stereo</Label>'), isTrue);
    expect(out.contains('<Label>French 5.1</Label>'), isTrue);
    expect(out.contains('<Label>English Stereo (2)</Label>'), isTrue); // dedup
    // video AdaptationSet must NOT get an audio label
    expect('<Label>'.allMatches(out).length, 4);

    await tmp.delete(recursive: true);
  });

  group('HDR+SDR dual ladder', () {
    final res = [kPresets[0], kPresets[1], kPresets[2]]; // 2160, 1080, 720
    List<String> dl(VideoOutput out, {bool nvenc = false,
        List<AudioSelection> plan = const []}) =>
      buildHlsCmd(input: '/in.mkv', outputDir: '/out', resolutions: res,
        segmentDuration: 6, nvenc: nvenc, quality: EncodeQuality.balanced,
        output: out, inputColor: InputColor.hdr,
        hdrMeta: const HdrMetadata(), audioPlan: plan);

    test('single split, one tone-map, HDR rungs before SDR rungs', () {
      final c = dl(VideoOutput.h265HdrSdr);
      final fc = c[c.indexOf('-filter_complex') + 1];
      expect('[0:v]split=2'.allMatches(fc).length, 1);
      expect('tonemap=hable'.allMatches(fc).length, 1); // applied once
      // HDR ladder scales the bt2020 source; SDR ladder scales the tone-mapped.
      expect(fc.contains('[hdrsrc]split=3'), isTrue);
      expect(fc.contains('[sdrtm]split=3'), isTrue);
    });

    test('HEVC dual: SDR ladder mirrors HDR (both full 2160/1080/720)', () {
      final vsm = _varStreamMap(dl(VideoOutput.h265HdrSdr));
      expect(vsm.contains('name:hdr_2160p'), isTrue);
      expect(vsm.contains('name:sdr_2160p'), isTrue);
      expect(vsm.contains('name:sdr_720p'), isTrue);
      // 6 video variants: 3 HDR + 3 SDR
      expect('name:hdr_'.allMatches(vsm).length, 3);
      expect('name:sdr_'.allMatches(vsm).length, 3);
    });

    test('H.264 SDR ladder is capped at 1080p (no 2160p SDR rung)', () {
      final vsm = _varStreamMap(dl(VideoOutput.h265HdrH264Sdr));
      expect(vsm.contains('name:hdr_2160p'), isTrue); // HDR keeps 4K
      expect(vsm.contains('name:sdr_2160p'), isFalse); // SDR capped
      expect('name:sdr_'.allMatches(vsm).length, 2);   // 1080 + 720
    });

    test('HDR rungs are HEVC/PQ; SDR rungs are the SDR codec + bt709', () {
      final c = dl(VideoOutput.h265HdrH264Sdr).join(' ');
      // HDR rung 0: HEVC 10-bit PQ
      expect(c.contains('-c:v:0 libx265'), isTrue);
      expect(c.contains('transfer=smpte2084'), isTrue);
      expect(c.contains('-pix_fmt:v:0 yuv420p10le'), isTrue);
      // First SDR rung (index 3) is H.264, 8-bit, tagged bt709
      expect(c.contains('-c:v:3 libx264'), isTrue);
      expect(c.contains('-color_trc:v:3 bt709'), isTrue);
    });

    test('single bitrate control maps the H.264 SDR ladder to its own tier', () {
      // resolutions 2160/1080/720 -> HDR rungs v:0,1,2 ; SDR (<=1080) v:3,4
      final c = buildHlsCmd(
        input: '/in.mkv', outputDir: '/out',
        resolutions: [kPresets[0], kPresets[1], kPresets[2]],
        segmentDuration: 6, nvenc: false, quality: EncodeQuality.balanced,
        output: VideoOutput.h265HdrH264Sdr, inputColor: InputColor.hdr,
        hdrMeta: const HdrMetadata(),
        videoQuality: const VideoQuality(bitrate4kKbps: 15000),
      );
      String after(String f) => c[c.indexOf(f) + 1];
      // HDR HEVC 1080p (v:1): the H.265 anchor + 15% HDR bump.
      expect(after('-b:v:1'), '${scaledVideoBitrateKbps(15000, 1920, 1080, hdr: true)}k');
      // SDR H.264 1080p (v:3): the AVC anchor at the same tier (15000 -> 24000),
      // no HDR bump -> higher than the HDR HEVC rung, not lower.
      expect(after('-b:v:3'), '${scaledVideoBitrateKbps(24000, 1920, 1080)}k');
    });

    test('HEVC+HEVC dual shares the anchor for the SDR ladder', () {
      // resolutions 1080/720 -> HDR v:0,1 ; SDR v:2,3
      final c = buildHlsCmd(
        input: '/in.mkv', outputDir: '/out',
        resolutions: [kPresets[1], kPresets[2]],
        segmentDuration: 6, nvenc: false, quality: EncodeQuality.balanced,
        output: VideoOutput.h265HdrSdr, inputColor: InputColor.hdr,
        hdrMeta: const HdrMetadata(),
        videoQuality: const VideoQuality(bitrate4kKbps: 15000),
      );
      String after(String f) => c[c.indexOf(f) + 1];
      expect(after('-b:v:0'), '${scaledVideoBitrateKbps(15000, 1920, 1080, hdr: true)}k'); // HDR +15%
      expect(after('-b:v:2'), '${scaledVideoBitrateKbps(15000, 1920, 1080)}k');            // SDR same anchor
    });

    test('empty audio plan muxes AAC per variant (v:i,a:i)', () {
      final vsm = _varStreamMap(dl(VideoOutput.h265HdrSdr));
      expect(vsm.contains('v:0,a:0,name:hdr_2160p'), isTrue);
      expect(vsm.contains('v:5,a:5,name:sdr_720p'), isTrue);
    });

    test('audio plan -> shared group, all 6 video variants reference it', () {
      final plan = [
        AudioSelection(sourceOrder: 0, language: 'eng', isDefault: true),
        AudioSelection(sourceOrder: 1, language: 'fra'),
      ];
      final vsm = _varStreamMap(dl(VideoOutput.h265HdrSdr, plan: plan));
      expect('agroup:aud'.allMatches(vsm).length, 6 + 2); // 6 video + 2 audio
      expect('default:yes'.allMatches(vsm).length, 1);
    });

    test('promote sets per-variant VIDEO-RANGE (PQ for hdr_, SDR for sdr_)', () async {
      final tmp = await Directory.systemTemp.createTemp('sp_dual_');
      const stem = 'Movie';
      Directory('${tmp.path}/$stem').createSync(recursive: true);
      File('${tmp.path}/$stem/master.m3u8').writeAsStringSync('''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,CODECS="hvc1.2.4"
${stem}_hdr_1080p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,CODECS="avc1.640028"
${stem}_sdr_720p.m3u8
''');
      await promoteHlsMaster(input: '${tmp.path}/$stem.mkv', outputDir: tmp.path,
          videoRange: 'PQ', stemOverride: stem);
      final out = File('${tmp.path}/$stem.m3u8').readAsStringSync();
      expect('VIDEO-RANGE=PQ'.allMatches(out).length, 1);  // the hdr_ variant
      expect('VIDEO-RANGE=SDR'.allMatches(out).length, 1);  // the sdr_ variant
      await tmp.delete(recursive: true);
    });
  });
}
