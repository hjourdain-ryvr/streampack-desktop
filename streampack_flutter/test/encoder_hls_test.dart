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

    await promoteHlsMaster(input: '${tmp.path}/$stem.mkv', outputDir: tmp.path);
    final out = File('${tmp.path}/$stem.m3u8').readAsStringSync();

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
}
