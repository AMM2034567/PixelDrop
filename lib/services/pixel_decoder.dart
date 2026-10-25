import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../models/pixel_packet.dart';
import 'ffmpeg_runner.dart';
import 'notification_service.dart';
import 'storage_helper.dart';

class DecodeResult {
  final File restoredFile;
  final String filename;
  final int fileSize;
  final String sha256;
  final bool isSha256Matched;
  final int detectedBlockSize;

  DecodeResult({
    required this.restoredFile,
    required this.filename,
    required this.fileSize,
    required this.sha256,
    required this.isSha256Matched,
    required this.detectedBlockSize,
  });
}

class _RawScanArgs {
  final SendPort sendPort;
  final String rawFilePath;
  final int gridW;
  final int gridH;
  final int frameByteSize;
  final int totalFrames;

  _RawScanArgs({
    required this.sendPort,
    required this.rawFilePath,
    required this.gridW,
    required this.gridH,
    required this.frameByteSize,
    required this.totalFrames,
  });
}

class _ScanProgressMsg {
  final int currentFrame;
  final int totalFrames;
  final int collectedChunks;
  final int? totalExpectedChunks;

  _ScanProgressMsg({
    required this.currentFrame,
    required this.totalFrames,
    required this.collectedChunks,
    required this.totalExpectedChunks,
  });
}

class _ScanDoneMsg {
  final Map<int, Uint8List> collectedChunks;
  final int? totalChunks;

  _ScanDoneMsg({
    required this.collectedChunks,
    required this.totalChunks,
  });
}

/// Background Isolate worker: reads raw RGB frames directly and unpacks bits with integer registers.
/// Supports both v2 (RGB 8-color, PD02) and legacy v1 (monochrome, PXL1).
void _scanRawFramesWorker(_RawScanArgs args) {
  final file = File(args.rawFilePath);
  final raf = file.openSync(mode: FileMode.read);
  final Map<int, Uint8List> collected = {};
  int? totalChunksExpected;
  int? detectedVersion; // 2 for RGB color, 1 for monochrome

  final int dotCount = args.gridW * args.gridH;
  final int colorCapacity = (dotCount * 3) ~/ 8;
  final int monoCapacity = dotCount ~/ 8;

  final buffer = Uint8List(args.frameByteSize);
  final packedColor = Uint8List(colorCapacity);
  final packedMono = Uint8List(monoCapacity);

  for (int f = 0; f < args.totalFrames; f++) {
    final readBytes = raf.readIntoSync(buffer);
    if (readBytes < args.frameByteSize) break;

    FrameParseResult? parsed;

    // 1. Try RGB color protocol (v2, PD02) if version not fixed to 1
    if (detectedVersion == null || detectedVersion == 2) {
      packedColor.fillRange(0, packedColor.length, 0);
      int acc = 0;
      int bitsInAcc = 0;
      int outIdx = 0;

      for (int i = 0; i < dotCount; i++) {
        final offset = i * 3;
        final rBit = buffer[offset] > 128 ? 4 : 0;
        final gBit = buffer[offset + 1] > 128 ? 2 : 0;
        final bBit = buffer[offset + 2] > 128 ? 1 : 0;
        final dotVal = rBit | gBit | bBit;

        acc = (acc << 3) | dotVal;
        bitsInAcc += 3;
        while (bitsInAcc >= 8) {
          bitsInAcc -= 8;
          if (outIdx < colorCapacity) {
            packedColor[outIdx++] = (acc >> bitsInAcc) & 0xFF;
          }
        }
        acc &= (1 << bitsInAcc) - 1;
      }
      if (bitsInAcc > 0 && outIdx < colorCapacity) {
        packedColor[outIdx++] = (acc << (8 - bitsInAcc)) & 0xFF;
      }

      parsed = PixelProtocol.parseFrame(packedColor);
      if (parsed != null) {
        detectedVersion = 2;
      }
    }

    // 2. If color parse failed and version not fixed to 2, test monochrome (v1, PXL1)
    if (parsed == null && (detectedVersion == null || detectedVersion == 1)) {
      packedMono.fillRange(0, packedMono.length, 0);
      for (int i = 0; i < dotCount; i++) {
        if (buffer[i * 3] > 128) {
          packedMono[i >> 3] |= (1 << (7 - (i & 7)));
        }
      }
      parsed = PixelProtocol.parseFrame(packedMono);
      if (parsed != null) {
        detectedVersion = 1;
      }
    }

    if (parsed != null) {
      totalChunksExpected = parsed.totalChunks;
      if (!collected.containsKey(parsed.chunkIndex)) {
        collected[parsed.chunkIndex] = Uint8List.fromList(parsed.payload);

        // Send progress update
        args.sendPort.send(_ScanProgressMsg(
          currentFrame: f + 1,
          totalFrames: args.totalFrames,
          collectedChunks: collected.length,
          totalExpectedChunks: totalChunksExpected,
        ));
      }

      if (collected.length == totalChunksExpected) {
        break;
      }
    } else if (f % 20 == 0) {
      // Periodic progress even if skipping redundant duplicate hold frames
      args.sendPort.send(_ScanProgressMsg(
        currentFrame: f + 1,
        totalFrames: args.totalFrames,
        collectedChunks: collected.length,
        totalExpectedChunks: totalChunksExpected,
      ));
    }
  }

  raf.closeSync();
  args.sendPort.send(_ScanDoneMsg(
    collectedChunks: collected,
    totalChunks: totalChunksExpected,
  ));
}

