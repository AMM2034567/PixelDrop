import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

/// Unified cross-platform FFmpeg execution engine.
///
/// On Windows / Desktop, prefers direct high-performance native FFmpeg CLI process
/// if available, providing unconstrained multi-threading and instant zero-overhead execution.
/// Falls back to FFmpegKit on mobile (Android/iOS) or when CLI is not installed.
class FfmpegRunner {
  static String? _cachedFfmpegCliPath;
  static bool _hasProbedCli = false;

  /// Validates that the FFmpeg executable at [path] can be spawned and supports video encoding (e.g. libx264).
  static Future<bool> _isValidFfmpeg(String path) async {
    try {
      final res = await Process.run(path, ['-encoders'])
          .timeout(const Duration(seconds: 2));
      if (res.exitCode == 0) {
        return res.stdout.toString().contains('libx264');
      }
      final verRes = await Process.run(path, ['-version'])
          .timeout(const Duration(seconds: 2));
      return verRes.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Probes for a valid local FFmpeg CLI executable on Desktop.
  static Future<String?> getFfmpegCliPath() async {
    if (_hasProbedCli && _cachedFfmpegCliPath != null) return _cachedFfmpegCliPath;
    _hasProbedCli = true;

    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return null;
    }

    Future<bool> checkAndCache(String p) async {
      if (await File(p).exists() && await _isValidFfmpeg(p)) {
        _cachedFfmpegCliPath = p;
        return true;
      }
      return false;
    }

    // 1. Environment variable override
    final envFfmpeg = Platform.environment['FFMPEG_PATH'];
    if (envFfmpeg != null && envFfmpeg.isNotEmpty && await checkAndCache(envFfmpeg)) {
      return _cachedFfmpegCliPath;
    }

    // 2. Check beside current executable & in current directory
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final nearbyPaths = [
      '$exeDir\\ffmpeg.exe',
      '$exeDir\\bin\\ffmpeg.exe',
      '${Directory.current.path}\\ffmpeg.exe',
      '${Directory.current.path}\\windows\\ffmpeg-kit\\bin\\ffmpeg.exe',
    ];
    for (final p in nearbyPaths) {
      if (await checkAndCache(p)) {
        return _cachedFfmpegCliPath;
      }
    }

    // 3. Package managers (WinGet, Scoop, Chocolatey) and Program Files
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final userProfile = Platform.environment['USERPROFILE'];
    final programFiles = Platform.environment['ProgramFiles'];
    final choco = Platform.environment['ChocolateyInstall'];

    final pmPaths = <String>[
      if (localAppData != null) '$localAppData\\Microsoft\\WinGet\\Links\\ffmpeg.exe',
      if (userProfile != null) '$userProfile\\scoop\\shims\\ffmpeg.exe',
      if (userProfile != null) '$userProfile\\scoop\\apps\\ffmpeg\\current\\bin\\ffmpeg.exe',
      if (choco != null) '$choco\\bin\\ffmpeg.exe',
      if (programFiles != null) '$programFiles\\ffmpeg\\bin\\ffmpeg.exe',
    ];
    for (final p in pmPaths) {
      if (await checkAndCache(p)) {
        return _cachedFfmpegCliPath;
      }
    }

    // 4. Common drive roots and standard installations
    final candidatePaths = [
      r'C:\ffmpeg\bin\ffmpeg.exe',
      r'D:\ffmpeg\bin\ffmpeg.exe',
      r'E:\ffmpeg\bin\ffmpeg.exe',
      r'C:\ffmpeg\ffmpeg.exe',
      r'D:\ffmpeg\ffmpeg.exe',
      r'E:\ffmpeg\ffmpeg.exe',
    ];

    for (final p in candidatePaths) {
      if (await checkAndCache(p)) {
        return _cachedFfmpegCliPath;
      }
    }

    // 5. Search PATH via where.exe on Windows or which on POSIX
    try {
      final probeCmd = Platform.isWindows ? 'where.exe' : 'which';
      for (final query in Platform.isWindows ? ['ffmpeg.exe', 'ffmpeg'] : ['ffmpeg']) {
        final probeRes = await Process.run(probeCmd, [query]);
        if (probeRes.exitCode == 0) {
          final outLines = (probeRes.stdout as String)
              .split(RegExp(r'[\r\n]+'))
              .where((s) => s.trim().isNotEmpty)
              .toList();
          for (final line in outLines) {
            if (await checkAndCache(line.trim())) {
              return _cachedFfmpegCliPath;
            }
          }
        }
      }
    } catch (_) {}

    // 6. Test if 'ffmpeg' directly runs from system PATH
    if (await _isValidFfmpeg('ffmpeg')) {
      _cachedFfmpegCliPath = 'ffmpeg';
      return _cachedFfmpegCliPath;
    }

    return null;
  }

  /// Probes video width and height. Returns (width, height) or null if undetermined.
  static Future<(int, int)?> getVideoDimensions(String videoPath) async {
    final cliPath = await getFfmpegCliPath();
    if (cliPath != null) {
      // 1. Try ffprobe beside ffmpeg
      try {
        final dir = File(cliPath).parent.path;
        final probeCandidate = Platform.isWindows ? '$dir\\ffprobe.exe' : '$dir/ffprobe';
        if (await File(probeCandidate).exists()) {
          final res = await Process.run(probeCandidate, [
            '-v', 'error',
            '-select_streams', 'v:0',
            '-show_entries', 'stream=width,height',
            '-of', 'csv=s=x:p=0',
            videoPath,
          ]).timeout(const Duration(seconds: 4));
          if (res.exitCode == 0) {
            final text = (res.stdout as String).trim();
            final parts = text.split('x');
            if (parts.length == 2) {
              final w = int.tryParse(parts[0]);
              final h = int.tryParse(parts[1]);
              if (w != null && h != null && w > 0 && h > 0) {
                return (w, h);
              }
            }
          }
        }
      } catch (_) {}

      // 2. Try ffmpeg -i videoPath and parse stderr
      try {
        final res = await Process.run(cliPath, ['-i', videoPath]).timeout(const Duration(seconds: 4));
        final errText = res.stderr as String;
        final match = RegExp(r'Stream #0:\d+.*?: Video:.*?\b(\d{3,5})x(\d{3,5})\b').firstMatch(errText)
            ?? RegExp(r'Video:.*?\b(\d{3,5})x(\d{3,5})\b').firstMatch(errText)
            ?? RegExp(r'\b(\d{3,5})x(\d{3,5})\b').firstMatch(errText);
        if (match != null) {
          final w = int.tryParse(match.group(1)!);
          final h = int.tryParse(match.group(2)!);
          if (w != null && h != null && w > 0 && h > 0) {
            return (w, h);
          }
        }
      } catch (_) {}
    }

    // 3. Fallback on mobile with FFmpegKit
    try {
      final session = await FFmpegKit.executeWithArguments(['-i', videoPath]);
      final rawLogs = await session.getLogsAsString();
      final match = RegExp(r'Stream #0:\d+.*?: Video:.*?\b(\d{3,5})x(\d{3,5})\b').firstMatch(rawLogs)
          ?? RegExp(r'Video:.*?\b(\d{3,5})x(\d{3,5})\b').firstMatch(rawLogs)
          ?? RegExp(r'\b(\d{3,5})x(\d{3,5})\b').firstMatch(rawLogs);
      if (match != null) {
        final w = int.tryParse(match.group(1)!);
        final h = int.tryParse(match.group(2)!);
        if (w != null && h != null && w > 0 && h > 0) {
          return (w, h);
        }
      }
    } catch (_) {}

    return null;
  }

  /// Executes FFmpeg arguments with real-time frame progress callbacks.
  static Future<void> execute({
    required List<String> args,
    int? totalExpectedFrames,
    void Function(int frameNumber, double? ratio)? onProgress,
  }) async {
    final cliPath = await getFfmpegCliPath();

    if (cliPath != null) {
      try {
        await _executeViaCli(
          cliPath: cliPath,
          args: args,
          totalExpectedFrames: totalExpectedFrames,
          onProgress: onProgress,
        );
        return;
      } catch (cliError) {
        // Fallback to FFmpegKit if native CLI fails
        _cachedFfmpegCliPath = null;
        try {
          await _executeViaKit(
            args: args,
            totalExpectedFrames: totalExpectedFrames,
            onProgress: onProgress,
          );
          return;
        } catch (_) {
          rethrow;
        }
      }
    } else {
      await _executeViaKit(
        args: args,
        totalExpectedFrames: totalExpectedFrames,
        onProgress: onProgress,
      );
    }
  }

  static Future<void> _executeViaCli({
    required String cliPath,
    required List<String> args,
    int? totalExpectedFrames,
    void Function(int frameNumber, double? ratio)? onProgress,
  }) async {
    final process = await Process.start(cliPath, args);
    final logBuffer = StringBuffer();
    final frameRegex = RegExp(r'frame=\s*(\d+)');

    final stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
      (chunk) {
        logBuffer.write(chunk);
        final matches = frameRegex.allMatches(chunk);
        if (matches.isNotEmpty) {
          final lastMatch = matches.last;
          final f = int.tryParse(lastMatch.group(1) ?? '');
          if (f != null && f > 0) {
            double? ratio;
            if (totalExpectedFrames != null && totalExpectedFrames > 0) {
              ratio = (f / totalExpectedFrames).clamp(0.0, 1.0);
            }
            onProgress?.call(f, ratio);
          }
        }
      },
      onError: (_) {},
    );

    final stdoutSub = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
      (chunk) {
        logBuffer.write(chunk);
      },
      onError: (_) {},
    );

