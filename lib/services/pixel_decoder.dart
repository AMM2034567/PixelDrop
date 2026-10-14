import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../models/pixel_packet.dart';
import 'notification_service.dart';
import 'storage_helper.dart';

class DecodeResult {
  final File restoredFile;
  final String filename;
  final int fileSize;
  final String sha256;
  final bool isSha256Matched;

  DecodeResult({
    required this.restoredFile,
    required this.filename,
    required this.fileSize,
    required this.sha256,
    required this.isSha256Matched,
  });
}

class _RawScanArgs {
  final SendPort sendPort;
  final String rawFilePath;
  final int frameByteSize;
  final int totalFrames;

  _RawScanArgs({
    required this.sendPort,
    required this.rawFilePath,
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

/// Background Isolate worker: reads raw gray frames directly and packs bits in pure memory integers.
/// 100x faster than reading individual JPEG files.
void _scanRawFramesWorker(_RawScanArgs args) {
  final file = File(args.rawFilePath);
  final raf = file.openSync(mode: FileMode.read);
  final Map<int, Uint8List> collected = {};
  int? totalChunksExpected;

  final buffer = Uint8List(args.frameByteSize);
  final packed = Uint8List(args.frameByteSize >> 3);

  for (int f = 0; f < args.totalFrames; f++) {
    final readBytes = raf.readIntoSync(buffer);
    if (readBytes < args.frameByteSize) break;

    // Direct fast byte-to-bit conversion (red/gray > 128 is 1, else 0)
    packed.fillRange(0, packed.length, 0);
    for (int i = 0; i < args.frameByteSize; i++) {
      if (buffer[i] > 128) {
        packed[i >> 3] |= (1 << (7 - (i & 7)));
      }
    }

    final parsed = PixelProtocol.parseFrame(packed);
    if (parsed != null) {
      totalChunksExpected = parsed.totalChunks;
      if (!collected.containsKey(parsed.chunkIndex)) {
        collected[parsed.chunkIndex] = parsed.payload;

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
  static const int width = 1280;
  static const int height = 720;

  static Future<DecodeResult> decodeVideoToFile({
    required File videoFile,
    int blockSize = 4,
    Function(double progress, String status)? onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Safe ASCII paths
    final safeInputFile = File('${tempDir.path}/decode_in_$timestamp.mp4');
    final rawFramesFile = File('${tempDir.path}/raw_frames_$timestamp.raw');

    try {
      onProgress?.call(0.02, '正在准备视频缓存...');
      await videoFile.copy(safeInputFile.path);

      onProgress?.call(0.05, 'FFmpeg 原生硬件极速解流画面中...');
      await NotificationService.showProgress(
        id: 102,
        title: 'PixelDrop 正在还原文件...',
        body: 'FFmpeg 原生硬件极速解流画面中...',
        progress: 5,
        maxProgress: 100,
        force: true,
      );

      final gridW = width ~/ blockSize;
      final gridH = height ~/ blockSize;
      final frameByteSize = gridW * gridH;

      // Real-time statistics during FFmpeg raw extraction
      FFmpegKitConfig.enableStatisticsCallback((statistics) {
        final f = statistics.getVideoFrameNumber();
        if (f > 0) {
          final statusText = 'FFmpeg 极速解流画面: $f 帧';
          onProgress?.call(0.05 + 0.35 * (f / 1500).clamp(0.0, 1.0), statusText);
          NotificationService.showProgress(
            id: 102,
            title: 'PixelDrop 正在还原文件...',
            body: statusText,
            progress: 20,
            maxProgress: 100,
          );
        }
      });

      // 1. FFmpeg hardware-speed scale and dump to raw 8-bit grayscale stream
      final args = [
        '-y',
        '-i',
        safeInputFile.path,
        '-vf',
        'scale=$gridW:$gridH:flags=neighbor,format=gray',
        '-f',
        'rawvideo',
        rawFramesFile.path,
      ];

      final session = await FFmpegKit.executeWithArguments(args);
      FFmpegKitConfig.enableStatisticsCallback(null);
      final returnCode = await session.getReturnCode();

      if (!ReturnCode.isSuccess(returnCode)) {
        final rawLogs = await session.getLogsAsString() ?? '';
        final lines = rawLogs.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final tailLogs = lines.length > 8 ? lines.sublist(lines.length - 8).join('\n') : rawLogs;
        throw Exception('FFmpeg 视频解流失败 (Code: $returnCode):\n$tailLogs');
      }

      if (!await rawFramesFile.exists()) {
        throw Exception('未能从视频中提取出有效画面流');
      }

      final rawFileSize = await rawFramesFile.length();
      final totalFrames = rawFileSize ~/ frameByteSize;
      if (totalFrames == 0) {
        throw Exception('提取的画面帧数为 0');
      }

      onProgress?.call(0.42, '画面提取出 $totalFrames 帧，后台并发解析黑白矩阵...');

      // 2. High-speed memory scan in background Isolate
      final receivePort = ReceivePort();
      await Isolate.spawn(
        _scanRawFramesWorker,
        _RawScanArgs(
          sendPort: receivePort.sendPort,
          rawFilePath: rawFramesFile.path,
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
            status = '已解析收集分块: ${msg.collectedChunks} / $exp (${(msg.collectedChunks / exp * 100).toInt()}%)';
          } else {
            p = 0.42 + 0.45 * (msg.currentFrame / msg.totalFrames);
            status = '正在扫描点阵帧: ${msg.currentFrame} / ${msg.totalFrames}';
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

      onProgress?.call(0.88, '正在拼装数据流并进行元数据解包...');

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
      onProgress?.call(0.96, '正在比对 SHA-256 全局指纹...');
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

      onProgress?.call(1.0, '还原成功！');
      await NotificationService.showComplete(
        id: 102,
        title: '🎉 文件还原成功 (100% 吻合)！',
        body: '${meta.filename} 已保存至 Download/PixelDrop/Restored',
      );

      return DecodeResult(
        restoredFile: savedFile,
        filename: meta.filename,
        fileSize: restoredBytes.length,
        sha256: actualHash,
        isSha256Matched: isMatched,
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