class PixelDecoderService {
  static const int defaultWidth = 1920;
  static const int defaultHeight = 1080;

  // Preserved for backwards compatibility
  static const int width = 1280;
  static const int height = 720;

  static bool _isValidRgbOrMonoFrame(Uint8List buffer, int gridW, int gridH) {
    if (gridW <= 0 || gridH <= 0) return false;
    final int dotCount = gridW * gridH;
    if (buffer.length < dotCount * 3) return false;
    final int colorCapacity = (dotCount * 3) ~/ 8;
    final int monoCapacity = dotCount ~/ 8;

    // 1. Try RGB color protocol (v2, PD02)
    final packedColor = Uint8List(colorCapacity);
    int acc = 0;
    int bitsInAcc = 0;
    int outIdx = 0;

    for (int i = 0; i < dotCount; i++) {
      final offset = i * 3;
      final rBit = buffer[offset] > 128 ? 4 : 0;
      final gBit = buffer[offset + 1] > 128 ? 2 : 0;
      final bBit = buffer[offset + 2] > 128 ? 1 : 0;
      final dotVal = rBit | gBit | bBit;

      acc = (acc << 3) | dotVal;
      bitsInAcc += 3;
      while (bitsInAcc >= 8) {
        bitsInAcc -= 8;
        if (outIdx < colorCapacity) {
          packedColor[outIdx++] = (acc >> bitsInAcc) & 0xFF;
        }
      }
      acc &= (1 << bitsInAcc) - 1;
    }
    if (bitsInAcc > 0 && outIdx < colorCapacity) {
      packedColor[outIdx++] = (acc << (8 - bitsInAcc)) & 0xFF;
    }

    if (PixelProtocol.parseFrame(packedColor) != null) {
      return true;
    }

    // 2. Try monochrome protocol (v1, PXL1)
    final packedMono = Uint8List(monoCapacity);
    for (int i = 0; i < dotCount; i++) {
      if (buffer[i * 3] > 128) {
        packedMono[i >> 3] |= (1 << (7 - (i & 7)));
      }
    }

    return PixelProtocol.parseFrame(packedMono) != null;
  }

  /// Fast probe for candidate block sizes: [4, 2, 8]
  static Future<int> _probeBlockSize({
    required String videoPath,
    required int targetWidth,
    required int targetHeight,
    required Directory tempDir,
    required int timestamp,
    Function(double progress, String status)? onProgress,
  }) async {
    const candidates = [4, 2, 8];
    for (final candidate in candidates) {
      final gridW = targetWidth ~/ candidate;
      final gridH = targetHeight ~/ candidate;
      if (gridW <= 0 || gridH <= 0) continue;

      onProgress?.call(0.06, '正在自动识别点阵规格 (尝试 ${candidate}x$candidate)...');
      final frameByteSize = gridW * gridH * 3;
      final probeRawFile = File(
        '${tempDir.path}/probe_${timestamp}_${candidate}_${DateTime.now().microsecondsSinceEpoch}.raw',
      );

      try {
        final args = [
          '-y',
          '-noautorotate',
          '-i',
          videoPath,
          '-an',
          '-vframes',
          '2',
          '-vf',
          'format=rgb24,scale=$gridW:$gridH:flags=area',
          '-f',
          'rawvideo',
          probeRawFile.path,
        ];

        await FfmpegRunner.execute(args: args);

        if (await probeRawFile.exists()) {
          final probeBytes = await probeRawFile.readAsBytes();
          final availableFrames = probeBytes.length ~/ frameByteSize;
          for (int f = 0; f < availableFrames && f < 2; f++) {
            final frameSlice = Uint8List.sublistView(
              probeBytes,
              f * frameByteSize,
              (f + 1) * frameByteSize,
            );
            if (_isValidRgbOrMonoFrame(frameSlice, gridW, gridH)) {
              return candidate;
            }
          }
        }
      } catch (_) {
        // Probe execution failed for this candidate, test next
      } finally {
        try {
          if (await probeRawFile.exists()) {
            await probeRawFile.delete();
          }
        } catch (_) {}
      }
    }

    throw Exception(
      '无法自动识别点阵规格，请确认视频由 PixelDrop 生成，或手动指定采样规格（2x2、4x4 或 8x8）后重试',
    );
  }

