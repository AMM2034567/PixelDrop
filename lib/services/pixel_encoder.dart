import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../models/pixel_packet.dart';
import 'ffmpeg_runner.dart';
import 'notification_service.dart';
import 'storage_helper.dart';

class EncodeResult {
  final File videoFile;
  final String filename;
  final int originalSize;
  final int videoSize;
  final String sha256;

  EncodeResult({
    required this.videoFile,
    required this.filename,
    required this.originalSize,
    required this.videoSize,
    required this.sha256,
  });
}

class _RenderWorkerArgs {
  final SendPort sendPort;
  final List<Uint8List> chunks;
  final int startChunkIndex;
  final int totalChunks;
  final int frameCapacity;
  final int gridW;
  final int gridH;
  final int holdFrames;
  final int version;
  final String framesDirPath;

  _RenderWorkerArgs({
    required this.sendPort,
    required this.chunks,
    required this.startChunkIndex,
    required this.totalChunks,
    required this.frameCapacity,
    required this.gridW,
    required this.gridH,
    required this.holdFrames,
    required this.version,
    required this.framesDirPath,
  });
}

/// Background Isolate worker for parallel frame generation.
/// Each worker processes a disjoint sublist of chunks and writes deterministically
/// numbered PNG frames directly into [args.framesDirPath].
void _renderFramesWorker(_RenderWorkerArgs args) {
  try {
    final dotCount = args.gridW * args.gridH;

    for (int i = 0; i < args.chunks.length; i++) {
      final chunkIdx = args.startChunkIndex + i;
      final chunk = args.chunks[i];
      final frameRaw = PixelProtocol.buildFrame(
        args.totalChunks,
        chunkIdx,
        chunk,
        args.frameCapacity,
        version: args.version,
      );

      // 3-channel RGB image (480x270, 320x180, etc.)
      final smallImg = img.Image(
        width: args.gridW,
        height: args.gridH,
        numChannels: 3,
      );

      if (args.version == 2) {
        // RGB 8-color protocol: 3 bits per dot
        final dots = PixelProtocol.unpackBytesToColorDots(frameRaw, dotCount);
        int dotIdx = 0;
        for (int y = 0; y < args.gridH; y++) {
          for (int x = 0; x < args.gridW; x++) {
            final v = dots[dotIdx++];
            final r = (v & 4) != 0 ? 255 : 0;
            final g = (v & 2) != 0 ? 255 : 0;
            final b = (v & 1) != 0 ? 255 : 0;
            smallImg.setPixelRgb(x, y, r, g, b);
          }
        }
      } else {
        // Monochrome protocol: 1 bit per dot
        final bits = PixelProtocol.unpackBits(frameRaw);
        int bitIdx = 0;
        for (int y = 0; y < args.gridH; y++) {
          for (int x = 0; x < args.gridW; x++) {
            final val = bits[bitIdx++] == 1 ? 255 : 0;
            smallImg.setPixelRgb(x, y, val, val, val);
          }
        }
      }

      final pngBytes = img.encodePng(smallImg, level: 1);

      // Deterministic frame index calculation:
      // Chunk idx generates frames from 1 + chunkIdx * holdFrames to (chunkIdx + 1) * holdFrames.
      final startFrameNumber = 1 + chunkIdx * args.holdFrames;
      for (int h = 0; h < args.holdFrames; h++) {
        final frameNumber = startFrameNumber + h;
        final framePath =
            '${args.framesDirPath}/frame_${frameNumber.toString().padLeft(6, '0')}.png';
        File(framePath).writeAsBytesSync(pngBytes, flush: false);
      }

      // Signal 1 chunk completed
      args.sendPort.send(1);
    }
  } catch (e) {
    args.sendPort.send('Worker error: $e');
  } finally {
    // Done signal for this worker
    args.sendPort.send(null);
  }
}

