import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:pixel_drop/main.dart';
import 'package:pixel_drop/screens/encode_screen.dart';
import 'package:pixel_drop/screens/decode_screen.dart';
import 'package:pixel_drop/services/storage_helper.dart';
import 'package:pixel_drop/services/ffmpeg_runner.dart';
import 'package:pixel_drop/services/pixel_encoder.dart';
import 'package:pixel_drop/services/pixel_decoder.dart';

void main() {
  group('Windows Desktop Storage & Services Tests', () {
    test('StorageHelper locates and creates Videos and Restored directories', () async {
      final videosDir = await StorageHelper.getVideosDir();
      final restoredDir = await StorageHelper.getRestoredDir();

      expect(videosDir.existsSync(), isTrue);
      expect(restoredDir.existsSync(), isTrue);
      expect(videosDir.path.endsWith('Videos'), isTrue);
      expect(restoredDir.path.endsWith('Restored'), isTrue);
    });

    test('StorageHelper showInExplorer and openFile handle file targets gracefully', () async {
      final tempFile = File('${Directory.systemTemp.path}\\pixeldrop_probe_file.tmp');
      await tempFile.writeAsString('probe content');
      try {
        final openRes = await StorageHelper.openFile(tempFile);
        expect(openRes, isNotNull);
        final showRes = await StorageHelper.showInExplorer(tempFile);
        expect(showRes, isNotNull);
      } finally {
        if (await tempFile.exists()) await tempFile.delete();
      }
    });

    test('FfmpegRunner detects local FFmpeg CLI executable if available on system', () async {
      final cliPath = await FfmpegRunner.getFfmpegCliPath();
      expect(cliPath, isNotNull, reason: 'FFmpeg CLI should be detected on the development environment');
      if (cliPath != null && cliPath != 'ffmpeg') {
        expect(File(cliPath).existsSync(), isTrue);
      }
    });
  });

  group('Windows Desktop Responsive UI & Drag-and-Drop Tests', () {
    testWidgets('Desktop wide screen (1120x760) renders NavigationRail and wide canvas', (tester) async {
      tester.view.physicalSize = const Size(1120 * 2, 760 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const PixelDropApp());
      await tester.pumpAndSettle();

      // Verify Desktop NavigationRail is used
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      // Verify DropTarget is active on EncodeScreen
      expect(find.byType(DropTarget), findsWidgets);
      expect(find.byType(EncodeScreen), findsOneWidget);

      // Switch to DecodeScreen using NavigationRail
      await tester.tap(find.text('视频转文件'));
      await tester.pumpAndSettle();

      expect(find.byType(DecodeScreen), findsOneWidget);
      expect(find.byType(DropTarget), findsWidgets);
    });

    testWidgets('DropTarget widget wraps file picking zone properly on EncodeScreen', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EncodeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DropTarget), findsOneWidget);
      expect(find.textContaining('选择待转换文件'), findsOneWidget);
    });

    testWidgets('DropTarget widget wraps file picking zone properly on DecodeScreen', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DecodeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DropTarget), findsOneWidget);
      expect(find.textContaining('选择待还原视频'), findsOneWidget);
    });
  });

  group('Windows Desktop End-to-End Pixel Encoding & Decoding', () {
    test('8x8 Block Size: Encodes test file to pixel MP4 and restores bit-exact with 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_8x8_${DateTime.now().millisecondsSinceEpoch}.txt');
      const originalContent = 'PixelDrop Windows Desktop Native 8x8 Block Noise Resistant Test: 像素矩阵传输协议 PXL1 2026!';
      await testFile.writeAsString(originalContent, flush: true);

      try {
        // 1. Encode to video (using 8x8 block for noise resistance)
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 8,
          fps: 10,
          holdFrames: 2,
          crf: 18,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);
        expect(encodeResult.sha256.isNotEmpty, isTrue);

        // 2. Decode back from video
        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 8,
        );

        // 3. Verify bit-exact integrity & SHA-256
        expect(decodeResult.isSha256Matched, isTrue);
        expect(decodeResult.sha256, equals(encodeResult.sha256));
        final restoredContent = await decodeResult.restoredFile.readAsString();
        expect(restoredContent, equals(originalContent));

        // Cleanup
        try {
          if (await encodeResult.videoFile.exists()) await encodeResult.videoFile.delete();
          if (await decodeResult.restoredFile.exists()) await decodeResult.restoredFile.delete();
        } catch (_) {}
      } finally {
        try {
          if (await testFile.exists()) await testFile.delete();
        } catch (_) {}
      }
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('4x4 Block Size: High-density multi-chunk file encodes and restores with 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_4x4_multi_${DateTime.now().millisecondsSinceEpoch}.dat');
      // Create multi-chunk test payload (12 KB with mixed repetitive and high entropy patterns)
      final buffer = Uint8List(12 * 1024);
      for (int i = 0; i < buffer.length; i++) {
        buffer[i] = (i * 37 + (i >> 3)) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        // 1. Encode to video (using 4x4 high density block)
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          fps: 10,
          holdFrames: 2,
          crf: 18,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);
        expect(encodeResult.sha256.isNotEmpty, isTrue);

        // 2. Decode back from video
        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 4,
        );

        // 3. Verify bit-exact integrity & SHA-256
        expect(decodeResult.isSha256Matched, isTrue);
        expect(decodeResult.sha256, equals(encodeResult.sha256));
        final restoredBytes = await decodeResult.restoredFile.readAsBytes();
        expect(restoredBytes, equals(buffer));

        // Cleanup
        try {
          if (await encodeResult.videoFile.exists()) await encodeResult.videoFile.delete();
          if (await decodeResult.restoredFile.exists()) await decodeResult.restoredFile.delete();
        } catch (_) {}
      } finally {
        try {
          if (await testFile.exists()) await testFile.delete();
        } catch (_) {}
      }
    }, timeout: const Timeout(Duration(seconds: 180)));
  });
}
