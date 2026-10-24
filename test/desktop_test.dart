import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
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

    testWidgets('DecodeScreen renders warning card and red alert styling when isSha256Matched is false', (tester) async {
      final dummyFile = File('C:/downloads/sha256_mismatch_demo.txt');
      final mismatchResult = DecodeResult(
        restoredFile: dummyFile,
        filename: 'sha256_mismatch_demo.txt',
        fileSize: 2048,
        sha256: 'deadbeef0123456789abcdef0123456789abcdef0123456789abcdef01234567',
        isSha256Matched: false,
        detectedBlockSize: 4,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: DecodeScreen(initialResult: mismatchResult),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify simulated mismatch UI elements
      expect(find.text('文件还原完成（校验不一致）'), findsOneWidget);
      expect(find.text('哈希指纹未完全匹配，视频可能经历了二次转码压缩'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text('sha256_mismatch_demo.txt'), findsOneWidget);
      expect(find.textContaining('deadbeef0123456789abcdef'), findsOneWidget);
      expect(find.text('打开文件'), findsOneWidget);
      expect(find.text('定位目录'), findsOneWidget);
    });

    testWidgets('DecodeScreen renders success card and verified icon when isSha256Matched is true', (tester) async {
      final dummyFile = File('C:/downloads/success_sample.txt');
      final successResult = DecodeResult(
        restoredFile: dummyFile,
        filename: 'success_sample.txt',
        fileSize: 1024,
        sha256: 'cafebabe0123456789abcdef0123456789abcdef0123456789abcdef01234567',
        isSha256Matched: true,
        detectedBlockSize: 2,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: DecodeScreen(initialResult: successResult),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify success UI elements
      expect(find.text('文件还原成功'), findsOneWidget);
      expect(find.text('SHA-256 校验通过，与源文件完全一致'), findsOneWidget);
      expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
      expect(find.text('success_sample.txt'), findsOneWidget);
      expect(find.textContaining('cafebabe0123456789abcdef'), findsOneWidget);
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

  group('Windows Desktop Multi-Isolate Parallel Frame Rendering & Acceleration Tests', () {
    test('getOptimalWorkerCount and getAcceleratorStatus adapt properly to CPU cores', () {
      final cpuCount = Platform.numberOfProcessors;
      final optimal = PixelEncoderService.getOptimalWorkerCount();
      expect(optimal, inInclusiveRange(1, 8));
      if (cpuCount >= 8) {
        expect(optimal, inInclusiveRange(6, 8));
      }

      // Explicit overrides
      expect(PixelEncoderService.getOptimalWorkerCount(1), equals(1));
      expect(PixelEncoderService.getOptimalWorkerCount(4), equals(4));
      expect(PixelEncoderService.getOptimalWorkerCount(16), equals(16));

      // Status string
      final status = PixelEncoderService.getAcceleratorStatus();
      expect(status, contains('多核并行加速: 启用'));
      expect(status, contains('$optimal 核心'));
    });

    testWidgets('EncodeScreen renders multi-core accelerator badge and thread choice chips', (tester) async {
      tester.view.physicalSize = const Size(1120 * 2, 800 * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EncodeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('多核并行加速'), findsOneWidget);
      expect(find.textContaining('多核并行加速: 启用'), findsOneWidget);
      expect(find.textContaining('自动 ('), findsOneWidget);
      expect(find.text('单线程 (节能)'), findsOneWidget);

      // Select '单线程 (节能)'
      await tester.ensureVisible(find.text('单线程 (节能)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('单线程 (节能)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('多核并行加速: 启用 (1 核心)'), findsOneWidget);

      // Select back to '自动'
      await tester.tap(find.textContaining('自动 ('));
      await tester.pumpAndSettle();
      final optimal = PixelEncoderService.getOptimalWorkerCount();
      expect(find.textContaining('多核并行加速: 启用 ($optimal 核心)'), findsOneWidget);
    });

    test('Multi-Worker Parallelism (4 Isolates vs 1 Isolate): Both restore bit-exact 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull);

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_parallel_${DateTime.now().millisecondsSinceEpoch}.dat');
      // Create multi-chunk uncompressible test payload (150 KB)
      final buffer = Uint8List(150 * 1024);
      int lcg = 314159265;
      for (int i = 0; i < buffer.length; i++) {
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        buffer[i] = (lcg >> 16) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      final List<double> progressUpdates = [];

      try {
        // 1. Encode with 4 parallel worker Isolates
        final encodeResult4 = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          width: 1920,
          height: 1080,
          fps: 30,
          holdFrames: 1,
          workerCount: 4,
          onProgress: (p, s) {
            progressUpdates.add(p);
          },
        );

        expect(encodeResult4.videoFile.existsSync(), isTrue);
        expect(progressUpdates.isNotEmpty, isTrue);
        expect(progressUpdates.last, equals(1.0));

        // 2. Decode and verify bit-exact SHA-256
        final decodeResult4 = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult4.videoFile,
          blockSize: 4,
        );

        expect(decodeResult4.isSha256Matched, isTrue);
        expect(decodeResult4.sha256, equals(encodeResult4.sha256));
        final restoredBytes4 = await decodeResult4.restoredFile.readAsBytes();
        expect(restoredBytes4, equals(buffer));

        // 3. Encode with 1 worker Isolate
        final encodeResult1 = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          width: 1920,
          height: 1080,
          fps: 30,
          holdFrames: 1,
          workerCount: 1,
        );

        final decodeResult1 = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult1.videoFile,
          blockSize: 4,
        );

        expect(decodeResult1.isSha256Matched, isTrue);
        expect(decodeResult1.sha256, equals(encodeResult4.sha256));
        final restoredBytes1 = await decodeResult1.restoredFile.readAsBytes();
        expect(restoredBytes1, equals(buffer));

        try {
          if (await encodeResult4.videoFile.exists()) await encodeResult4.videoFile.delete();
          if (await decodeResult4.restoredFile.exists()) await decodeResult4.restoredFile.delete();
          if (await encodeResult1.videoFile.exists()) await encodeResult1.videoFile.delete();
          if (await decodeResult1.restoredFile.exists()) await decodeResult1.restoredFile.delete();
        } catch (_) {}
      } finally {
        try {
          if (await testFile.exists()) await testFile.delete();
        } catch (_) {}
      }
    }, timeout: const Timeout(Duration(seconds: 180)));

    test('Multi-Worker Parallelism (8 Isolates): 2x2 Ultra-dense 1080p Hold=1 restores bit-exact 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull);

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_parallel_2x2_${DateTime.now().millisecondsSinceEpoch}.dat');
      // Create multi-chunk uncompressible test payload (80 KB)
      final buffer = Uint8List(80 * 1024);
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
          width: 1920,
          height: 1080,
          fps: 30,
          holdFrames: 1,
          workerCount: 8,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

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

    test('Multi-Worker Parallelism (4 Isolates): 8x8 720p Hold=2 restores bit-exact 100% SHA-256 match', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull);

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_parallel_8x8_${DateTime.now().millisecondsSinceEpoch}.dat');
      // Create multi-chunk uncompressible test payload (20 KB)
      final buffer = Uint8List(20 * 1024);
      int lcg = 135792468;
      for (int i = 0; i < buffer.length; i++) {
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        buffer[i] = (lcg >> 16) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 8,
          width: 1280,
          height: 720,
          fps: 30,
          holdFrames: 2,
          workerCount: 4,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 8,
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

  group('Automatic Block Size Auto-Detection Tests', () {
    test('Auto-detect 4x4 (1080p, hold=1): decodeVideoToFile(blockSize: null) detects 4x4 and restores bit-exact', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_autodetect_4x4_${DateTime.now().millisecondsSinceEpoch}.dat');
      final buffer = Uint8List(50 * 1024);
      int lcg = 44444444;
      for (int i = 0; i < buffer.length; i++) {
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        buffer[i] = (lcg >> 16) & 0xFF;
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
          workerCount: 4,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: null, // Test auto-detection
        );

        expect(decodeResult.detectedBlockSize, equals(4));
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

    test('Auto-detect 2x2 (1080p, hold=1): decodeVideoToFile(blockSize: null) detects 2x2 and restores bit-exact', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_autodetect_2x2_${DateTime.now().millisecondsSinceEpoch}.dat');
      final buffer = Uint8List(60 * 1024);
      int lcg = 22222222;
      for (int i = 0; i < buffer.length; i++) {
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        buffer[i] = (lcg >> 16) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 2,
          width: 1920,
          height: 1080,
          fps: 30,
          holdFrames: 1,
          workerCount: 4,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: null, // Test auto-detection
        );

        expect(decodeResult.detectedBlockSize, equals(2));
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

    test('Auto-detect 8x8 (720p, hold=2): decodeVideoToFile(blockSize: null) detects 8x8 and restores bit-exact', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_autodetect_8x8_${DateTime.now().millisecondsSinceEpoch}.dat');
      final buffer = Uint8List(20 * 1024);
      int lcg = 88888888;
      for (int i = 0; i < buffer.length; i++) {
        lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF;
        buffer[i] = (lcg >> 16) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 8,
          width: 1280,
          height: 720,
          fps: 30,
          holdFrames: 2,
          workerCount: 4,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: null, // Test auto-detection
        );

        expect(decodeResult.detectedBlockSize, equals(8));
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

    test('Auto-detect with blockSize: 0: decodeVideoToFile(blockSize: 0) triggers auto-detection without division-by-zero crash', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_autodetect_bs0_${DateTime.now().millisecondsSinceEpoch}.dat');
      final buffer = Uint8List(10 * 1024);
      for (int i = 0; i < buffer.length; i++) {
        buffer[i] = (i * 17 + 23) & 0xFF;
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
          workerCount: 2,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: 0, // Explicitly pass 0 to ensure no IntegerDivisionByZeroException occurs
        );

        expect(decodeResult.detectedBlockSize, equals(4));
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

    test('Auto-detect Legacy Version 1 (Monochrome PXL1): decodeVideoToFile(blockSize: null) detects v1 block size', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for end-to-end verification');

      final tempDir = Directory.systemTemp;
      final testFile = File('${tempDir.path}\\desktop_test_autodetect_v1_${DateTime.now().millisecondsSinceEpoch}.dat');
      final buffer = Uint8List(12 * 1024);
      for (int i = 0; i < buffer.length; i++) {
        buffer[i] = (i * 37 + 7) & 0xFF;
      }
      await testFile.writeAsBytes(buffer, flush: true);

      try {
        final encodeResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: testFile,
          blockSize: 4,
          width: 1280,
          height: 720,
          fps: 15,
          holdFrames: 1,
          version: 1, // Legacy monochrome PXL1
          workerCount: 2,
        );

        expect(encodeResult.videoFile.existsSync(), isTrue);

        final decodeResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encodeResult.videoFile,
          blockSize: null, // Auto-detect on legacy v1
        );

        expect(decodeResult.detectedBlockSize, equals(4));
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

    test('Auto-detect non-PixelDrop file: throws descriptive exception', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final tempDir = Directory.systemTemp;
      final fakeVideo = File('${tempDir.path}\\desktop_test_fake_${DateTime.now().millisecondsSinceEpoch}.mp4');
      await fakeVideo.writeAsBytes(Uint8List.fromList([0, 0, 0, 32, 102, 116, 121, 112, 109, 112, 52, 50]), flush: true);

      try {
        expect(
          () => PixelDecoderService.decodeVideoToFile(
            videoFile: fakeVideo,
            blockSize: null,
          ),
          throwsA(
            predicate((e) =>
              e is Exception &&
              e.toString().contains('无法自动识别点阵规格')
            ),
          ),
        );
      } finally {
        try {
          if (await fakeVideo.exists()) await fakeVideo.delete();
        } catch (_) {}
      }
    });

    test('Simulated SHA-256 Mismatch: Video with spoofed metadata hash decodes successfully but flags isSha256Matched as false', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI must be present for simulation verification');

      // 1. Prepare dummy payload
      const testFilename = 'sha256_mismatch_demo.txt';
      final dummyText = StringBuffer();
      dummyText.writeln('=====================================================');
      dummyText.writeln('PixelDrop SHA-256 校验不一致模拟测试文件');
      dummyText.writeln('=====================================================');
      dummyText.writeln('测试说明:');
      dummyText.writeln('1. 本视频中每一个像素点和分块的 CRC32 均 100% 正确且完整。');
      dummyText.writeln('2. 文件内容被无损解压并保存到本地。');
      dummyText.writeln('3. 头部元数据中记录的期望 SHA-256 哈希被特意篡改为伪造指纹。');
      dummyText.writeln('4. PixelDrop 在最终安全比对时发现不一致，触发防篡改警告 UI！');
      dummyText.writeln('=====================================================');

      final dummyBytes = Uint8List.fromList(utf8.encode(dummyText.toString()));
      final realHash = sha256.convert(dummyBytes).toString();
      const spoofedHash = '0000000000000000000000000000000000000000000000000000000000000000';

      // 2. Build meta header with spoofed SHA-256
      final metaHeader = PixelProtocol.buildMetaHeader(
        filename: testFilename,
        origSize: dummyBytes.length,
        sha256Hex: spoofedHash,
        useGzip: false,
      );

      final fullStream = Uint8List(metaHeader.length + dummyBytes.length);
      fullStream.setRange(0, metaHeader.length, metaHeader);
      fullStream.setRange(metaHeader.length, fullStream.length, dummyBytes);

      // 3. Grid geometry: 4x4 block, 1280x720
      const blockSize = 4;
      const width = 1280;
      const height = 720;
      const gridW = width ~/ blockSize;
      const gridH = height ~/ blockSize;
      const totalDots = gridW * gridH;
      const frameCapacity = (totalDots * 3) ~/ 8;
      const chunkCapacity = frameCapacity - PixelProtocol.headerLen;

      final List<Uint8List> chunks = [];
      for (int i = 0; i < fullStream.length; i += chunkCapacity) {
        final end = (i + chunkCapacity < fullStream.length) ? i + chunkCapacity : fullStream.length;
        chunks.add(Uint8List.sublistView(fullStream, i, end));
      }

      // 4. Render frames
      final tempDir = Directory.systemTemp;
      final sessionTs = DateTime.now().millisecondsSinceEpoch;
      final framesDir = Directory('${tempDir.path}\\sim_mismatch_frames_$sessionTs');
      await framesDir.create(recursive: true);

      int frameIndex = 1;
      for (int c = 0; c < chunks.length; c++) {
        final frameRaw = PixelProtocol.buildFrame(chunks.length, c, chunks[c], frameCapacity, version: 2);
        final smallImg = img.Image(width: gridW, height: gridH, numChannels: 3);
        final dots = PixelProtocol.unpackBytesToColorDots(frameRaw, totalDots);
        int dotIdx = 0;
        for (int y = 0; y < gridH; y++) {
          for (int x = 0; x < gridW; x++) {
            final v = dots[dotIdx++];
            final r = (v & 4) != 0 ? 255 : 0;
            final g = (v & 2) != 0 ? 255 : 0;
            final b = (v & 1) != 0 ? 255 : 0;
            smallImg.setPixelRgb(x, y, r, g, b);
          }
        }
        final pngBytes = Uint8List.fromList(img.encodePng(smallImg, level: 1));
        for (int h = 0; h < 20; h++) {
          final fpath = '${framesDir.path}\\frame_${frameIndex.toString().padLeft(6, '0')}.png';
          await File(fpath).writeAsBytes(pngBytes, flush: false);
          frameIndex++;
        }
      }

      // 5. FFmpeg encode
      final tempVideo = File('${tempDir.path}\\sim_mismatch_video_$sessionTs.mp4');
      final ffmpegArgs = [
        '-y',
        '-framerate', '20',
        '-i', '${framesDir.path}\\frame_%06d.png',
        '-vf', 'scale=$width:$height:flags=neighbor',
        '-c:v', 'libx264',
        '-crf', '24',
        '-pix_fmt', 'yuv420p',
        tempVideo.path,
      ];
      final procRes = await Process.run(cli!, ffmpegArgs);
      expect(procRes.exitCode, 0);

      // Save a permanent copy to Downloads/PixelDrop/Videos/sha256_mismatch_demo.mp4
      final videosDir = await StorageHelper.getVideosDir();
      final userVideo = File('${videosDir.path}\\sha256_mismatch_demo.mp4');
      await tempVideo.copy(userVideo.path);

      // 6. Decode and verify mismatch behavior
      final decodeResult = await PixelDecoderService.decodeVideoToFile(
        videoFile: tempVideo,
        blockSize: null, // Auto-detect
      );

      expect(decodeResult.detectedBlockSize, equals(4));
      expect(decodeResult.isSha256Matched, isFalse, reason: 'Expected SHA-256 mismatch flag to be false');
      expect(decodeResult.sha256, equals(realHash), reason: 'Actual computed SHA-256 must match real file hash');
      expect(decodeResult.filename, equals(testFilename));
      final restoredBytes = await decodeResult.restoredFile.readAsBytes();
      expect(restoredBytes, equals(dummyBytes), reason: 'Payload bytes must be perfectly restored');

      // Cleanup temp working files
      try {
        if (await framesDir.exists()) await framesDir.delete(recursive: true);
        if (await tempVideo.exists()) await tempVideo.delete();
        if (await decodeResult.restoredFile.exists()) await decodeResult.restoredFile.delete();
      } catch (_) {}
    });
  });
}

