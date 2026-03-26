import 'dart:convert';
import 'dart:io';

/// Returns the path to ffmpeg — bundled binary next to executable, or PATH.
String ffmpegPath()  => _toolPath('ffmpeg');
String ffprobePath() => _toolPath('ffprobe');

String _toolPath(String name) {
  final exe     = File(Platform.resolvedExecutable);
  final binName = Platform.isWindows ? '$name.exe' : name;
  final sibling = File('${exe.parent.path}${Platform.pathSeparator}$binName');
  if (sibling.existsSync()) return sibling.path;
  return name;
}

/// Run ffprobe on [target] and return parsed JSON, or null on failure.
Future<Map<String, dynamic>?> ffprobeJson(String target) async {
  try {
    final result = await Process.run(ffprobePath(), [
      '-v', 'error',
      '-print_format', 'json',
      '-show_format', '-show_streams',
      target,
    ]);
    if (result.exitCode != 0) return null;
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// Read a local file or fetch a remote URL as text. Returns null on failure.
Future<String?> readPlaylist(String pathOrUrl) async {
  if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
    try {
      final result = await Process.run(
        'curl', ['-fsSL', '--max-time', '15', pathOrUrl],
      );
      return result.exitCode == 0 ? result.stdout as String : null;
    } catch (_) {
      return null;
    }
  }
  try {
    return await File(pathOrUrl).readAsString();
  } catch (_) {
    return null;
  }
}

/// Resolve a playlist-relative segment or sub-playlist reference.
String resolveRef(String base, String ref) {
  if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
  if (base.startsWith('http://') || base.startsWith('https://')) {
    return Uri.parse(base).resolve(ref).toString();
  }
  return '${File(base).parent.path}${Platform.pathSeparator}$ref';
}

/// Check whether ffmpeg is available (bundled or system).
Future<bool> ffmpegAvailable() async {
  try {
    final r = await Process.run(ffmpegPath(), ['-version']);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}
