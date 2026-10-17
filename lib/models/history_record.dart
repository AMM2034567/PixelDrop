import 'dart:convert';

enum HistoryType {
  encode, // 文件转视频
  decode, // 视频转文件
}

class HistoryRecord {
  final String id;
  final HistoryType type;
  final String fileName;
  final String targetPath;
  final int originalSize;
  final int outputSize;
  final String sha256;
  final int blockSize;
  final DateTime timestamp;

  const HistoryRecord({
    required this.id,
    required this.type,
    required this.fileName,
    required this.targetPath,
    required this.originalSize,
    required this.outputSize,
    required this.sha256,
    required this.blockSize,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'fileName': fileName,
      'targetPath': targetPath,
      'originalSize': originalSize,
      'outputSize': outputSize,
      'sha256': sha256,
      'blockSize': blockSize,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory HistoryRecord.fromJson(Map<String, dynamic> json) {
    return HistoryRecord(
      id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
      type: json['type'] == 'decode' ? HistoryType.decode : HistoryType.encode,
      fileName: json['fileName'] as String? ?? '未命名文件',
      targetPath: json['targetPath'] as String? ?? '',
      originalSize: json['originalSize'] as int? ?? 0,
      outputSize: json['outputSize'] as int? ?? 0,
      sha256: json['sha256'] as String? ?? '',
      blockSize: json['blockSize'] as int? ?? 8,
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
    );
  }

  static List<HistoryRecord> listFromJsonString(String content) {
    if (content.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(content);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map((item) => HistoryRecord.fromJson(item))
            .toList();
      }
    } catch (_) {}
    return [];
  }

  static String listToJsonString(List<HistoryRecord> records) {
    final list = records.map((r) => r.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(list);
  }
}
