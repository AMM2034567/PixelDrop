import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/history_record.dart';

/// Service managing persistent local transfer history for PixelDrop.
class HistoryService {
  static final ValueNotifier<List<HistoryRecord>> recordsNotifier =
      ValueNotifier<List<HistoryRecord>>([]);

  static File? _customHistoryFile;
  static bool _hasLoaded = false;
  static const int maxRecords = 200;

  @visibleForTesting
  static void setCustomFileForTesting(File file) {
    _customHistoryFile = file;
    _hasLoaded = false;
    recordsNotifier.value = [];
  }

  static Future<File> _getHistoryFile() async {
    if (_customHistoryFile != null) {
      return _customHistoryFile!;
    }
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/pixeldrop_history.json');
    if (!file.existsSync()) {
      try {
        file.createSync(recursive: true);
      } catch (_) {}
    }
    return file;
  }

  /// Loads history records from disk into memory.
  static Future<List<HistoryRecord>> loadRecords() async {
    try {
      final file = await _getHistoryFile();
      if (!file.existsSync()) {
        recordsNotifier.value = [];
        _hasLoaded = true;
        return [];
      }
      final content = file.readAsStringSync();
      final records = HistoryRecord.listFromJsonString(content);
      // Sort newest first
      records.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      recordsNotifier.value = records;
      _hasLoaded = true;
      return records;
    } catch (e) {
      debugPrint('HistoryService.loadRecords error: $e');
      recordsNotifier.value = [];
      _hasLoaded = true;
      return [];
    }
  }

  /// Appends a new transfer history record and persists to disk.
  static Future<void> addRecord({
    required HistoryType type,
    required String fileName,
    required String targetPath,
    required int originalSize,
    required int outputSize,
    required String sha256,
    required int blockSize,
  }) async {
    if (!_hasLoaded) {
      await loadRecords();
    }

    final newRecord = HistoryRecord(
      id: '${DateTime.now().millisecondsSinceEpoch}_${(1000 + (DateTime.now().microsecond % 9000))}',
      type: type,
      fileName: fileName,
      targetPath: targetPath,
      originalSize: originalSize,
      outputSize: outputSize,
      sha256: sha256,
      blockSize: blockSize,
      timestamp: DateTime.now(),
    );

    final current = List<HistoryRecord>.from(recordsNotifier.value);
    current.insert(0, newRecord);

    // Limit maximum records
    if (current.length > maxRecords) {
      current.removeRange(maxRecords, current.length);
    }

    recordsNotifier.value = current;
    await _saveToDisk(current);
  }

  /// Deletes a specific history record by its ID.
  static Future<void> deleteRecord(String id) async {
    if (!_hasLoaded) {
      await loadRecords();
    }
    final current = List<HistoryRecord>.from(recordsNotifier.value);
    current.removeWhere((r) => r.id == id);
    recordsNotifier.value = current;
    await _saveToDisk(current);
  }

  /// Clears all history records.
  static Future<void> clearAll() async {
    recordsNotifier.value = [];
    _hasLoaded = true;
    await _saveToDisk([]);
  }

  static Future<void> _saveToDisk(List<HistoryRecord> records) async {
    try {
      final file = await _getHistoryFile();
      final jsonStr = HistoryRecord.listToJsonString(records);
      file.writeAsStringSync(jsonStr, flush: true);
    } catch (e) {
      debugPrint('HistoryService._saveToDisk error: $e');
    }
  }
}