    final exitCode = await process.exitCode;
    await stderrSub.cancel();
    await stdoutSub.cancel();

    if (exitCode != 0) {
      final rawLogs = logBuffer.toString();
      final lines = rawLogs.split('\n').where((l) => l.trim().isNotEmpty).toList();
      final tailLogs = lines.length > 10 ? lines.sublist(lines.length - 10).join('\n') : rawLogs;
      throw Exception('FFmpeg CLI 运行失败 (Code: $exitCode):\n$tailLogs');
    }
  }

  static Future<void> _executeViaKit({
    required List<String> args,
    int? totalExpectedFrames,
    void Function(int frameNumber, double? ratio)? onProgress,
  }) async {
    if (onProgress != null) {
      FFmpegKitConfig.enableStatisticsCallback((statistics) {
        final f = statistics.getVideoFrameNumber();
        if (f > 0) {
          double? ratio;
          if (totalExpectedFrames != null && totalExpectedFrames > 0) {
            ratio = (f / totalExpectedFrames).clamp(0.0, 1.0);
          }
          onProgress(f, ratio);
        }
      });
    }

    try {
      final session = await FFmpegKit.executeWithArguments(args);
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final rawLogs = await session.getLogsAsString();
        final lines = rawLogs.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final tailLogs = lines.length > 10 ? lines.sublist(lines.length - 10).join('\n') : rawLogs;
        throw Exception('FFmpegKit 执行失败 (Code: $returnCode):\n$tailLogs');
      }
    } finally {
      FFmpegKitConfig.enableStatisticsCallback(null);
    }
  }
}
