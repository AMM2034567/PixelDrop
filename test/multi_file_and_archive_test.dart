import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_drop/screens/encode_screen.dart';
import 'package:pixel_drop/screens/decode_screen.dart';
import 'package:pixel_drop/services/archive_service.dart';
import 'package:pixel_drop/services/ffmpeg_runner.dart';
import 'package:pixel_drop/services/pixel_encoder.dart';
import 'package:pixel_drop/services/pixel_decoder.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
import 'package:path/path.dart' as p;

void main() {
  group('Multi-file and Folder Packaging & UI Tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('pixeldrop_test_env_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    testWidgets('EncodeScreen initial state provides file multi-pick and folder pick buttons', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EncodeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('选择待转换文件'), findsOneWidget);
      expect(find.text('选择文件 (支持多选)'), findsOneWidget);
      expect(find.text('选择文件夹'), findsOneWidget);
      expect(find.text('开始生成视频'), findsOneWidget);
      expect(find.byIcon(Icons.drive_folder_upload_rounded), findsOneWidget);
    });

    testWidgets('DecodeScreen renders 一键解压 button only for zip archives and extracts successfully', (tester) async {
      // 1. Non-zip file: No extraction button
      final dummyPdf = File(p.join(tempDir.path, 'sample.pdf'))..writeAsStringSync('PDF content');
      final nonZipResult = DecodeResult(
        restoredFile: dummyPdf,
        filename: 'sample.pdf',
        fileSize: dummyPdf.lengthSync(),
        sha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        isSha256Matched: true,
        detectedBlockSize: 4,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DecodeScreen(initialResult: nonZipResult),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('一键解压 (解压到当前目录)'), findsNothing);
      expect(find.text('打开文件'), findsOneWidget);
      expect(find.text('定位目录'), findsOneWidget);

      // 2. Zip archive: Shows extraction button and handles extract action
      final srcDir = Directory(p.join(tempDir.path, 'ZipSource'))..createSync();
      File(p.join(srcDir.path, 'inner.txt')).writeAsStringSync('Unzipped Content Success');
      final scanned = await ArchiveService.scanInputPaths([srcDir.path]);
      final testZip = await ArchiveService.createZipArchive(
        entries: scanned.entries,
        outputZipPath: p.join(tempDir.path, 'test_bundle.zip'),
      );

      final zipResult = DecodeResult(
        restoredFile: testZip,
        filename: 'test_bundle.zip',
        fileSize: testZip.lengthSync(),
        sha256: 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
        isSha256Matched: true,
        detectedBlockSize: 4,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DecodeScreen(initialResult: zipResult),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('一键解压 (解压到当前目录)'), findsOneWidget);
      expect(find.textContaining('检测到还原文件为 ZIP 归档包'), findsOneWidget);
      expect(find.text('打开文件'), findsOneWidget);
      expect(find.text('定位目录'), findsOneWidget);

      // Tap 一键解压 after scrolling into view
      await tester.ensureVisible(find.text('一键解压 (解压到当前目录)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一键解压 (解压到当前目录)'));
      await tester.pump();
      await tester.pumpAndSettle();

      // Check extracted directory exists
      final expectedExtractDir = Directory(p.join(tempDir.path, 'test_bundle'));
      expect(expectedExtractDir.existsSync(), isTrue);
      final extractedInner = File(p.join(expectedExtractDir.path, 'ZipSource', 'inner.txt'));
      expect(extractedInner.existsSync(), isTrue);
      expect(extractedInner.readAsStringSync(), equals('Unzipped Content Success'));

      // Check UI updated
      expect(find.textContaining('已成功解压至:'), findsWidgets);
    });

    test('End-to-End: Entire folder packaging, pixel encoding, decoding, and extraction', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI required for end-to-end test');

      // 1. Create a genuine folder hierarchy
      final projectDir = Directory(p.join(tempDir.path, 'MyDocs'))..createSync();
      File(p.join(projectDir.path, 'readme.txt')).writeAsStringSync('PixelDrop End-to-End Documentation');
      final subDir = Directory(p.join(projectDir.path, 'specs'))..createSync();
      File(p.join(subDir.path, 'spec.json')).writeAsStringSync('{"version": "1.0", "name": "PixelDrop"}');

      // 2. Scan input
      final selected = await ArchiveService.scanInputPaths([projectDir.path]);
      expect(selected.type, equals(SelectedInputType.directory));
      expect(selected.needsArchive, isTrue);
      expect(selected.fileCount, equals(2));
      expect(selected.suggestedArchiveName, equals('MyDocs.zip'));

      // 3. Package to archive
      final zipFile = await ArchiveService.createZipArchive(
        entries: selected.entries,
        outputZipPath: p.join(tempDir.path, selected.suggestedArchiveName),
      );
      expect(zipFile.existsSync(), isTrue);

      // 4. Encode to Pixel MP4 Video
      final encodeRes = await PixelEncoderService.encodeFileToVideo(
        inputFile: zipFile,
        blockSize: 4,
        width: 1280,
        height: 720,
        fps: 30,
        holdFrames: 1,
      );
      expect(encodeRes.videoFile.existsSync(), isTrue);

      // 5. Decode video back to file
      final decodeRes = await PixelDecoderService.decodeVideoToFile(
        videoFile: encodeRes.videoFile,
        blockSize: 4,
      );
      expect(decodeRes.isSha256Matched, isTrue);
      expect(decodeRes.filename, equals('MyDocs.zip'));
      expect(decodeRes.restoredFile.existsSync(), isTrue);

      // 6. Extract the decoded zip
      final extractedDir = await ArchiveService.extractZipArchive(
        zipFile: decodeRes.restoredFile,
      );
      expect(extractedDir.existsSync(), isTrue);

      final restoredReadme = File(p.join(extractedDir.path, 'readme.txt'));
      expect(restoredReadme.existsSync(), isTrue);
      expect(restoredReadme.readAsStringSync(), equals('PixelDrop End-to-End Documentation'));

      final restoredSpec = File(p.join(extractedDir.path, 'specs', 'spec.json'));
      expect(restoredSpec.existsSync(), isTrue);
      expect(restoredSpec.readAsStringSync(), equals('{"version": "1.0", "name": "PixelDrop"}'));

      // Cleanup
      try {
        if (encodeRes.videoFile.existsSync()) await encodeRes.videoFile.delete();
        if (decodeRes.restoredFile.existsSync()) await decodeRes.restoredFile.delete();
      } catch (_) {}
    });

    test('End-to-End: Multi-file bundle packaging, pixel encoding, decoding, and extraction', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cli = await FfmpegRunner.getFfmpegCliPath();
      expect(cli, isNotNull, reason: 'FFmpeg CLI required for end-to-end test');

      // 1. Create multiple files
      final file1 = File(p.join(tempDir.path, 'alpha.txt'))..writeAsStringSync('Alpha Content 12345');
      final file2 = File(p.join(tempDir.path, 'beta.csv'))..writeAsStringSync('id,name\n1,PixelDrop');

      // 2. Scan multi-file inputs
      final selected = await ArchiveService.scanInputPaths([file1.path, file2.path]);
      expect(selected.type, equals(SelectedInputType.multipleItems));
      expect(selected.needsArchive, isTrue);
      expect(selected.fileCount, equals(2));

      // 3. Package
      final zipFile = await ArchiveService.createZipArchive(
        entries: selected.entries,
        outputZipPath: p.join(tempDir.path, selected.suggestedArchiveName),
      );
      expect(zipFile.existsSync(), isTrue);

      // 4. Encode to Pixel Video
      final encodeRes = await PixelEncoderService.encodeFileToVideo(
        inputFile: zipFile,
        blockSize: 4,
        width: 1280,
        height: 720,
        fps: 30,
        holdFrames: 1,
      );
      expect(encodeRes.videoFile.existsSync(), isTrue);

      // 5. Decode
      final decodeRes = await PixelDecoderService.decodeVideoToFile(
        videoFile: encodeRes.videoFile,
        blockSize: 4,
      );
      expect(decodeRes.isSha256Matched, isTrue);

      // 6. Extract
      final extractedDir = await ArchiveService.extractZipArchive(
        zipFile: decodeRes.restoredFile,
      );
      expect(extractedDir.existsSync(), isTrue);

      final restoredF1 = File(p.join(extractedDir.path, 'alpha.txt'));
      expect(restoredF1.existsSync(), isTrue);
      expect(restoredF1.readAsStringSync(), equals('Alpha Content 12345'));

      final restoredF2 = File(p.join(extractedDir.path, 'beta.csv'));
      expect(restoredF2.existsSync(), isTrue);
      expect(restoredF2.readAsStringSync(), equals('id,name\n1,PixelDrop'));

      // Cleanup
      try {
        if (encodeRes.videoFile.existsSync()) await encodeRes.videoFile.delete();
        if (decodeRes.restoredFile.existsSync()) await decodeRes.restoredFile.delete();
      } catch (_) {}
    });

    testWidgets('DropTarget in EncodeScreen handles single file, multiple files, and folder drops', (tester) async {
      final f1 = File(p.join(tempDir.path, 'sample1.txt'))..writeAsStringSync('Hello 1');
      final f2 = File(p.join(tempDir.path, 'sample2.txt'))..writeAsStringSync('Hello 2');
      final folder = Directory(p.join(tempDir.path, 'TestFolder'))..createSync();
      File(p.join(folder.path, 'subfile.txt')).writeAsStringSync('Sub Content');

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EncodeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dropTarget = tester.widget<DropTarget>(find.byType(DropTarget));

      // 1. Drop single file
      dropTarget.onDragDone?.call(DropDoneDetails(files: [XFile(f1.path)], localPosition: Offset.zero, globalPosition: Offset.zero));
      await tester.pumpAndSettle();

      expect(find.text('sample1.txt'), findsOneWidget);
      expect(find.textContaining('大小: 7 B'), findsOneWidget);
      expect(find.text('开始生成视频'), findsOneWidget);
      expect(find.textContaining('自动打包归档为'), findsNothing);

      // Clear selection
      await tester.tap(find.byTooltip('清除选择'));
      await tester.pumpAndSettle();
      expect(find.text('选择待转换文件'), findsOneWidget);

      // 2. Drop folder
      dropTarget.onDragDone?.call(DropDoneDetails(files: [XFile(folder.path)], localPosition: Offset.zero, globalPosition: Offset.zero));
      await tester.pumpAndSettle();

      expect(find.text('TestFolder'), findsOneWidget);
      expect(find.textContaining('文件夹 · 包含 1 个文件'), findsOneWidget);
      expect(find.text('打包并生成视频'), findsOneWidget);
      expect(find.textContaining('自动打包归档为: TestFolder.zip'), findsOneWidget);

      // Clear selection
      await tester.tap(find.byTooltip('清除选择'));
      await tester.pumpAndSettle();

      // 3. Drop multiple files
      dropTarget.onDragDone?.call(DropDoneDetails(files: [XFile(f1.path), XFile(f2.path)], localPosition: Offset.zero, globalPosition: Offset.zero));
      await tester.pumpAndSettle();

      expect(find.text('已选 2 个项目'), findsOneWidget);
      expect(find.textContaining('包含 2 个文件'), findsOneWidget);
      expect(find.text('打包并生成视频'), findsOneWidget);
      expect(find.textContaining('自动打包归档为: sample1_bundle.zip'), findsOneWidget);
    });

    testWidgets('DecodeScreen renders video card with Chinese, spaces, and percent characters without URI exception', (tester) async {
      final chinesePercentVideo = File(p.join(tempDir.path, '测试文件 100% 完成_pixel.mp4'))
        ..writeAsBytesSync(List.filled(1024, 0));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DecodeScreen(initialVideoFile: chinesePercentVideo),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('测试文件 100% 完成_pixel.mp4'), findsOneWidget);
      expect(find.text('开始还原文件'), findsOneWidget);
    });
  });
}
