import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:pixel_drop/main.dart';
import 'package:pixel_drop/models/pixel_packet.dart';
import 'package:pixel_drop/screens/encode_screen.dart';
import 'package:pixel_drop/screens/decode_screen.dart';
import 'package:pixel_drop/services/storage_helper.dart';
import 'package:pixel_drop/services/ffmpeg_runner.dart';
import 'package:pixel_drop/services/pixel_encoder.dart';
import 'package:pixel_drop/services/pixel_decoder.dart';

void main() {
  group('PixelProtocol RGB 8-Color & Versioning Protocol Tests', () {
    test('packColorDotsToBytes and unpackBytesToColorDots bit-level exact roundtrip', () {
      // Test cases: empty, 1B, 2B, 3B, 7B, 100B, and random pattern
      final testCases = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList([0x55]),
        Uint8List.fromList([0xAA, 0x55]),
        Uint8List.fromList([0x12, 0x34, 0x56]),
        Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03]),
        Uint8List.fromList(List.generate(128, (i) => (i * 47 + (i >> 1)) & 0xFF)),
      ];

      for (final original in testCases) {
        final dotCount = (original.length * 8 + 2) ~/ 3;
        final dots = PixelProtocol.unpackBytesToColorDots(original, dotCount);
        expect(dots.length, equals(dotCount));
        for (final dot in dots) {
          expect(dot, inInclusiveRange(0, 7), reason: 'Each RGB 8-color dot value must be in 0..7');
        }

        final restored = PixelProtocol.packColorDotsToBytes(dots, original.length);
        expect(restored, equals(original), reason: 'Unpacked and repacked bytes must match original 100%');
      }
    });

    test('buildFrame and parseFrame support both PD02 (v2) and PXL1 (v1)', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);

      // Version 2 (PD02 RGB 8-Color)
      final frameV2 = PixelProtocol.buildFrame(10, 3, payload, 64, version: 2);
      expect(frameV2[0], equals(0x50)); // 'P'
      expect(frameV2[1], equals(0x44)); // 'D'
      expect(frameV2[2], equals(0x30)); // '0'
      expect(frameV2[3], equals(0x32)); // '2'
      final parsedV2 = PixelProtocol.parseFrame(frameV2);
      expect(parsedV2, isNotNull);
      expect(parsedV2!.version, equals(2));
      expect(parsedV2.totalChunks, equals(10));
      expect(parsedV2.chunkIndex, equals(3));
      expect(parsedV2.payload, equals(payload));

      // Version 1 (PXL1 Monochrome)
      final frameV1 = PixelProtocol.buildFrame(10, 3, payload, 64, version: 1);
      expect(frameV1[0], equals(0x50)); // 'P'
      expect(frameV1[1], equals(0x58)); // 'X'
      expect(frameV1[2], equals(0x4C)); // 'L'
      expect(frameV1[3], equals(0x31)); // '1'
      final parsedV1 = PixelProtocol.parseFrame(frameV1);
      expect(parsedV1, isNotNull);
      expect(parsedV1!.version, equals(1));
      expect(parsedV1.totalChunks, equals(10));
      expect(parsedV1.chunkIndex, equals(3));
      expect(parsedV1.payload, equals(payload));

      // CRC Mismatch corrupt detection
      final corruptFrame = Uint8List.fromList(frameV2);
      corruptFrame[16] ^= 0xFF; // Flip bit in payload
      expect(PixelProtocol.parseFrame(corruptFrame), isNull);

      // Invalid magic rejection
      final invalidMagicFrame = Uint8List.fromList(frameV2);
      invalidMagicFrame[0] = 0x00;
      expect(PixelProtocol.parseFrame(invalidMagicFrame), isNull);
    });

    test('buildMetaHeader and parseMetaHeader roundtrip with SHA-256 and GZip flags', () {
      const filename = 'test_document_测试.pdf';
      const origSize = 1048576;
      const sha256Hex = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      final dummyBody = Uint8List.fromList([10, 20, 30, 40, 50]);

      final metaHeader = PixelProtocol.buildMetaHeader(
        filename: filename,
        origSize: origSize,
        sha256Hex: sha256Hex,
        useGzip: true,
      );

      final fullStream = Uint8List(metaHeader.length + dummyBody.length);
      fullStream.setRange(0, metaHeader.length, metaHeader);
      fullStream.setRange(metaHeader.length, fullStream.length, dummyBody);

      final parsed = PixelProtocol.parseMetaHeader(fullStream);
      expect(parsed.filename, equals(filename));
      expect(parsed.originalSize, equals(origSize));
      expect(parsed.sha256, equals(sha256Hex));
      expect(parsed.useGzip, isTrue);
      expect(parsed.body, equals(dummyBody));
    });

    test('parseMetaHeader rejects truncated or malformed streams gracefully with FormatException', () {
      expect(() => PixelProtocol.parseMetaHeader(Uint8List(0)), throwsFormatException);
      expect(() => PixelProtocol.parseMetaHeader(Uint8List(1)), throwsFormatException);
      expect(() => PixelProtocol.parseMetaHeader(Uint8List.fromList([0x01, 0x00])), throwsFormatException);

      // Filename length says 10 bytes, but stream is only 20 bytes total (header needs offset + 73)
      final truncatedStream = Uint8List(20);
      truncatedStream[0] = 0;
      truncatedStream[1] = 10;
      expect(() => PixelProtocol.parseMetaHeader(truncatedStream), throwsFormatException);
    });
  });

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
    test('2x2 Block Size: Ultra-dense multi-chunk file encodes and restores bit-exact with 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_2x2_multi_${DateTime.now().millisecondsSinceEpoch}.dat');
      // Create genuine multi-chunk uncompressible test payload (400 KB > 194 KB frame capacity)
      final buffer = Uint8List(400 * 1024);
      int lcg = 123456789;
      for (int i = 0; i < buffer.length; i++) {
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        buffer[i] = (lcg >> 16) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        // 1. Encode to video using 2x2 ultra-dense block and default CRF (24)
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 2,
          width: 1920,
          height: 1080,
          fps: 30,
          holdFrames: 1,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);
        expect(encodeResult.sha256.isNotEmpty, isTrue);

        // 2. Decode back from video with 2x2 block size
        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 2,
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

    test('2x2 Block Size at 720p Resolution: Encodes with hold=2 and auto-detects/restores bit-exact', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_2x2_720p_${DateTime.now().millisecondsSinceEpoch}.dat');
      // Create multi-chunk test payload (> 86 KB frame capacity for 2x2 720p, e.g. 180 KB)
      final buffer = Uint8List(180 * 1024);
      int lcg = 987654321;
      for (int i = 0; i < buffer.length; i++) {
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        buffer[i] = (lcg >> 16) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 2,
          width: 1280,
          height: 720,
          fps: 30,
          holdFrames: 2,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);
        expect(encodeResult.sha256.isNotEmpty, isTrue);

        // Auto-detect resolution on decode with blockSize 2
        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 2,
        );

        expect(decodeResult.isSha256Matched, isTrue);
        expect(decodeResult.sha256, equals(encodeResult.sha256));
        final restoredBytes = await decodeResult.restoredFile.readAsBytes();
        expect(restoredBytes, equals(buffer));

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

    test('8x8 Block Size: Encodes test file to pixel MP4 and restores bit-exact with 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_8x8_${DateTime.now().millisecondsSinceEpoch}.dat');
      // Create multi-chunk test payload (> 12 KB frame capacity for 8x8 1080p, e.g. 25 KB)
      final buffer = Uint8List(25 * 1024);
      int lcg = 11223344;
      for (int i = 0; i < buffer.length; i++) {
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        buffer[i] = (lcg >> 16) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        // 1. Encode to video (using 8x8 block for noise resistance)
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 8,
          fps: 10,
          holdFrames: 2,
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
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('4x4 Block Size: High-density multi-chunk file encodes and restores with 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_4x4_multi_${DateTime.now().millisecondsSinceEpoch}.dat');
      // Create genuine multi-chunk test payload (> 48.6 KB frame capacity for 4x4 1080p, e.g. 100 KB)
      final buffer = Uint8List(100 * 1024);
      int lcg = 55667788;
      for (int i = 0; i < buffer.length; i++) {
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        buffer[i] = (lcg >> 16) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        // 1. Encode to video (using 4x4 high density block)
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          fps: 10,
          holdFrames: 2,
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

    test('1080p 30fps Hold=1: RGB 8-color protocol encodes and restores bit-exact with 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull);

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_1080p_30fps_${DateTime.now().millisecondsSinceEpoch}.bin');
      // Create multi-chunk test binary payload (100 KB)
      final buffer = Uint8List(100 * 1024);
      for (int i = 0; i < buffer.length; i++) {
        buffer[i] = (i * 97 + (i >> 3)) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          width: 1920,
          height: 1080,
          fps: 30,
          holdFrames: 1,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        // Auto-detect resolution on decode
        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 4,
        );

        expect(decodeResult.isSha256Matched, isTrue);
        expect(decodeResult.sha256, equals(encodeResult.sha256));
        final restoredBytes = await decodeResult.restoredFile.readAsBytes();
        expect(restoredBytes, equals(buffer));

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

    test('720p Resolution Override: Encodes at 720p and auto-detects/restores bit-exact', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull);

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_720p_${DateTime.now().millisecondsSinceEpoch}.bin');
      final buffer = Uint8List(30 * 1024);
      for (int i = 0; i < buffer.length; i++) {
        buffer[i] = (i * 53 + 7) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          width: 1280,
          height: 720,
          fps: 30,
          holdFrames: 1,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 4,
        );

        expect(decodeResult.isSha256Matched, isTrue);
        expect(decodeResult.sha256, equals(encodeResult.sha256));
        final restoredBytes = await decodeResult.restoredFile.readAsBytes();
        expect(restoredBytes, equals(buffer));

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

    test('Zero-Byte Empty File: Encodes to pixel MP4 and restores 0-byte file with 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull);

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_empty_${DateTime.now().millisecondsSinceEpoch}.bin');
      await testFile.writeAsBytes(Uint8List(0), flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          width: 1920,
          height: 1080,
          fps: 30,
          holdFrames: 1,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 4,
        );

        expect(decodeResult.isSha256Matched, isTrue);
        expect(decodeResult.sha256, equals(encodeResult.sha256));
        final restoredBytes = await decodeResult.restoredFile.readAsBytes();
        expect(restoredBytes.length, equals(0));

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

    test('Hold Frames = 2: Encodes with 2 hold frames and restores bit-exact with 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull);

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_hold2_${DateTime.now().millisecondsSinceEpoch}.bin');
      final buffer = Uint8List(25 * 1024);
      for (int i = 0; i < buffer.length; i++) {
        buffer[i] = (i * 73 + 19) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          width: 1280,
          height: 720,
          fps: 30,
          holdFrames: 2,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 4,
        );

        expect(decodeResult.isSha256Matched, isTrue);
        expect(decodeResult.sha256, equals(encodeResult.sha256));
        final restoredBytes = await decodeResult.restoredFile.readAsBytes();
        expect(restoredBytes, equals(buffer));

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

    test('Legacy Version 1 (Monochrome PXL1): Encodes with v1 and auto-detects/restores bit-exact', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull);

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_v1_${DateTime.now().millisecondsSinceEpoch}.bin');
      final buffer = Uint8List(15 * 1024);
      for (int i = 0; i < buffer.length; i++) {
        buffer[i] = (i * 31 + 41) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          width: 1280,
          height: 720,
          fps: 10,
          holdFrames: 2,
          version: 1, // Legacy monochrome
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 4,
        );

        expect(decodeResult.isSha256Matched, isTrue);
        expect(decodeResult.sha256, equals(encodeResult.sha256));
        final restoredBytes = await decodeResult.restoredFile.readAsBytes();
        expect(restoredBytes, equals(buffer));

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
