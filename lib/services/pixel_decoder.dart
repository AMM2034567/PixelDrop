import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../models/pixel_packet.dart';

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

class _ScanParams {
  final List<String> framePaths;
  final int blockSize;
  final int gridW;
  final int gridH;
  final int half;

  _ScanParams({
    required this.framePaths,
    required this.blockSize,
    required this.gridW,
    required this.gridH,
    required this.half,
  });
}

class _ScanResult {
  final Map<int, Uint8List> collectedChunks;
  final int? totalChunks;

  _ScanResult({
    required this.collectedChunks,
    required this.totalChunks,
  });
}

/// Background Isolate worker for fast frame reading and center-pixel sampling.
_ScanResult _scanFramesWorker(_ScanParams params) {
  final Map<int, Uint8List> collected = {};
  int? totalChunksExpected;

  for (final path in params.framePaths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    final frameImg = img.decodeJpg(bytes);
    if (frameImg == null) continue;

    final bits = <int>[];
    for (int y = 0; y < params.gridH; y++) {
      final py = y * params.blockSize + params.half;
      for (int x = 0; x < params.gridW; x++) {
        final px = x * params.blockSize + params.half;
        final pixel = frameImg.getPixel(px, py);
        // Red channel / Luma > 128 => 1, else 0
        bits.add(pixel.r > 128 ? 1 : 0);
      }
    }

    final rawData = PixelProtocol.packBits(bits);
    final parsed = PixelProtocol.parseFrame(rawData);

    if (parsed != null) {
      totalChunksExpected = parsed.totalChunks;
      if (!collected.containsKey(parsed.chunkIndex)) {
        collected[parsed.chunkIndex] = parsed.payload;
      }

      // Early exit if all chunks are collected
      if (collected.length == totalChunksExpected) {
        break;
      }
    }
  }

  return _ScanResult(
    collectedChunks: collected,
    totalChunks: totalChunksExpected,
  );
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
    final extractDir = Directory(
      '${tempDir.path}/pixel_dec_${DateTime.now().millisecondsSinceEpoch}',
    );
    await extractDir.create(recursive: true);

    onProgress?.call(0.1, 'FFmpeg 正在快速抽帧...');

    // 1. FFmpeg extract frames as high-speed JPG (-q:v 2)
    final extractCmd = '-y -i "${videoFile.path}" -q:v 2 "${extractDir.path}/frame_%06d.jpg"';
    final session = await FFmpegKit.execute(extractCmd);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      final logs = await session.getLogsAsString();
      throw Exception('FFmpeg 视频抽帧失败: $logs');
    }

    final frameFiles = extractDir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final totalFrames = frameFiles.length;
    if (totalFrames == 0) {
      throw Exception('未能从视频中提取出有效画面帧');
    }

    onProgress?.call(0.35, '提取出 $totalFrames 帧，后台并发解析黑白矩阵...');

    final gridW = width ~/ blockSize;
    final gridH = height ~/ blockSize;
    final half = blockSize ~/ 2;
    final framePaths = frameFiles.map((f) => f.path).toList();

    // 2. Sample pixels in background Isolate (100% smooth UI)
    final scanResult = await compute(
      _scanFramesWorker,
      _ScanParams(
        framePaths: framePaths,
        blockSize: blockSize,
        gridW: gridW,
        gridH: gridH,
        half: half,
      ),
    );

    // Clean up extracted frames
    try {
      await extractDir.delete(recursive: true);
    } catch (_) {}

    final totalExpected = scanResult.totalChunks;
    final collected = scanResult.collectedChunks;

    if (totalExpected == null || collected.length < totalExpected) {
      throw Exception(
        '未能集齐全部数据分块（已收集 ${collected.length}/${totalExpected ?? '?'}）',
      );
    }

    onProgress?.call(0.85, '正在拼装数据流并进行元数据解包...');

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

    onProgress?.call(0.9, '正在解压文件数据...');
    List<int> restoredBytes;
    if (meta.useGzip) {
      restoredBytes = GZipDecoder().decodeBytes(meta.body);
    } else {
      restoredBytes = meta.body;
    }

    // 5. SHA-256 integrity verification
    onProgress?.call(0.95, '正在比对 SHA-256 全局指纹...');
    final actualHash = sha256.convert(restoredBytes).toString();
    final isMatched = actualHash.toLowerCase() == meta.sha256.toLowerCase();

    // 6. Save restored file to application documents dir
    final appDir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${appDir.path}/PixelDropRestored');
    await outDir.create(recursive: true);

    String targetPath = '${outDir.path}/${meta.filename}';
    int collision = 1;
    final dotIdx = meta.filename.lastIndexOf('.');
    final base = dotIdx != -1 ? meta.filename.substring(0, dotIdx) : meta.filename;
    final ext = dotIdx != -1 ? meta.filename.substring(dotIdx) : '';

    while (await File(targetPath).exists()) {
      targetPath = '${outDir.path}/${base}_restored_$collision$ext';
      collision++;
    }

    final savedFile = File(targetPath);
    await savedFile.writeAsBytes(restoredBytes, flush: true);

    onProgress?.call(1.0, '还原成功！');

    return DecodeResult(
      restoredFile: savedFile,
      filename: meta.filename,
      fileSize: restoredBytes.length,
      sha256: actualHash,
      isSha256Matched: isMatched,
    );
  }
}
