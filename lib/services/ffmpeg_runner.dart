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

  /// Probes for a valid local FFmpeg CLI executable on Desktop.
  static Future<String?> getFfmpegCliPath() async {
    if (_hasProbedCli) return _cachedFfmpegCliPath;
    _hasProbedCli = true;

    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return null;
    }

    // 1. Environment variable override
    final envFfmpeg = Platform.environment['FFMPEG_PATH'];
    if (envFfmpeg != null && envFfmpeg.isNotEmpty && await File(envFfmpeg).exists()) {
      _cachedFfmpegCliPath = envFfmpeg;
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
      if (await File(p).exists()) {
        _cachedFfmpegCliPath = p;
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
      if (await File(p).exists()) {
        _cachedFfmpegCliPath = p;
        return _cachedFfmpegCliPath;
      }
    }

    // 4. Common drive roots and known installations
    final candidatePaths = [
      r'E:\ffmpeg-8.1-full_build\bin\ffmpeg.exe',
      r'C:\ffmpeg\bin\ffmpeg.exe',
      r'D:\ffmpeg\bin\ffmpeg.exe',
      r'E:\ffmpeg\bin\ffmpeg.exe',
      r'D:\AIMP\Plugins\enc_ffmpeg\ffmpeg.exe',
      r'D:\deepin\SpleeterGUI\ffmpeg.exe',
    ];

    for (final p in candidatePaths) {
      if (await File(p).exists()) {
        _cachedFfmpegCliPath = p;
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
          if (outLines.isNotEmpty && await File(outLines.first.trim()).exists()) {
            _cachedFfmpegCliPath = outLines.first.trim();
            return _cachedFfmpegCliPath;
          }
        }
      }
    } catch (_) {}

    // 6. Test if 'ffmpeg' directly runs from system PATH
    try {
      final testRun = await Process.run('ffmpeg', ['-version']);
      if (testRun.exitCode == 0) {
        _cachedFfmpegCliPath = 'ffmpeg';
        return _cachedFfmpegCliPath;
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
      await _executeViaCli(
        cliPath: cliPath,
        args: args,
        totalExpectedFrames: totalExpectedFrames,
        onProgress: onProgress,
      );
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
