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

class _RenderIsolateArgs {
  final SendPort sendPort;
  final List<Uint8List> chunks;
  final int totalChunks;
  final int frameCapacity;
  final int gridW;
  final int gridH;
  final int holdFrames;
  final int version;
  final String framesDirPath;

  _RenderIsolateArgs({
    required this.sendPort,
    required this.chunks,
    required this.totalChunks,
    required this.frameCapacity,
    required this.gridW,
    required this.gridH,
    required this.holdFrames,
    required this.version,
    required this.framesDirPath,
  });
}

/// Background Isolate worker for fast frame generation with progress reporting.
void _renderFramesIsolateWorker(_RenderIsolateArgs args) {
  int frameIndex = 1;
  final dotCount = args.gridW * args.gridH;

  for (int idx = 0; idx < args.totalChunks; idx++) {
    final chunk = args.chunks[idx];
    final frameRaw = PixelProtocol.buildFrame(
      args.totalChunks,
      idx,
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

    final pngBytes = img.encodePng(smallImg);

    for (int h = 0; h < args.holdFrames; h++) {
      final framePath =
          '${args.framesDirPath}/frame_${frameIndex.toString().padLeft(6, '0')}.png';
      File(framePath).writeAsBytesSync(pngBytes, flush: true);
      frameIndex++;
    }

    // Send progress every 10 chunks or on last chunk
    if (idx % 10 == 0 || idx == args.totalChunks - 1) {
      args.sendPort.send(idx + 1);
    }
  }

  // Done signal
  args.sendPort.send(null);
}

class PixelEncoderService {
  static const int defaultWidth = 1920;
  static const int defaultHeight = 1080;
  static const int defaultFps = 30;
  static const int defaultHoldFrames = 1;
  static const int defaultCrf = 18;

  // Preserved for backwards compatibility
  static const int width = 1280;
  static const int height = 720;

  static Future<EncodeResult> encodeFileToVideo({
    required File inputFile,
    int blockSize = 4,
    int width = defaultWidth,
    int height = defaultHeight,
    int fps = defaultFps,
    int holdFrames = defaultHoldFrames,
    int crf = defaultCrf,
    int version = 2,
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

    // 4. Render frames in background Isolate with real-time progress
    Directory tempDir;
    try {
      tempDir = await getTemporaryDirectory();
    } catch (_) {
      tempDir = Directory.systemTemp;
    }
    final sessionTimestamp = DateTime.now().millisecondsSinceEpoch;
    final framesDir = Directory('${tempDir.path}/pixel_enc_$sessionTimestamp');
    await framesDir.create(recursive: true);

    onProgress?.call(0.05, '正在生成点阵帧 ($totalChunks 帧)...');

    final receivePort = ReceivePort();
    await Isolate.spawn(
      _renderFramesIsolateWorker,
      _RenderIsolateArgs(
        sendPort: receivePort.sendPort,
        chunks: chunks,
        totalChunks: totalChunks,
        frameCapacity: frameCapacity,
        gridW: gridW,
        gridH: gridH,
        holdFrames: holdFrames,
        version: version,
        framesDirPath: framesDir.path,
      ),
    );

    await for (final msg in receivePort) {
      if (msg is int) {
        final progressRatio = msg / totalChunks;
        final currentP = 0.05 + 0.45 * progressRatio;
        final statusText = '生成点阵帧: $msg / $totalChunks (${(progressRatio * 100).toInt()}%)';
        onProgress?.call(currentP, statusText);
        await NotificationService.showProgress(
          id: 101,
          title: 'PixelDrop 正在生成视频...',
          body: statusText,
          progress: (currentP * 100).toInt(),
          maxProgress: 100,
        );
      } else if (msg == null) {
        break;
      }
    }

    // 5. FFmpeg encode to MP4 with hardware scaling and real-time statistics
    onProgress?.call(0.52, '正在压制 MP4 视频...');
    final tempOutFile = File('${tempDir.path}/temp_enc_$sessionTimestamp.mp4');
    final totalTargetFrames = totalChunks * holdFrames;

    final args = [
      '-y',
      '-framerate',
      '$fps',
      '-i',
      '${framesDir.path}/frame_%06d.png',
      '-vf',
      'scale=$width:$height:flags=neighbor',
      '-c:v',
      'libx264',
      '-crf',
      '$crf',
      '-preset',
      'fast',
      '-tune',
      'stillimage',
      '-g',
      '300',
      '-pix_fmt',
      'yuv420p',
      tempOutFile.path,
    ];

    try {
      await FfmpegRunner.execute(
        args: args,
        totalExpectedFrames: totalTargetFrames,
        onProgress: (f, ratio) {
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
        },
      );
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
