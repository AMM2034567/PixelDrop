import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_drop/screens/encode_screen.dart';
import 'package:pixel_drop/services/pixel_decoder.dart';
import 'package:pixel_drop/services/pixel_encoder.dart';

void main() {
  group('Platform Compatibility & Silent Audio Encoding Tests', () {
    test('buildFfmpegArgs with includeSilentAudio = true contains audio stream and faststart', () {
      final args = PixelEncoderService.buildFfmpegArgs(
        framesPattern: '/tmp/frame_%06d.png',
        outputPath: '/tmp/output.mp4',
        fps: 30,
        width: 1920,
        height: 1080,
        crf: 24,
        gop: 60,
        includeSilentAudio: true,
      );

      // Verify input pattern
      expect(args, contains('/tmp/frame_%06d.png'));

      // Verify silent audio generator (lavfi anullsrc)
      expect(args, contains('-f'));
      expect(args, contains('lavfi'));
      expect(args.any((arg) => arg.contains('anullsrc')), isTrue);

      // Verify audio codec and bitrate
      expect(args, contains('-c:a'));
      expect(args, contains('aac'));
      expect(args, contains('-b:a'));
      expect(args, contains('32k'));
      expect(args, contains('-shortest'));

      // Verify GOP and scene cut threshold
      expect(args, contains('-g'));
      expect(args, contains('60'));
      expect(args, contains('-sc_threshold'));
      expect(args, contains('0'));

      // Verify web streaming faststart
      expect(args, contains('-movflags'));
      expect(args, contains('+faststart'));

      // Verify destination
      expect(args.last, equals('/tmp/output.mp4'));
    });

    test('buildFfmpegArgs with includeSilentAudio = false omits audio but preserves faststart and GOP', () {
      final args = PixelEncoderService.buildFfmpegArgs(
        framesPattern: '/tmp/frame_%06d.png',
        outputPath: '/tmp/output.mp4',
        fps: 25,
        width: 1280,
        height: 720,
        crf: 20,
        gop: 50,
        includeSilentAudio: false,
      );

      // Audio stream should not be present
      expect(args.any((arg) => arg.contains('anullsrc')), isFalse);
      expect(args, isNot(contains('-c:a')));
      expect(args, isNot(contains('-shortest')));

      // Faststart and GOP should still be present
      expect(args, contains('-g'));
      expect(args, contains('50'));
      expect(args, contains('-movflags'));
      expect(args, contains('+faststart'));
      expect(args.last, equals('/tmp/output.mp4'));
    });

    test('Full End-to-End: Encode with silent audio + faststart and restore bit-exact 100% SHA-256 match', () async {
      final tempDir = await Directory.systemTemp.createTemp('compat_e2e_');
      try {
        final samplePayload = Uint8List.fromList(
          List.generate(1500, (i) => (i * 17 + 31) % 256),
        );
        final expectedSha = sha256.convert(samplePayload).toString();

        final srcFile = File('${tempDir.path}/compat_test_data.bin');
        await srcFile.writeAsBytes(samplePayload);

        // 1. Encode with silent audio and faststart
        final encResult = await PixelEncoderService.encodeFileToVideo(
          inputFile: srcFile,
          blockSize: 4,
          width: 1280,
          height: 720,
          fps: 30,
          holdFrames: 1,
          includeSilentAudio: true,
        );

        expect(encResult.videoFile.existsSync(), isTrue);
        expect(encResult.videoSize, greaterThan(0));
        expect(encResult.sha256, equals(expectedSha));

        // 2. Decode the video containing the audio track
        final decResult = await PixelDecoderService.decodeVideoToFile(
          videoFile: encResult.videoFile,
          blockSize: 4,
        );

        expect(decResult.restoredFile.existsSync(), isTrue);
        expect(decResult.isSha256Matched, isTrue);
        expect(decResult.sha256, equals(expectedSha));

        final restoredBytes = await decResult.restoredFile.readAsBytes();
        expect(restoredBytes, equals(samplePayload));

        // Cleanup video file
        try {
          await encResult.videoFile.delete();
          await decResult.restoredFile.delete();
        } catch (_) {}
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('EncodeScreen renders Platform Compatibility Switch and toggles correctly', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EncodeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Find the platform compatibility switch / title
      final compatText = find.text('平台免压与音轨兼容');
      expect(compatText, findsOneWidget);

      final switchFinder = find.byType(Switch);
      expect(switchFinder, findsOneWidget);

      // Verify initial state is true (enabled by default)
      final switchWidget = tester.widget<Switch>(switchFinder);
      expect(switchWidget.value, isTrue);

      // Tap switch to toggle off
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      final updatedSwitch = tester.widget<Switch>(switchFinder);
      expect(updatedSwitch.value, isFalse);
    });
  });
}