  static Future<DecodeResult> decodeVideoToFile({
    required File videoFile,
    int? blockSize,
    int? width,
    int? height,
    Function(double progress, String status)? onProgress,
  }) async {
    Directory tempDir;
    try {
      tempDir = await getTemporaryDirectory();
    } catch (_) {
      tempDir = Directory.systemTemp;
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Safe ASCII paths
    final safeInputFile = File('${tempDir.path}/decode_in_$timestamp.mp4');
    final rawFramesFile = File('${tempDir.path}/raw_frames_$timestamp.raw');

    try {
      onProgress?.call(0.02, '正在读取视频文件...');
      await videoFile.copy(safeInputFile.path);

      onProgress?.call(0.05, '正在分析视频规格与画面...');
      await NotificationService.showProgress(
        id: 102,
        title: 'PixelDrop 正在还原文件...',
        body: '正在分析视频规格与画面...',
        progress: 5,
        maxProgress: 100,
        force: true,
      );

      int targetWidth = width ?? defaultWidth;
      int targetHeight = height ?? defaultHeight;

      // Auto-detect resolution from video metadata if not explicitly provided
      if (width == null || height == null) {
        try {
          final dims = await FfmpegRunner.getVideoDimensions(safeInputFile.path);
          if (dims != null) {
            targetWidth = dims.$1;
            targetHeight = dims.$2;
          }
        } catch (_) {}
      }

      int effectiveBlockSize;
      if (blockSize != null && blockSize > 0) {
        effectiveBlockSize = blockSize;
      } else {
        effectiveBlockSize = await _probeBlockSize(
          videoPath: safeInputFile.path,
          targetWidth: targetWidth,
          targetHeight: targetHeight,
          tempDir: tempDir,
          timestamp: timestamp,
          onProgress: onProgress,
        );
        onProgress?.call(
          0.08,
          '已自动识别点阵规格: ${effectiveBlockSize}x$effectiveBlockSize 像素',
        );
      }

      final gridW = targetWidth ~/ effectiveBlockSize;
      final gridH = targetHeight ~/ effectiveBlockSize;
      final frameByteSize = gridW * gridH * 3; // RGB 24-bit

      // 1. FFmpeg hardware-speed scale and dump to raw 24-bit RGB stream
      final args = [
        '-y',
        '-noautorotate',
        '-i',
        safeInputFile.path,
        '-an',
        '-vf',
        'format=rgb24,scale=$gridW:$gridH:flags=area',
        '-f',
        'rawvideo',
        rawFramesFile.path,
      ];

      await FfmpegRunner.execute(
        args: args,
        onProgress: (f, _) {
          if (f > 0) {
            final statusText = '正在提取视频帧: $f 帧';
            onProgress?.call(0.05 + 0.35 * (f / 1500).clamp(0.0, 1.0), statusText);
            NotificationService.showProgress(
              id: 102,
              title: 'PixelDrop 正在还原文件...',
              body: statusText,
              progress: 20,
              maxProgress: 100,
            );
          }
        },
      );

      if (!await rawFramesFile.exists()) {
        throw Exception('未能从视频中提取出有效画面流');
      }

      final rawFileSize = await rawFramesFile.length();
      final totalFrames = rawFileSize ~/ frameByteSize;
      if (totalFrames == 0) {
        throw Exception('提取的画面帧数为 0（分辨率或块大小可能不匹配）');
      }

      onProgress?.call(0.42, '已提取 $totalFrames 帧画面，正在解析点阵数据...');

      // 2. High-speed memory scan in background Isolate
      final receivePort = ReceivePort();
      await Isolate.spawn(
        _scanRawFramesWorker,
        _RawScanArgs(
          sendPort: receivePort.sendPort,
          rawFilePath: rawFramesFile.path,
          gridW: gridW,
          gridH: gridH,
          frameByteSize: frameByteSize,
          totalFrames: totalFrames,
        ),
      );

      Map<int, Uint8List> collected = {};
      int? totalExpected;

      await for (final msg in receivePort) {
        if (msg is _ScanProgressMsg) {
          final exp = msg.totalExpectedChunks;
          double p;
          String status;
          if (exp != null && exp > 0) {
            p = 0.42 + 0.45 * (msg.collectedChunks / exp);
            status = '解析进度: ${msg.collectedChunks} / $exp 块 (${(msg.collectedChunks / exp * 100).toInt()}%)';
          } else {
            p = 0.42 + 0.45 * (msg.currentFrame / msg.totalFrames);
            status = '正在解析: ${msg.currentFrame} / ${msg.totalFrames} 帧';
          }
          onProgress?.call(p, status);
          await NotificationService.showProgress(
            id: 102,
            title: 'PixelDrop 正在还原文件...',
            body: status,
            progress: (p * 100).toInt(),
            maxProgress: 100,
          );
        } else if (msg is _ScanDoneMsg) {
          collected = msg.collectedChunks;
          totalExpected = msg.totalChunks;
          break;
        }
      }

      if (totalExpected == null || collected.length < totalExpected) {
        throw Exception(
          '未能集齐全部数据分块（已收集 ${collected.length}/${totalExpected ?? '?'}，共扫描 $totalFrames 帧）',
        );
      }

      for (int i = 0; i < totalExpected; i++) {
        if (!collected.containsKey(i)) {
          throw Exception('数据分块不完整，缺失分块索引: $i（共 $totalExpected 块）');
        }
      }

      onProgress?.call(0.88, '正在校验并组装文件数据...');

      // 3. Reconstruct full stream
      final totalLen = collected.values.fold<int>(0, (sum, c) => sum + c.length);
      final fullStream = Uint8List(totalLen);
      int currentOffset = 0;
      for (int i = 0; i < totalExpected; i++) {
        final chunk = collected[i]!;
        fullStream.setRange(currentOffset, currentOffset + chunk.length, chunk);
        currentOffset += chunk.length;
      }

      // 4. Parse metadata header
      final meta = PixelProtocol.parseMetaHeader(fullStream);

      onProgress?.call(0.92, '正在解压文件数据...');
      List<int> restoredBytes;
      if (meta.useGzip) {
        restoredBytes = GZipDecoder().decodeBytes(meta.body);
      } else {
        restoredBytes = meta.body;
      }

      // 5. SHA-256 integrity verification
      onProgress?.call(0.96, '正在校验 SHA-256 完整性...');
      final actualHash = sha256.convert(restoredBytes).toString();
      final isMatched = actualHash.toLowerCase() == meta.sha256.toLowerCase();

      // 6. Save restored file to Download/PixelDrop/Restored
      final restoredDir = await StorageHelper.getRestoredDir();
      String targetPath = '${restoredDir.path}/${meta.filename}';
      int collision = 1;
      final dotIdx = meta.filename.lastIndexOf('.');
      final base = dotIdx != -1 ? meta.filename.substring(0, dotIdx) : meta.filename;
      final ext = dotIdx != -1 ? meta.filename.substring(dotIdx) : '';

      while (await File(targetPath).exists()) {
        targetPath = '${restoredDir.path}/${base}_restored_$collision$ext';
        collision++;
      }

      final savedFile = File(targetPath);
      await savedFile.writeAsBytes(restoredBytes, flush: true);

      onProgress?.call(1.0, '文件已还原');
      await NotificationService.showComplete(
        id: 102,
        title: '文件还原完成',
        body: '${meta.filename} 已保存至 Download/PixelDrop/Restored',
      );

      return DecodeResult(
        restoredFile: savedFile,
        filename: meta.filename,
        fileSize: restoredBytes.length,
        sha256: actualHash,
        isSha256Matched: isMatched,
        detectedBlockSize: effectiveBlockSize,
      );
    } finally {
      // Clean up temporary extraction frames and safe input copy
      try {
        if (await safeInputFile.exists()) {
          await safeInputFile.delete();
        }
      } catch (_) {}
      try {
        if (await rawFramesFile.exists()) {
          await rawFramesFile.delete();
        }
      } catch (_) {}
    }
  }
}
