import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_drop/models/history_record.dart';
import 'package:pixel_drop/services/history_service.dart';
import 'package:pixel_drop/screens/history_screen.dart';

void main() {
  group('HistoryRecord Model Serialization Tests', () {
    test('HistoryRecord converts to and from JSON correctly', () {
      final now = DateTime.now();
      final record = HistoryRecord(
        id: 'test_123',
        type: HistoryType.encode,
        fileName: 'sample_doc.pdf',
        targetPath: r'C:\Downloads\PixelDrop\Videos\sample_doc.mp4',
        originalSize: 1048576,
        outputSize: 1258291,
        sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        blockSize: 4,
        timestamp: now,
      );

      final json = record.toJson();
      expect(json['id'], 'test_123');
      expect(json['type'], 'encode');
      expect(json['fileName'], 'sample_doc.pdf');
      expect(json['targetPath'], r'C:\Downloads\PixelDrop\Videos\sample_doc.mp4');
      expect(json['originalSize'], 1048576);
      expect(json['outputSize'], 1258291);
      expect(json['sha256'], 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(json['blockSize'], 4);

      final restored = HistoryRecord.fromJson(json);
      expect(restored.id, record.id);
      expect(restored.type, HistoryType.encode);
      expect(restored.fileName, record.fileName);
      expect(restored.targetPath, record.targetPath);
      expect(restored.originalSize, record.originalSize);
      expect(restored.outputSize, record.outputSize);
      expect(restored.sha256, record.sha256);
      expect(restored.blockSize, 4);
    });

    test('listToJsonString and listFromJsonString round trip', () {
      final list = [
        HistoryRecord(
          id: '1',
          type: HistoryType.encode,
          fileName: 'file1.txt',
          targetPath: '/path/1',
          originalSize: 100,
          outputSize: 120,
          sha256: 'hash1',
          blockSize: 8,
          timestamp: DateTime.now(),
        ),
        HistoryRecord(
          id: '2',
          type: HistoryType.decode,
          fileName: 'file2.png',
          targetPath: '/path/2',
          originalSize: 500,
          outputSize: 500,
          sha256: 'hash2',
          blockSize: 4,
          timestamp: DateTime.now(),
        ),
      ];

      final jsonStr = HistoryRecord.listToJsonString(list);
      final parsed = HistoryRecord.listFromJsonString(jsonStr);
      expect(parsed.length, 2);
      expect(parsed[0].fileName, 'file1.txt');
      expect(parsed[1].fileName, 'file2.png');
      expect(parsed[1].type, HistoryType.decode);
    });
  });

  group('HistoryService Storage & Operations Tests', () {
    late Directory tempDir;
    late File historyFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('history_test_');
      historyFile = File('${tempDir.path}/test_history.json');
      HistoryService.setCustomFileForTesting(historyFile);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('addRecord, loadRecords, deleteRecord and clearAll work seamlessly', () async {
      expect(HistoryService.recordsNotifier.value.isEmpty, isTrue);

      // 1. Add Encode Record
      await HistoryService.addRecord(
        type: HistoryType.encode,
        fileName: 'music.mp3',
        targetPath: '${tempDir.path}/music.mp4',
        originalSize: 5242880,
        outputSize: 6400000,
        sha256: 'a1b2c3d4e5f6',
        blockSize: 8,
      );

      expect(HistoryService.recordsNotifier.value.length, 1);
      final firstRecord = HistoryService.recordsNotifier.value.first;
      expect(firstRecord.fileName, 'music.mp3');
      expect(firstRecord.type, HistoryType.encode);

      // Verify file persisted
      expect(await historyFile.exists(), isTrue);

      // 2. Add Decode Record
      await HistoryService.addRecord(
        type: HistoryType.decode,
        fileName: 'restored.zip',
        targetPath: '${tempDir.path}/restored.zip',
        originalSize: 1024,
        outputSize: 1024,
        sha256: '998877665544',
        blockSize: 4,
      );

      expect(HistoryService.recordsNotifier.value.length, 2);
      expect(HistoryService.recordsNotifier.value.first.fileName, 'restored.zip');

      // 3. Delete One Record
      await HistoryService.deleteRecord(firstRecord.id);
      expect(HistoryService.recordsNotifier.value.length, 1);
      expect(HistoryService.recordsNotifier.value.first.fileName, 'restored.zip');

      // 4. Clear All
      await HistoryService.clearAll();
      expect(HistoryService.recordsNotifier.value.isEmpty, isTrue);
      final reloaded = await HistoryService.loadRecords();
      expect(reloaded.isEmpty, isTrue);
    });
  });

  group('HistoryScreen Widget Tests', () {
    late Directory tempDir;
    late File historyFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('history_widget_test_');
      historyFile = File('${tempDir.path}/test_history.json');
      HistoryService.setCustomFileForTesting(historyFile);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('HistoryScreen displays empty state when no records exist', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: HistoryScreen(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('暂无传输历史'), findsOneWidget);
      expect(find.textContaining('当您完成文件转视频或从视频还原文件后'), findsOneWidget);
    });

    testWidgets('HistoryScreen renders history items and action buttons', (tester) async {
      // Add a test record
      await HistoryService.addRecord(
        type: HistoryType.encode,
        fileName: 'presentation.pptx',
        targetPath: '${tempDir.path}/presentation.mp4',
        originalSize: 204800,
        outputSize: 250000,
        sha256: 'fedcba9876543210',
        blockSize: 4,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: HistoryScreen(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('presentation.pptx'), findsOneWidget);
      expect(find.text('文件转视频'), findsOneWidget);
      expect(find.text('4x4'), findsOneWidget);
      expect(find.textContaining('fedcba9876543210'), findsOneWidget);
      expect(find.text('定位目录'), findsOneWidget);
      expect(find.text('播放视频'), findsOneWidget);
    });
  });
}
