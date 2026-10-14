import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_min_gpl/return_code.dart';
import 'package:path_provider/path_provider.dart';
import '../models/pixel_packet.dart';

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

    // 4. Render frames to temp folder
    final tempDir = await getTemporaryDirectory();
    final framesDir = Directory(
      '${tempDir.path}/pixel_enc_${DateTime.now().millisecondsSinceEpoch}',
    );
    await framesDir.create(recursive: true);

    int frameIndex = 1;
    for (int idx = 0; idx < totalChunks; idx++) {
      final chunk = chunks[idx];
      final frameRaw = PixelProtocol.buildFrame(totalChunks, idx, chunk, frameCapacity);
      final bits = PixelProtocol.unpackBits(frameRaw);

      // Render small image: gridW x gridH (320 x 180)
      final smallImg = img.Image(width: gridW, height: gridH, numChannels: 1);
      int bitIdx = 0;
      for (int y = 0; y < gridH; y++) {
        for (int x = 0; x < gridW; x++) {
          final val = bits[bitIdx] == 1 ? 255 : 0;
          smallImg.setPixelR(x, y, val);
          bitIdx++;
        }
      }

      // Upscale to 1280x720 using Nearest Neighbor interpolation
      final scaledImg = img.copyResize(
        smallImg,
        width: width,
        height: height,
        interpolation: img.Interpolation.nearest,
      );

      final bmpBytes = img.encodeBmp(scaledImg);

      for (int h = 0; h < holdFrames; h++) {
        final framePath =
            '${framesDir.path}/frame_${frameIndex.toString().padLeft(6, '0')}.bmp';
        await File(framePath).writeAsBytes(bmpBytes, flush: true);
        frameIndex++;
      }

      final progress = 0.1 + ((idx + 1) / totalChunks) * 0.6;
      onProgress?.call(progress, '渲染像素点阵帧 (${idx + 1}/$totalChunks)...');
    }

    // 5. FFmpeg encode to MP4
    onProgress?.call(0.75, 'FFmpeg 正在压制 MP4 视频 (CRF $crf)...');
    final outVideoPath = '${tempDir.path}/${filename}_pixel.mp4';

    final ffmpegCmd = '-y -framerate $fps '
        '-i "${framesDir.path}/frame_%06d.bmp" '
        '-c:v libx264 -crf $crf -preset fast -tune stillimage -g 300 -pix_fmt yuv420p '
        '"$outVideoPath"';

    final session = await FFmpegKit.execute(ffmpegCmd);
    final returnCode = await session.getReturnCode();

    // Clean up BMP frames
    await framesDir.delete(recursive: true);

    if (ReturnCode.isSuccess(returnCode)) {
      onProgress?.call(1.0, '视频生成完毕！');
      return File(outVideoPath);
    } else {
      final logs = await session.getLogsAsString();
      throw Exception('FFmpeg 编码失败: $logs');
    }
  }
}
