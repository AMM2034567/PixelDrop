import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_drop/main.dart';
import 'package:pixel_drop/models/pixel_packet.dart';
import 'package:pixel_drop/screens/decode_screen.dart';
import 'package:pixel_drop/screens/encode_screen.dart';
import 'package:pixel_drop/services/ffmpeg_runner.dart';
import 'package:pixel_drop/services/pixel_decoder.dart';
import 'package:pixel_drop/services/pixel_encoder.dart';
import 'package:pixel_drop/services/pixel_fec.dart';
import 'package:pixel_drop/services/sharing_service.dart';

void main() {
  group('Mobile System-Level Share Intent & Routing Tests', () {
    test('SharingService.isVideoFile detects video types and rejects non-video types', () {
      expect(SharingService.isVideoFile('/storage/emulated/0/Download/video.mp4'), isTrue);
      expect(SharingService.isVideoFile('C:\\Users\\test\\output.MKV'), isTrue);
      expect(SharingService.isVideoFile('/home/user/pixel.mov'), isTrue);
      expect(SharingService.isVideoFile('clip.AVI'), isTrue);

      expect(SharingService.isVideoFile('/storage/test.zip'), isFalse);
      expect(SharingService.isVideoFile('archive.tar.gz'), isFalse);
      expect(SharingService.isVideoFile('photo.png'), isFalse);
      expect(SharingService.isVideoFile('document.pdf'), isFalse);
      expect(SharingService.isVideoFile('data.bin'), isFalse);
    });

    testWidgets('Sharing non-video file auto-routes to EncodeScreen and populates selection card', (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('share_test_enc_');
      final testFile = File('${tempDir.path}/shared_document.pdf')..writeAsStringSync('Hello PixelDrop Share');

      await tester.pumpWidget(const PixelDropApp());
      await tester.pumpAndSettle();

      // Initially on EncodeScreen
      expect(find.text('选择待转换文件'), findsOneWidget);

      // Dispatch shared non-video file
      SharingService.dispatchSharedFilesForTesting([testFile.path]);
      await tester.pumpAndSettle();

      // Should remain on/navigate to EncodeScreen and show the imported file card
      expect(find.text('shared_document.pdf'), findsOneWidget);
      expect(find.text('开始生成视频'), findsOneWidget);

      tempDir.deleteSync(recursive: true);
    });

    testWidgets('Sharing .mp4 pixel video auto-routes to DecodeScreen and loads video card', (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('share_test_dec_');
      final testVideo = File('${tempDir.path}/shared_pixel_video.mp4')..writeAsBytesSync(List.filled(1024, 0));

      await tester.pumpWidget(const PixelDropApp());
      await tester.pumpAndSettle();

      // Initially on EncodeScreen
      expect(find.text('文件转视频'), findsWidgets);

      // Dispatch shared .mp4 video file
      SharingService.dispatchSharedFilesForTesting([testVideo.path]);
      await tester.pumpAndSettle();

      // Should automatically switch to DecodeScreen and display loaded video
      expect(find.text('shared_pixel_video.mp4'), findsOneWidget);
      expect(find.text('开始还原文件'), findsOneWidget);

      tempDir.deleteSync(recursive: true);
    });
  });

  group('Frame-level FEC & Time Redundancy UI Tests', () {
    testWidgets('EncodeScreen renders FEC fault-tolerance segmented buttons and updates state', (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: EncodeScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify FEC section title
      expect(find.text('抗掉帧容灾 (帧级 FEC 纠删码)'), findsOneWidget);

      // Verify segments
      expect(find.text('关闭 (0%)'), findsOneWidget);
      expect(find.text('轻量 (10%)'), findsOneWidget);
      expect(find.text('标准 (20%)'), findsOneWidget);
      expect(find.text('强抗损 (30%)'), findsOneWidget);

      // Default is 20%
      expect(find.textContaining('20% 容灾（默认推荐）'), findsOneWidget);

      // Tap 30% segment
      await tester.tap(find.text('强抗损 (30%)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('30% 容灾（强抗损）'), findsOneWidget);

      // Tap 0% segment
      await tester.tap(find.text('关闭 (0%)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('0% 容灾：仅传输原数据帧'), findsOneWidget);
    });

    testWidgets('DecodeScreen renders FEC recovery banner and detail row when fecRecoveredCount > 0', (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('fec_ui_test_');
      final dummyRestored = File('${tempDir.path}/recovered.txt')..writeAsStringSync('Restored via FEC');

      final resultWithFec = DecodeResult(
        restoredFile: dummyRestored,
        filename: 'recovered.txt',
        fileSize: 16,
        sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        isSha256Matched: true,
        detectedBlockSize: 4,
        fecRecoveredCount: 3,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DecodeScreen(initialResult: resultWithFec),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify FEC banner and detail row
      expect(find.textContaining('抗掉帧 FEC 纠删码生效：成功恢复 3 个丢失帧'), findsOneWidget);
      expect(find.text('已成功复原 3 个丢帧 (FEC)'), findsOneWidget);

      tempDir.deleteSync(recursive: true);
    });
  });

  group('End-to-End FEC Encoding, Dropped-Frames Disaster Recovery & Integrity Tests', () {
    test('PixelProtocol buildFecFrame and parseFrame verifies CRC and fields', () {
      final parityData = Uint8List.fromList([10, 20, 30, 40, 50, 60]);
      final fecFrame = PixelProtocol.buildFecFrame(
        dataTotal: 12,
        fecIndex: 1,
        fecTotal: 3,
        lastChunkLen: 6,
        parityChunk: parityData,
        targetCapacity: 24, // 16 header + 8 payload
        version: 2,
      );

      expect(fecFrame.length, 24);
      final parsed = PixelProtocol.parseFrame(fecFrame);
      expect(parsed, isNotNull);
      expect(parsed!.isFec, isTrue);
      expect(parsed.totalChunks, 12);
      expect(parsed.fecIndex, 1);
      expect(parsed.fecTotal, 3);
      expect(parsed.lastChunkLen, 6);
      expect(parsed.version, 2);
    });

    test('End-to-End: Video encoded with 20% FEC and guard frames restores bit-exact with 100% SHA-256 match', () async {
      final tempDir = await Directory.systemTemp.createTemp('fec_e2e_normal_');
      try {
        final samplePayload = Uint8List.fromList(
          List.generate(2000, (i) => (i * 31 + 17) % 256),
        );
        final expectedSha = sha256.convert(samplePayload).toString();

        final srcFile = File('${tempDir.path}/fec_test_data.bin');
        await srcFile.writeAsBytes(samplePayload);

        // Encode with 20% FEC redundancy and guard frames
        final encResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: srcFile,
          blockSize: 4,
          width: 1280,
          height: 720,
          fps: 30,
          holdFrames: 1,
          fecPercent: 20,
          includeGuardFrames: true,
        );

        expect(encResult.videoFile.existsSync(), isTrue);
        expect(encResult.sha256, equals(expectedSha));

        // Decode normally
        final decResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encResult.videoFile,
          blockSize: 4,
        );

        expect(decResult.restoredFile.existsSync(), isTrue);
        expect(decResult.isSha256Matched, isTrue);
        expect(decResult.sha256, equals(expectedSha));

        final restoredBytes = await decResult.restoredFile.readAsBytes();
        expect(restoredBytes, equals(samplePayload));

        // Cleanup
        try {
          await encResult.videoFile.delete();
          await decResult.restoredFile.delete();
        } catch (_) {}
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('Simulated Dropped Frames: Missing frames are 100% reconstructed via FEC and verify SHA-256', () async {
      // Simulate raw stream data sliced into 6 chunks
      const cap = 200;
      final rng = Random(999);
      final rawDataChunks = List.generate(6, (i) {
        final len = (i == 5) ? 142 : cap;
        return Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256)));
      });

      // Generate 2 FEC parity packets (~33% redundancy)
      final fecPackets = PixelFec.generateParityPackets(
        dataChunks: rawDataChunks,
        redundancyPercent: 33,
        chunkPayloadCapacity: cap,
      );

      expect(fecPackets.length, 2);

      // Simulate network dropping frame 0 (head truncation) and frame 3 (middle drop)
      final receivedData = <int, Uint8List>{
        1: rawDataChunks[1],
        2: rawDataChunks[2],
        4: rawDataChunks[4],
        5: rawDataChunks[5],
      };

      // Both parity packets successfully received
      final recovered = PixelFec.recoverMissingData(
        totalDataChunks: 6,
        collectedDataChunks: receivedData,
        collectedFecPackets: fecPackets,
        chunkPayloadCapacity: cap,
      );

      expect(recovered.length, 6);
      for (int i = 0; i < 6; i++) {
        expect(recovered[i], rawDataChunks[i], reason: 'Chunk $i must be 100% bit-exact');
      }

      // Verify SHA-256 of concatenated stream
      final originalFull = BytesBuilder();
      final recoveredFull = BytesBuilder();
      for (int i = 0; i < 6; i++) {
        originalFull.add(rawDataChunks[i]);
        recoveredFull.add(recovered[i]!);
      }

      final origSha = sha256.convert(originalFull.toBytes()).toString();
      final recoveredSha = sha256.convert(recoveredFull.toBytes()).toString();
      expect(recoveredSha, equals(origSha));
    });

    test('Full Pipeline Video Dropped-Frame Disaster Recovery: Video with real dropped frame decodes and restores bit-exact via FEC', () async {
      final tempDir = await Directory.systemTemp.createTemp('fec_e2e_drop_');
      try {
        final rng = Random(42);
        final samplePayload = Uint8List.fromList(
          List.generate(12000, (_) => rng.nextInt(256)),
        );
        final expectedSha = sha256.convert(samplePayload).toString();

        final srcFile = File('${tempDir.path}/e2e_fec_payload.bin');
        await srcFile.writeAsBytes(samplePayload);

        // Encode at 720p 8x8 with 30% FEC, without guard frames to directly test FEC frame erasure
        final encResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: srcFile,
          blockSize: 8,
          width: 1280,
          height: 720,
          fps: 30,
          holdFrames: 1,
          fecPercent: 30,
          includeGuardFrames: false,
        );

        expect(encResult.videoFile.existsSync(), isTrue);

        // Use FFmpeg to simulate real video player/network frame drop: drop frame index 1 (chunk 1)
        final droppedVideo = File('${tempDir.path}/dropped_frame_video.mp4');
        await FfmpegRunner.execute(args: [
          '-y',
          '-i',
          encResult.videoFile.path,
          '-vf',
          "select='not(eq(n\\,1))'",
          '-vsync',
          '0',
          '-c:v',
          'libx264',
          '-crf',
          '0',
          droppedVideo.path,
        ]);

        expect(droppedVideo.existsSync(), isTrue);

        // Decode the damaged video with PixelDecoderService
        final decResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: droppedVideo,
          blockSize: 8,
        );

        expect(decResult.restoredFile.existsSync(), isTrue);
        expect(decResult.isSha256Matched, isTrue);
        expect(decResult.sha256, equals(expectedSha));
        expect(decResult.fecRecoveredCount, equals(1));

        final restoredBytes = await decResult.restoredFile.readAsBytes();
        expect(restoredBytes, equals(samplePayload));

        // Cleanup
        try {
          await encResult.videoFile.delete();
          await droppedVideo.delete();
          await decResult.restoredFile.delete();
        } catch (_) {}
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