class PixelEncoderService {
  static const int defaultWidth = 1920;
  static const int defaultHeight = 1080;
  static const int defaultFps = 30;
  static const int defaultHoldFrames = 1;
  static const int defaultCrf = 24;

  // Preserved for backwards compatibility
  static const int width = 1280;
  static const int height = 720;

  /// Returns optimal worker Isolate count based on platform and hardware capabilities.
  /// - Desktop (Windows, Linux, macOS): uses 3/4 of logical cores, clamped between 1 and 8.
  /// - Mobile (Android, iOS): conservative 1~2 Isolates to avoid thermal throttling and LMK.
  static int getOptimalWorkerCount([int? overrideWorkers]) {
    if (overrideWorkers != null && overrideWorkers > 0) {
      return overrideWorkers;
    }
    final cpuCount = Platform.numberOfProcessors;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return (cpuCount * 3 ~/ 4).clamp(1, 8);
    } else {
      return (cpuCount >= 4) ? 2 : 1;
    }
  }

  /// Platform-aware accelerator description for UI indicators.
  static String getAcceleratorStatus([int? workerCount]) {
    final count = workerCount ?? getOptimalWorkerCount();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return '多核并行加速: 启用 ($count 核心)';
    } else {
      return '移动温控模式: 启用 ($count 核心)';
    }
  }

  /// Builds standard FFmpeg arguments for encoding frames into MP4 with optional silent AAC audio
  /// and +faststart web optimization.
  static List<String> buildFfmpegArgs({
    required String framesPattern,
    required String outputPath,
    int fps = defaultFps,
    int width = defaultWidth,
    int height = defaultHeight,
    int crf = defaultCrf,
    int gop = 60,
    bool includeSilentAudio = true,
  }) {
    return [
      '-y',
      '-framerate',
      '$fps',
      '-i',
      framesPattern,
      if (includeSilentAudio) ...[
        '-f',
        'lavfi',
        '-i',
        'anullsrc=channel_layout=stereo:sample_rate=44100',
      ],
      '-vf',
      'scale=$width:$height:flags=neighbor',
      '-c:v',
      'libx264',
      '-crf',
      '$crf',
      '-preset',
      'fast',
      '-g',
      '$gop',
      '-sc_threshold',
      '0',
      '-pix_fmt',
      'yuv420p',
      if (includeSilentAudio) ...[
        '-c:a',
        'aac',
        '-b:a',
        '32k',
        '-shortest',
      ],
      '-movflags',
      '+faststart',
      outputPath,
    ];
  }

  static Future<EncodeResult> encodeFileToVideo({
    required File inputFile,
    int blockSize = 4,
    int width = defaultWidth,
    int height = defaultHeight,
    int fps = defaultFps,
    int holdFrames = defaultHoldFrames,
    int crf = defaultCrf,
    int version = 2,
    int? workerCount,
    bool includeSilentAudio = true,
    Function(double progress, String status)? onProgress,
  }) async {
    final rawBytes = await inputFile.readAsBytes();
    final filename = Uri.decodeComponent(inputFile.uri.pathSegments.last);
    final origSize = rawBytes.length;
    final fileSha256 = sha256.convert(rawBytes).toString();

    onProgress?.call(0.02, '正在压缩文件数据...');

    // 1. Gzip compression
    final compressedBytes = Uint8List.fromList(GZipEncoder().encode(rawBytes)!);
    final useGzip = compressedBytes.length < origSize;
    final payloadBody = useGzip ? compressedBytes : rawBytes;

    // 2. Prep metadata header
    final metaHeader = PixelProtocol.buildMetaHeader(
      filename: filename,
      origSize: origSize,
      sha256Hex: fileSha256,
      useGzip: useGzip,
    );

    final fullStream = Uint8List(metaHeader.length + payloadBody.length);
    fullStream.setRange(0, metaHeader.length, metaHeader);
    fullStream.setRange(metaHeader.length, fullStream.length, payloadBody);

    // 3. Grid geometry
    final gridW = width ~/ blockSize;
    final gridH = height ~/ blockSize;
    final totalDots = gridW * gridH;
    final int bitsPerDot = (version == 2) ? 3 : 1;
    final frameCapacity = (totalDots * bitsPerDot) ~/ 8; // Total bytes capacity per frame
    final chunkPayloadCapacity = frameCapacity - PixelProtocol.headerLen;

    // Slice into chunks
    final List<Uint8List> chunks = [];
    for (int i = 0; i < fullStream.length; i += chunkPayloadCapacity) {
      final end = (i + chunkPayloadCapacity < fullStream.length)
          ? i + chunkPayloadCapacity
          : fullStream.length;
      chunks.add(Uint8List.sublistView(fullStream, i, end));
    }
    final totalChunks = chunks.length;

    // 4. Render frames in background Isolate worker pool with real-time aggregated progress
    Directory tempDir;
    try {
      tempDir = await getTemporaryDirectory();
    } catch (_) {
      tempDir = Directory.systemTemp;
    }
    final sessionTimestamp = DateTime.now().millisecondsSinceEpoch;
    final framesDir = Directory('${tempDir.path}/pixel_enc_$sessionTimestamp');
    await framesDir.create(recursive: true);
    final tempOutFile = File('${tempDir.path}/temp_enc_$sessionTimestamp.mp4');

    try {
      final optimalWorkers = getOptimalWorkerCount(workerCount);
      final effectiveWorkers = optimalWorkers.clamp(1, totalChunks);
      onProgress?.call(
        0.05,
        '正在生成点阵帧 ($totalChunks 帧 · $effectiveWorkers 线程并行)...',
      );

      final receivePort = ReceivePort();
      final spawnedIsolates = <Isolate>[];
      int activeWorkers = 0;

      final baseCount = totalChunks ~/ effectiveWorkers;
      final remainder = totalChunks % effectiveWorkers;
      int currentStart = 0;

      for (int w = 0; w < effectiveWorkers; w++) {
        final count = baseCount + (w < remainder ? 1 : 0);
        if (count == 0) continue;
        final startIdx = currentStart;
        final endIdx = currentStart + count;
        currentStart = endIdx;

        final workerChunks = chunks.sublist(startIdx, endIdx);
        final iso = await Isolate.spawn(
          _renderFramesWorker,
          _RenderWorkerArgs(
            sendPort: receivePort.sendPort,
            chunks: workerChunks,
            startChunkIndex: startIdx,
            totalChunks: totalChunks,
            frameCapacity: frameCapacity,
            gridW: gridW,
            gridH: gridH,
            holdFrames: holdFrames,
            version: version,
            framesDirPath: framesDir.path,
          ),
          onError: receivePort.sendPort,
        );
        spawnedIsolates.add(iso);
        activeWorkers++;
      }

      int completedWorkers = 0;
      int completedChunks = 0;
      int lastReportTime = 0;
      String? workerError;

      try {
        await for (final msg in receivePort) {
          if (msg is int) {
            completedChunks += msg;
            final now = DateTime.now().millisecondsSinceEpoch;
            final isFirst = completedChunks == 1;
            final isLast = completedChunks >= totalChunks;
            // Smooth UI updates: report on first, last, or at least every 50ms
            if (isFirst || isLast || (now - lastReportTime >= 50)) {
              lastReportTime = now;
              final progressRatio = (completedChunks / totalChunks).clamp(0.0, 1.0);
              final currentP = 0.05 + 0.45 * progressRatio;
              final statusText =
                  '生成点阵帧: $completedChunks / $totalChunks (${(progressRatio * 100).toInt()}%)';
              onProgress?.call(currentP, statusText);
              NotificationService.showProgress(
                id: 101,
                title: 'PixelDrop 正在生成视频...',
                body: statusText,
                progress: (currentP * 100).toInt(),
                maxProgress: 100,
              );
            }
          } else if (msg is List) {
            // Uncaught error emitted by Isolate.spawn onError
            workerError = msg.isNotEmpty ? msg.first.toString() : '未知 Isolate 线程异常';
            break;
          } else if (msg is String) {
            workerError = msg;
            break;
          } else if (msg == null) {
            completedWorkers++;
            if (completedWorkers >= activeWorkers) {
              break;
            }
          }
        }
      } finally {
        receivePort.close();
        for (final iso in spawnedIsolates) {
          iso.kill(priority: Isolate.immediate);
        }
      }

      if (workerError != null) {
        throw Exception('点阵帧并行生成失败: $workerError');
      }

      // 5. FFmpeg encode to MP4 with hardware scaling, silent audio, and faststart
      onProgress?.call(0.52, '正在压制 MP4 视频...');
      final totalTargetFrames = totalChunks * holdFrames;

      void reportProgress(int f, double? ratio) {
        if (f > 0 && totalTargetFrames > 0) {
          final r = ratio ?? (f / totalTargetFrames).clamp(0.0, 1.0);
          final currentP = 0.52 + 0.45 * r;
          final statusText = '正在压制视频: $f / $totalTargetFrames 帧 (${(r * 100).toInt()}%)';
          onProgress?.call(currentP, statusText);
          NotificationService.showProgress(
            id: 101,
            title: 'PixelDrop 正在生成视频...',
            body: statusText,
            progress: (currentP * 100).toInt(),
            maxProgress: 100,
          );
        }
      }

      final framesPattern = '${framesDir.path}/frame_%06d.png';
      final args = buildFfmpegArgs(
        framesPattern: framesPattern,
        outputPath: tempOutFile.path,
        fps: fps,
        width: width,
        height: height,
        crf: crf,
        gop: 60,
        includeSilentAudio: includeSilentAudio,
      );

      try {
        await FfmpegRunner.execute(
          args: args,
          totalExpectedFrames: totalTargetFrames,
          onProgress: reportProgress,
        );
      } catch (err) {
        if (includeSilentAudio) {
          // Graceful fallback to video-only if audio synthesis or filter fails
          final fallbackArgs = buildFfmpegArgs(
            framesPattern: framesPattern,
            outputPath: tempOutFile.path,
            fps: fps,
            width: width,
            height: height,
            crf: crf,
            gop: 60,
            includeSilentAudio: false,
          );
          await FfmpegRunner.execute(
            args: fallbackArgs,
            totalExpectedFrames: totalTargetFrames,
            onProgress: reportProgress,
          );
        } else {
          rethrow;
        }
      }
    } finally {
      // Clean up temporary PNG frames
      try {
        await framesDir.delete(recursive: true);
      } catch (_) {}
    }

    if (await tempOutFile.exists()) {
      // 6. Save final video into Download/PixelDrop/Videos
      final videosDir = await StorageHelper.getVideosDir();
      String targetPath = '${videosDir.path}/${filename}_pixel.mp4';
      int collision = 1;
      final dotIdx = filename.lastIndexOf('.');
      final base = dotIdx != -1 ? filename.substring(0, dotIdx) : filename;
      while (await File(targetPath).exists()) {
        targetPath = '${videosDir.path}/${base}_pixel_$collision.mp4';
        collision++;
      }

      final finalSavedVideo = await tempOutFile.copy(targetPath);
      try {
        await tempOutFile.delete();
      } catch (_) {}

      onProgress?.call(1.0, '视频已生成');
      await NotificationService.showComplete(
        id: 101,
        title: '视频生成完成',
        body: '已保存至 Download/PixelDrop/Videos',
      );

      return EncodeResult(
        videoFile: finalSavedVideo,
        filename: filename,
        originalSize: origSize,
        videoSize: finalSavedVideo.lengthSync(),
        sha256: fileSha256,
      );
    } else {
      throw Exception('FFmpeg 压制未生成视频文件');
    }
  }
}
