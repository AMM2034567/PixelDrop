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

class _RenderParams {
  final List<Uint8List> chunks;
  final int totalChunks;
  final int frameCapacity;
  final int gridW;
  final int gridH;
  final int holdFrames;
  final String framesDirPath;

  _RenderParams({
    required this.chunks,
    required this.totalChunks,
    required this.frameCapacity,
    required this.gridW,
    required this.gridH,
    required this.holdFrames,
    required this.framesDirPath,
  });
}

/// Background Isolate worker for fast frame generation.
/// Uses 3-channel RGB so black is (0,0,0) and white is (255,255,255).
/// Generates small grid-size images (e.g. 320x180) in milliseconds;
/// FFmpeg will scale them up to 1280x720 in hardware with flags=neighbor.
void _renderFramesWorker(_RenderParams params) {
  int frameIndex = 1;

  for (int idx = 0; idx < params.totalChunks; idx++) {
    final chunk = params.chunks[idx];
    final frameRaw = PixelProtocol.buildFrame(
      params.totalChunks,
      idx,
      chunk,
      params.frameCapacity,
    );
    final bits = PixelProtocol.unpackBits(frameRaw);

    // 3-channel RGB image (320x180 or 160x90)
    final smallImg = img.Image(
      width: params.gridW,
      height: params.gridH,
      numChannels: 3,
    );

    int bitIdx = 0;
    for (int y = 0; y < params.gridH; y++) {
      for (int x = 0; x < params.gridW; x++) {
        final val = bits[bitIdx] == 1 ? 255 : 0;
        smallImg.setPixelRgb(x, y, val, val, val);
        bitIdx++;
      }
    }

    final pngBytes = img.encodePng(smallImg);

    for (int h = 0; h < params.holdFrames; h++) {
      final framePath =
          '${params.framesDirPath}/frame_${frameIndex.toString().padLeft(6, '0')}.png';
      File(framePath).writeAsBytesSync(pngBytes, flush: true);
      frameIndex++;
    }
  }
}

class PixelEncoderService {
  static const int width = 1280;
  static const int height = 720;

  static Future<File> encodeFileToVideo({
    required File inputFile,
    int blockSize = 4,
    int fps = 10,
    int holdFrames = 2,
    int crf = 22,
    Function(double progress, String status)? onProgress,
  }) async {
    final rawBytes = await inputFile.readAsBytes();
    final filename = inputFile.uri.pathSegments.last;
    final origSize = rawBytes.length;
    final fileSha256 = sha256.convert(rawBytes).toString();

    onProgress?.call(0.05, '正在自适应 Gzip 压缩...');

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
    final frameCapacity = (gridW * gridH) ~/ 8; // Total bytes capacity per frame
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

    // 4. Render frames in background Isolate (keeps UI 100% fluid)
    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory(
      '${tempDir.path}/pixel_enc_${DateTime.now().millisecondsSinceEpoch}',
    );
    await framesDir.create(recursive: true);

    onProgress?.call(0.2, '后台快速生成点阵帧 ($totalChunks 分块)...');

    await compute(
      _renderFramesWorker,
      _RenderParams(
        chunks: chunks,
        totalChunks: totalChunks,
        frameCapacity: frameCapacity,
        gridW: gridW,
        gridH: gridH,
        holdFrames: holdFrames,
        framesDirPath: framesDir.path,
      ),
    );

    // 5. FFmpeg encode to MP4 with hardware-speed nearest neighbor scaling
    onProgress?.call(0.65, 'FFmpeg 正在压制 MP4 视频...');
    final outVideoPath = '${tempDir.path}/${filename}_pixel.mp4';

    final ffmpegCmd = '-y -framerate $fps '
        '-i "${framesDir.path}/frame_%06d.png" '
        '-vf "scale=$width:$height:flags=neighbor" '
        '-c:v libx264 -crf $crf -preset fast -tune stillimage -g 300 -pix_fmt yuv420p '
        '"$outVideoPath"';

    final session = await FFmpegKit.execute(ffmpegCmd);
    final returnCode = await session.getReturnCode();

    // Clean up PNG frames
    try {
      await framesDir.delete(recursive: true);
    } catch (_) {}

    if (ReturnCode.isSuccess(returnCode)) {
      onProgress?.call(1.0, '视频生成完毕！');
      return File(outVideoPath);
    } else {
      final logs = await session.getLogsAsString();
      throw Exception('FFmpeg 编码失败: $logs');
    }
  }
}
